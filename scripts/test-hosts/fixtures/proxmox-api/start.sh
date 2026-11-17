#!/bin/sh
# Makes the fake's self-signed certificate (once per container, as a Proxmox node makes its own),
# then serves the API on 8006. The two tokens' secrets come from the environment.
set -eu
: "${PVE_TOKEN_SECRET:?}" "${PVE_AUDIT_TOKEN_SECRET:?}"
umask 077
mkdir -p /etc/omniterm-pve
if [ ! -f /etc/omniterm-pve/pve-ssl.pem ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/OU=PVE Cluster Node/O=Proxmox Virtual Environment/CN=pve1.omniterm.invalid" \
    -addext "subjectAltName=DNS:pve1.omniterm.invalid,DNS:pve1" \
    -keyout /etc/omniterm-pve/pve-ssl.key -out /etc/omniterm-pve/pve-ssl.pem 2>/dev/null
fi
exec python3 -I /usr/local/lib/omniterm/fake_pve.py /etc/omniterm-pve/pve-ssl.pem /etc/omniterm-pve/pve-ssl.key
