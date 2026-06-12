#!/bin/sh
# Stable AnyConnect/OpenConnect runner for MikroTik container (Alpine)
# Required ENV:
#   ANYCONNECT_SERVER, ANYCONNECT_USER, ANYCONNECT_PASSWORD, ANYCONNECT_CERT
#
# Optional ENV:
#   ANYCONNECT_LAN_CIDRS or LAN_CIDRS   (e.g. "192.168.1.0/24 192.168.88.0/24")
#   VPN_IF=tun127
#   NO_DTLS=1, DISABLE_IPV6=1, MTU=1300, REFRESH_SEC=30
#   LOG_LEVEL=info|debug, OC_VERBOSE=0|1, PRINT_STATE=0|1
#   SKIP_INSTALL=0|1  (default 0)
#
# Note: This script avoids printing the password.

set -u

# ---------- logging ----------
LOG_LEVEL="${LOG_LEVEL:-info}"   # info|debug
OC_VERBOSE="${OC_VERBOSE:-0}"    # 1 => openconnect -v
PRINT_STATE="${PRINT_STATE:-0}"  # 1 => print routes/addrs/iptables occasionally

ts() { date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date; }
log() { echo "$(ts) [INFO]  $*" >&2; }
dbg() { [ "$LOG_LEVEL" = "debug" ] && echo "$(ts) [DEBUG] $*" >&2 || true; }
warn(){ echo "$(ts) [WARN]  $*" >&2; }
err() { echo "$(ts) [ERROR] $*" >&2; }

# ---------- robust lock (PID + starttime, stale-safe) ----------
LOCKROOT="/run"
touch "$LOCKROOT/.w" 2>/dev/null && rm -f "$LOCKROOT/.w" 2>/dev/null || LOCKROOT="/tmp"

LOCKDIR="$LOCKROOT/ocvpn.lock.d"
PIDFILE="$LOCKDIR/pid"
STARTFILE="$LOCKDIR/start"

pstart() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null || echo ""; }

acquire_lock() {
  for _ in 1 2 3 4 5; do
    if mkdir "$LOCKDIR" 2>/dev/null; then
      echo "$$" > "$PIDFILE" 2>/dev/null || true
      pstart "$$" > "$STARTFILE" 2>/dev/null || true
      return 0
    fi

    oldpid="$(cat "$PIDFILE" 2>/dev/null || true)"
    oldst="$(cat "$STARTFILE" 2>/dev/null || true)"

    # no pid recorded -> stale
    if [ -z "${oldpid:-}" ]; then
      rm -rf "$LOCKDIR" 2>/dev/null || true
      continue
    fi

    # pid doesn't exist -> stale
    if [ ! -d "/proc/$oldpid" ]; then
      rm -rf "$LOCKDIR" 2>/dev/null || true
      continue
    fi

    # pid exists but starttime differs -> pid reused -> stale
    curst="$(pstart "$oldpid")"
    if [ -n "${oldst:-}" ] && [ -n "${curst:-}" ] && [ "$curst" != "$oldst" ]; then
      rm -rf "$LOCKDIR" 2>/dev/null || true
      continue
    fi

    echo "$(ts) [WARN] Another instance is running (pid=$oldpid). Exiting." >&2
    return 1
  done

  echo "$(ts) [ERROR] Could not acquire lock." >&2
  return 1
}

acquire_lock || exit 0
trap 'rm -rf "$LOCKDIR" 2>/dev/null || true' EXIT INT TERM HUP QUIT

# ---------- required env ----------
SERVER="${ANYCONNECT_SERVER:-}"
USER="${ANYCONNECT_USER:-}"
PASS="${ANYCONNECT_PASSWORD:-}"
CERT="${ANYCONNECT_CERT:-}"

# ---------- optional env ----------
VPN_IF="${VPN_IF:-tun127}"
NO_DTLS="${NO_DTLS:-1}"
DISABLE_IPV6="${DISABLE_IPV6:-1}"
MTU="${MTU:-1300}"
REFRESH_SEC="${REFRESH_SEC:-30}"
SKIP_INSTALL="${SKIP_INSTALL:-0}"

LAN_CIDRS="${LAN_CIDRS:-${ANYCONNECT_LAN_CIDRS:-}}"

need_env() {
  [ -n "$SERVER" ] && [ -n "$USER" ] && [ -n "$PASS" ] && [ -n "$CERT" ] && [ -n "$LAN_CIDRS" ]
}

servercert_arg() {
  case "$CERT" in
    pin-sha256:*|sha256:*|sha1:*) echo "$CERT" ;;
    *) echo "pin-sha256:$CERT" ;;
  esac
}

# Detect LAN gateway (avoid tun default)
detect_gw() {
  gw="$(ip route show default 2>/dev/null | awk '/ via /{print $3; exit}')"
  [ -n "${gw:-}" ] && { echo "$gw"; return 0; }

  gw="$(ip route show 2>/dev/null | awk -v vpn="$VPN_IF" '
    / via / {
      if ($0 ~ (" dev " vpn)) next
      if ($0 ~ / dev tun/) next
      print $3; exit
    }')"
  [ -n "${gw:-}" ] && { echo "$gw"; return 0; }

  return 1
}

detect_lan_if() {
  gw="$1"
  iface="$(ip route get "$gw" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  [ -n "${iface:-}" ] && { echo "$iface"; return 0; }

  iface="$(ip -o -4 addr show scope global 2>/dev/null | awk '$2 !~ /^(lo|tun)/{print $2; exit}')"
  [ -n "${iface:-}" ] && { echo "$iface"; return 0; }

  return 1
}

resolve_v4() {
  if command -v getent >/dev/null 2>&1; then
    ip="$(getent ahostsv4 "$SERVER" 2>/dev/null | awk '{print $1; exit}' || true)"
    [ -n "${ip:-}" ] && { echo "$ip"; return 0; }
  fi
  if command -v nslookup >/dev/null 2>&1; then
    ip="$(nslookup "$SERVER" 2>/dev/null | awk '/^Address: /{print $2; exit}' || true)"
    [ -n "${ip:-}" ] && { echo "$ip"; return 0; }
  fi
  return 1
}

ensure_sysctl() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
}

ensure_dns_routes() {
  gw="$1"; lan_if="$2"
  for ns in $(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null || true); do
    echo "$ns" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || continue
    ip route replace "$ns/32" via "$gw" dev "$lan_if" 2>/dev/null || true
  done
}

ensure_lan_routes() {
  gw="$1"; lan_if="$2"
  [ -n "${LAN_CIDRS:-}" ] || return 0
  for c in $LAN_CIDRS; do
    ip route replace "$c" via "$gw" dev "$lan_if" 2>/dev/null || true
  done
}

ensure_server_route() {
  gw="$1"; lan_if="$2"; vpn_ip="$3"
  ip route replace "$vpn_ip/32" via "$gw" dev "$lan_if" 2>/dev/null || true
}

ensure_iptables() {
  lan_if="$1"

  iptables -t nat -C POSTROUTING -o "$VPN_IF" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "$VPN_IF" -j MASQUERADE

  iptables -C FORWARD -i "$lan_if" -o "$VPN_IF" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$lan_if" -o "$VPN_IF" -j ACCEPT

  iptables -C FORWARD -i "$VPN_IF" -o "$lan_if" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$VPN_IF" -o "$lan_if" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
}

cleanup_tun() {
  if ip link show "$VPN_IF" >/dev/null 2>&1; then
    dbg "Cleaning up $VPN_IF (avoid Resource busy)"
    ip link set "$VPN_IF" down 2>/dev/null || true
    ip tuntap del dev "$VPN_IF" mode tun 2>/dev/null || true
    ip link del "$VPN_IF" 2>/dev/null || true
  fi
}

pick_vpnc_script() {
  [ -x /etc/vpnc/vpnc-script ] && { echo /etc/vpnc/vpnc-script; return 0; }
  return 1
}

make_vpnc_wrapper() {
  base="$(pick_vpnc_script || true)"
  if [ -z "${base:-}" ]; then
    warn "vpnc-script not found; using /bin/true (less reliable tunnel setup)."
    echo "/bin/true"
    return 0
  fi

  mkdir -p /opt/openconnect
  cat > /opt/openconnect/vpnc-wrapper.sh <<WRAP
#!/bin/sh
if [ "\${reason:-}" = "attempt-reconnect" ]; then
  reason="reconnect"
  export reason
fi
exec "$base" "\$@"
WRAP
  chmod +x /opt/openconnect/vpnc-wrapper.sh
  echo "/opt/openconnect/vpnc-wrapper.sh"
}

ensure_deps() {
  if [ ! -c /dev/net/tun ]; then
    err "/dev/net/tun missing. In RouterOS set container: user=0:0 devices=/dev/net/tun"
    return 1
  fi

  command -v openconnect >/dev/null 2>&1 || { err "openconnect not found in image"; return 1; }

  if command -v ip >/dev/null 2>&1 && command -v iptables >/dev/null 2>&1 && [ -x /etc/vpnc/vpnc-script ]; then
    return 0
  fi

  [ "$SKIP_INSTALL" = "1" ] && { err "Deps missing and SKIP_INSTALL=1"; return 1; }

  if command -v apk >/dev/null 2>&1; then
    log "apk update"
    apk update || return 1
    log "apk add iproute2 iptables ca-certificates bind-tools vpnc curl"
    apk add --no-cache iproute2 iptables ca-certificates bind-tools vpnc || return 1
    update-ca-certificates >/dev/null 2>&1 || true
    return 0
  fi

  err "apk not found; cannot install deps."
  return 1
}

print_state() {
  [ "$PRINT_STATE" = "1" ] || return 0
  echo "---- STATE ----" >&2
  ip route >&2 || true
  ip addr show "$VPN_IF" >&2 || true
  iptables -t nat -L -v -n >&2 || true
  iptables -L FORWARD -v -n >&2 || true
  echo "--------------" >&2
}

# ---------- main loop ----------
while true; do
  # reload env (so script stays constant)
  SERVER="${ANYCONNECT_SERVER:-$SERVER}"
  USER="${ANYCONNECT_USER:-$USER}"
  PASS="${ANYCONNECT_PASSWORD:-$PASS}"
  CERT="${ANYCONNECT_CERT:-$CERT}"
  LAN_CIDRS="${LAN_CIDRS:-${ANYCONNECT_LAN_CIDRS:-$LAN_CIDRS}}"

  if ! need_env; then
    err "Missing envs. Need ANYCONNECT_SERVER/USER/PASSWORD/CERT. Sleeping..."
    sleep 5
    continue
  fi

  if ! ensure_deps; then
    err "Deps install/check failed. Sleeping..."
    sleep 5
    continue
  fi

  gw="$(detect_gw || true)"
  [ -n "${gw:-}" ] || { err "Cannot detect LAN gateway. Sleeping..."; sleep 5; continue; }

  lan_if="$(detect_lan_if "$gw" || true)"
  [ -n "${lan_if:-}" ] || { err "Cannot detect LAN interface. Sleeping..."; sleep 5; continue; }

  vpn_ip="$(resolve_v4 || true)"
  [ -n "${vpn_ip:-}" ] || { err "DNS resolve failed for $SERVER. Sleeping..."; sleep 5; continue; }

  dbg "Detected gw=$gw lan_if=$lan_if vpn_if=$VPN_IF server_ip=$vpn_ip"
  [ -n "${LAN_CIDRS:-}" ] && dbg "LAN_CIDRS=$LAN_CIDRS" || dbg "LAN_CIDRS empty"

  ensure_sysctl
  ensure_dns_routes "$gw" "$lan_if"
  ensure_lan_routes "$gw" "$lan_if"
  ensure_server_route "$gw" "$lan_if" "$vpn_ip"
  ensure_iptables "$lan_if"

  cleanup_tun

  sc="$(servercert_arg)"
  vpnc_script="$(make_vpnc_wrapper)"

  extra=""
  [ "$NO_DTLS" = "1" ] && extra="$extra --no-dtls"
  [ "$DISABLE_IPV6" = "1" ] && extra="$extra --disable-ipv6"
  [ -n "$MTU" ] && extra="$extra --mtu $MTU"
  [ "$OC_VERBOSE" = "1" ] && extra="$extra -v"

  log "Connecting: server=$SERVER ($vpn_ip) lan_if=$lan_if gw=$gw vpn_if=$VPN_IF"
  print_state

  # Do NOT leak password; run openconnect without xtrace
  ( printf "%s\n" "$PASS" | openconnect $extra \
      --resolve="$SERVER:$vpn_ip" \
      --user="$USER" --passwd-on-stdin \
      -i "$VPN_IF" \
      --servercert "$sc" \
      --script "$vpnc_script" \
      "$SERVER"
  ) &
  pid=$!

  while kill -0 "$pid" >/dev/null 2>&1; do
    ensure_dns_routes "$gw" "$lan_if"
    new_ip="$(resolve_v4 || true)"
    if [ -n "${new_ip:-}" ] && [ "$new_ip" != "$vpn_ip" ]; then
      vpn_ip="$new_ip"
      dbg "Server IP changed -> $vpn_ip ; updating route"
      ensure_server_route "$gw" "$lan_if" "$vpn_ip"
    fi
    sleep "$REFRESH_SEC"
  done

  warn "openconnect exited; cleaning up $VPN_IF and restarting..."
  cleanup_tun
  sleep 3
done
