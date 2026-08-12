FROM alpine:3.22

# WebDAV is served by rclone rather than Apache. Apache's mod_dav_fs opens its lock database through
# apr_dbm, and apr-util 1.6.4 ships no apr_dbm_*.so driver on Alpine 3.21/3.22, httpd:2.4-alpine or
# httpd:2.4 — all four fail the same way. mod_dav consults the lock database even for PUT (it
# queries lock-null status), so every write returned 500 while reads and PROPFIND kept working.
RUN apk add --no-cache \
      curl \
      rclone \
      samba \
      samba-client \
      samba-common-tools \
      su-exec \
      vsftpd \
    && mkdir -p /opt/omniterm-seed /run/samba /srv/share /var/lib/rclone

COPY smb.conf /etc/samba/smb.conf
COPY vsftpd.conf /etc/vsftpd/vsftpd.conf.template
COPY seed/ /opt/omniterm-seed/
COPY start.sh /usr/local/bin/omniterm-shares

RUN chmod 0755 /usr/local/bin/omniterm-shares

EXPOSE 21 445 8080 21100-21110

ENTRYPOINT ["/usr/local/bin/omniterm-shares"]
