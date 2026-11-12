#!/bin/sh
# Writes snmpd's configuration from SNMP_COMMUNITY and SNMP_PASSWORD, then runs it in the
# foreground. Read-only: a v2c community and one v3 user (SHA-256, AES), no write access at all.
set -eu
: "${SNMP_COMMUNITY:?}" "${SNMP_PASSWORD:?}"
umask 077
mkdir -p /etc/snmp /var/lib/net-snmp
cat >/etc/snmp/snmpd.conf <<CONF
agentAddress udp:1161
rocommunity $SNMP_COMMUNITY default
rouser omniterm priv
sysName omniterm-snmp-fixture
sysLocation OmniTerm test rack
sysContact fixtures@omniterm.invalid
sysServices 72
CONF
# A v3 user is created from the persistent file on start; snmpd replaces the line with its keys.
echo "createUser omniterm SHA-256 \"$SNMP_PASSWORD\" AES \"$SNMP_PASSWORD\"" >/var/lib/net-snmp/snmpd.conf
# snmpd reads /etc/snmp/snmpd.conf by default; naming it again with -c would bind the port twice.
exec snmpd -f -Lo
