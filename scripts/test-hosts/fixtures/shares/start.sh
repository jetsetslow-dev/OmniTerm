#!/bin/sh
set -eu

: "${OMNITERM_TEST_USER:?OMNITERM_TEST_USER is required}"
: "${OMNITERM_TEST_PASSWORD:?OMNITERM_TEST_PASSWORD is required}"

if ! id "$OMNITERM_TEST_USER" >/dev/null 2>&1; then
  adduser -D -h /srv/share "$OMNITERM_TEST_USER"
fi
printf '%s:%s\n' "$OMNITERM_TEST_USER" "$OMNITERM_TEST_PASSWORD" | chpasswd
printf '%s\n%s\n' "$OMNITERM_TEST_PASSWORD" "$OMNITERM_TEST_PASSWORD" |
  smbpasswd -s -a "$OMNITERM_TEST_USER"

# Restore the two named baseline files on every start. Tests use their own uniquely named paths, so
# their other edits remain reusable in the named volume while the verification facts stay stable.
cp -a /opt/omniterm-seed/. /srv/share/
chown -R "$OMNITERM_TEST_USER:$OMNITERM_TEST_USER" /srv/share /var/lib/rclone

pasv_address="${OMNITERM_TEST_FTP_PASV_ADDRESS:-127.0.0.1}"
sed "s/__PASV_ADDRESS__/$pasv_address/" \
  /etc/vsftpd/vsftpd.conf.template >/etc/vsftpd/vsftpd.conf

smbd --foreground --no-process-group --debug-stdout &
vsftpd /etc/vsftpd/vsftpd.conf &

# rclone runs as the share user so WebDAV writes land with the same ownership as SMB and FTP writes;
# a root-owned file would be unwritable over the other two protocols. Unprivileged means it cannot
# bind 80, so the share answers on 8080 and compose maps the host's 8082 onto it. The config path is
# kept out of /srv/share, which is the user's home and would otherwise gain a .config directory that
# shows up in every fixture listing.
exec su-exec "$OMNITERM_TEST_USER" rclone serve webdav /srv/share \
  --addr 0.0.0.0:8080 \
  --baseurl /fixture \
  --config /var/lib/rclone/rclone.conf \
  --user "$OMNITERM_TEST_USER" \
  --pass "$OMNITERM_TEST_PASSWORD"
