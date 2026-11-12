# A read-only SNMP agent for OmniTerm's SNMP device suite: net-snmp on the same pinned Alpine as the
# runtime hosts. The community and the v3 password come from the environment at start (see start.sh).
FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
RUN apk add --no-cache net-snmp
COPY start.sh /usr/local/bin/omniterm-snmp-device
RUN chmod 0755 /usr/local/bin/omniterm-snmp-device
EXPOSE 1161/udp
CMD ["/usr/local/bin/omniterm-snmp-device"]
