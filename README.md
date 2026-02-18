# OpenConnect / AnyConnect VPN Client for MikroTik RouterOS Containers

A lightweight **OpenConnect (Cisco AnyConnect-compatible)** VPN client designed for **MikroTik RouterOS v7 Containers**.

This project provides a robust `run.sh` entrypoint that connects to an AnyConnect/OpenConnect VPN and can be used as a **VPN gateway** to route selected LAN traffic through the tunnel (policy routing friendly).

---

## Features

- ✅ OpenConnect (AnyConnect-compatible) VPN client
- ✅ Works well with MikroTik **policy routing** (route only selected devices/subnets via VPN)
- ✅ Supports **domain-based VPN servers** (dynamic IPs) and refreshes host routes automatically
- ✅ Automatic handling for:
  - stale TUN devices (`Resource busy`)
  - reconnect script issues (`attempt-reconnect`)
  - stable logging
- ✅ DTLS disabled by default (avoids common UDP/DTLS handshake issues)
- ✅ Configurable via environment variables (no need to modify the script)

---

## Environment Variables

### Required

| Variable | Description |
|---|---|
| `ANYCONNECT_SERVER` | VPN server hostname (domain) |
| `ANYCONNECT_USER` | Username |
| `ANYCONNECT_PASSWORD` | Password |
| `ANYCONNECT_CERT` | Certificate pin (`pin-sha256:...`, `sha256:...`, `sha1:...`). If you provide a raw pin, it is treated as `pin-sha256:<value>`. |
| `ANYCONNECT_LAN_CIDRS` | *(empty)* | Space-separated LAN CIDRs to add return routes for (e.g. `"192.168.12.0/24 192.168.88.0/24"`). |

### Optional

| Variable | Default | Description |
|---|---:|---|
| `LAN_CIDRS` | *(fallback)* | Alternative name for LAN CIDRs (same format). |
| `VPN_IF` | `tun127` | TUN device name. |
| `NO_DTLS` | `1` | Disable DTLS (UDP). |
| `DISABLE_IPV6` | `1` | Disable IPv6 in OpenConnect. |
| `MTU` | `1300` | Tunnel MTU. |
| `REFRESH_SEC` | `30` | How often to re-resolve the server domain and refresh host routes. |
| `LOG_LEVEL` | `info` | `info` or `debug`. |
| `OC_VERBOSE` | `0` | Set to `1` for `openconnect -v` verbosity. |
| `PRINT_STATE` | `0` | Set to `1` to print routing/iptables state periodically. |
| `SKIP_INSTALL` | `0` | Set to `1` to skip installing packages (only if your image already includes deps). |

---

## How it Works (High-level)

1. Connects to the VPN server using OpenConnect (with certificate pinning).
2. Creates/uses a TUN interface (default `tun127`).
3. Applies NAT (MASQUERADE) and forwarding rules so traffic from LAN subnets can pass through the tunnel.
4. Adds host routes for:
   - VPN server IP (so the VPN connection doesn’t loop through itself)
   - DNS servers (so reconnect/DNS resolution stays stable)
5. Periodically re-resolves the VPN server domain and updates host routes when IP changes.

---

## MikroTik RouterOS Notes

For a RouterOS container, you typically need:

- Run as root inside container: `user=0:0`
- Allow TUN device: `devices=/dev/net/tun`
- Enable logs: `logging=yes`
- Ensure the container subnet has internet access (usually NAT/masquerade on RouterOS)

> RouterOS containers are documented here: MikroTik RouterOS Container docs.

---

## Policy Routing (Typical Setup)

**Goal:** Only route selected clients/subnets via the VPN container, not all traffic.

General steps on MikroTik:

1. Container gets an IP on a container subnet (e.g. `192.168.21.0/24`).
2. Create a routing table that uses the container IP as a gateway.
3. Use mangle rules to mark traffic for specific clients/subnets and route them via that table.

*(Exact commands depend on your RouterOS config and naming.)*

---

## Credits / Acknowledgements

This project is inspired by and builds upon the original concept from:

- https://github.com/degritsenko/openconnect-mikrotik

The original repository provided a solid base for running OpenConnect on MikroTik RouterOS containers.  
This variant focuses on a more “hands-off” operational setup for daily use (gateway + routing + resiliency + logging).

Huge thanks to the original author for publishing the base implementation.

---

## Image / Project Layout

Typical repo layout:

```text
.
├─ Dockerfile
├─ run.sh
└─ README.md

```bash
docker login
docker buildx create --use --name mybuilder
docker buildx inspect --bootstrap

docker buildx build \
  --platform linux/arm64,linux/amd64 \
  -t YOUR_DOCKERHUB_USER/mt-openconnect:latest \
  --push .
