      # OpenConnect / AnyConnect VPN Client for MikroTik RouterOS Containers

A lightweight **OpenConnect (Cisco AnyConnect-compatible)** VPN client designed for **MikroTik RouterOS v7 Containers**.

This project provides a robust `run.sh` entrypoint that connects to an AnyConnect/OpenConnect VPN and can be used as a **VPN gateway** to route selected LAN traffic through the tunnel (**policy routing friendly**).

---

## Features

- ✅ OpenConnect (AnyConnect-compatible) VPN client
- ✅ Works well with MikroTik **policy routing** (route only selected devices/subnets via VPN)
- ✅ Supports **domain-based VPN servers** (dynamic IPs) and refreshes host routes automatically
- ✅ Automatic handling for:
  - stale TUN devices (`TUNSETIFF: Resource busy`)
  - reconnect script issues (`attempt-reconnect`)
  - stale locks after unexpected container stops
- ✅ DTLS disabled by default (avoids common UDP/DTLS handshake issues)
- ✅ Configurable via environment variables (no need to modify the script)
- ✅ Optional debug logging and state dumps for troubleshooting

---

## Environment Variables

### Required

| Variable | Description |
|---|---|
| `ANYCONNECT_SERVER` | VPN server hostname (domain) |
| `ANYCONNECT_USER` | Username |
| `ANYCONNECT_PASSWORD` | Password |
| `ANYCONNECT_CERT` | Certificate pin (`pin-sha256:...`, `sha256:...`, `sha1:...`). If you provide a raw pin, it is treated as `pin-sha256:<value>`. |
| `ANYCONNECT_LAN_CIDRS` | Space-separated LAN CIDRs to add return routes for (e.g. `"192.168.1.0/24 192.168.88.0/24"`). |

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
3. Applies NAT (MASQUERADE) and forwarding rules so traffic from selected LAN subnets can pass through the tunnel.
4. Adds host routes for:
   - VPN server IP (so the VPN connection doesn’t loop through itself)
   - DNS servers (so reconnect/DNS resolution stays stable)
5. Periodically re-resolves the VPN server domain and updates host routes when IP changes.

---

## Quick Start

### 1) Build the image

```bash
docker login
docker buildx create --use --name mybuilder
docker buildx inspect --bootstrap

docker buildx build \
  --platform linux/arm64,linux/amd64 \
  -t YOUR_DOCKERHUB_USER/mt-openconnect:latest \
  --push .
```

MikroTik devices are often ```linux/arm64``` (aarch64). If you only need MikroTik, you can build just ```linux/arm64```.

### 2) Configure MikroTik container (concept)

You typically need:

- Enable logs: ```logging=yes```
- Ensure the container subnet has internet access (usually NAT/masquerade on RouterOS)

Also make sure your container environment variables are set:

- ```ANYCONNECT_SERVER```
- ```ANYCONNECT_USER```
- ```ANYCONNECT_PASSWORD```
- ```ANYCONNECT_CERT```
- ```ANYCONNECT_LAN_CIDRS```

### MikroTik RouterOS Notes

- The container subnet must have internet access (DNS + outbound connectivity), otherwise the VPN connection and/or package installation can fail.

- If you use MikroTik policy routing, you usually route selected traffic to the container IP as the gateway in a separate routing table.

### Policy Routing (Typical Setup)

Goal: Only route selected clients/subnets via the VPN container, not all traffic.

General steps on MikroTik:

1. Container gets an IP on a container subnet (e.g. ```192.168.21.0/24```).
2. Create a routing table that uses the container IP as a gateway.
3. Use mangle rules to mark traffic for specific clients/subnets and route them via that table.

(Exact commands depend on your RouterOS config and naming.)

### Dockerfile (recommended)
```
FROM alpine:3.22

RUN apk add --no-cache \
    openconnect iproute2 iptables ca-certificates bind-tools vpnc tini \
 && update-ca-certificates

COPY run.sh /opt/openconnect/run.sh
RUN chmod +x /opt/openconnect/run.sh

ENTRYPOINT ["/sbin/tini","--","/opt/openconnect/run.sh"]
```

### GitHub Actions (Build & Push to Docker Hub)

1. Create a Docker Hub access token
2. Add GitHub secrets:
- ```DOCKERHUB_USERNAME```
- ```DOCKERHUB_TOKEN```

Create ```.github/workflows/docker.yml```:
```
name: Build & Push Docker image

on:
  push:
    branches: [ "main" ]
    tags: [ "v*" ]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Login to Docker Hub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Extract metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ secrets.DOCKERHUB_USERNAME }}/mt-openconnect
          tags: |
            type=ref,event=branch
            type=ref,event=tag
            type=raw,value=latest,enable={{is_default_branch}}

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          platforms: linux/arm64,linux/amd64
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
```

## Troubleshooting
### Container exits quickly / no logs

Enable container logging on MikroTik (logging=yes) and check RouterOS logs.
```
TUNSETIFF: Resource busy 
```
A previous tunnel device exists or another OpenConnect instance is running.
This project includes cleanup logic to remove an existing ``` tun127 ``` before reconnect.
```
attempt-reconnect / vpnc-script returned error
```
Some scripts don’t recognize the ```attempt-reconnect``` reason.
This project wraps ```vpnc-script``` to normalize that reason.
```
unable to get local issuer certificate
```
Your VPN server may use a private CA chain.
Pinning via ANYCONNECT_CERT is recommended. To remove this warning, install your organization CA into the container trust store.
```
Failed to open /dev/vhost-net
```
Usually harmless in container environments (no acceleration device).

### Credits / Acknowledgements

This project is inspired by and builds upon the original concept from:

- https://github.com/degritsenko/openconnect-mikrotik

The original repository provided a solid base for running OpenConnect on MikroTik RouterOS containers.
This variant focuses on a more “hands-off” operational setup for daily use (gateway + routing + resiliency + logging).

Huge thanks to the original author for publishing the base implementation.

### Project Layout
```
.
├─ Dockerfile
├─ run.sh
└─ README.md
```
### Security Notes

Don’t hardcode passwords into the image.
Keep container logs private (especially with ```OC_VERBOSE=1```).
Prefer certificate pinning (```ANYCONNECT_CERT```) for server identity verification.
