# WireGuard peer for the per-host VPN tunnel suite (E2eVpnTunnelTest). Userspace wireguard-go with
# the real wg tools, so the host needs no kernel module, only /dev/net/tun.
FROM alpine:3.22
RUN apk add --no-cache wireguard-tools wireguard-go iproute2 socat dnsmasq
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
