# WireGuard peer for the per-host VPN tunnel suite (E2eVpnTunnelTest). Userspace wireguard-go with
# the real wg tools, so the host needs no kernel module, only /dev/net/tun.
FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
RUN apk add --no-cache wireguard-tools wireguard-go iproute2 socat dnsmasq
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
