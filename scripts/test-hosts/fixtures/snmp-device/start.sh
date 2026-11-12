#!/bin/sh
# Writes snmpd's configuration from SNMP_COMMUNITY and SNMP_PASSWORD, then runs it in the
# foreground. Read-only: a v2c community and one v3 user (SHA-256, AES), no write access at all.
set -eu
: "${SNMP_COMMUNITY:?}" "${SNMP_PASSWORD:?}"
umask 077
mkdir -p /etc/snmp /var/lib/net-snmp
# An interface that is switched on with no link (omni-up, its veth peer left down) and one switched
# off (omni-down), for the interface readings. Needs NET_ADMIN, which
# docker-compose.yml grants; without it the fixture runs with lo and eth0 only.
if ip link add omni-up type veth peer name omni-down 2>/dev/null; then
  ip link set omni-up up
fi
cat >/etc/snmp/snmpd.conf <<CONF
agentAddress udp:1161
rocommunity $SNMP_COMMUNITY default
rouser omniterm priv
sysName omniterm-snmp-fixture
sysLocation OmniTerm test rack
sysContact fixtures@omniterm.invalid
sysServices 72
# A UPS on battery with a low battery, as RFC 1628 (UPS-MIB) reports one: identity, battery status
# batteryLow(3), 420 s on battery, 7 minutes and 18 % left, input line 1 at 0 V, output source
# battery(5), output line 1 at 230 V and 35 % load. Read-only values, for the UPS readings.
override .1.3.6.1.2.1.33.1.1.1.0 octet_str "OmniTerm"
override .1.3.6.1.2.1.33.1.1.2.0 octet_str "Fixture UPS 1500"
override .1.3.6.1.2.1.33.1.2.1.0 integer 3
override .1.3.6.1.2.1.33.1.2.2.0 integer 420
override .1.3.6.1.2.1.33.1.2.3.0 integer 7
override .1.3.6.1.2.1.33.1.2.4.0 integer 18
override .1.3.6.1.2.1.33.1.3.3.1.3.1 integer 0
override .1.3.6.1.2.1.33.1.4.1.0 integer 5
override .1.3.6.1.2.1.33.1.4.4.1.2.1 integer 230
override .1.3.6.1.2.1.33.1.4.4.1.5.1 integer 35
CONF
# A v3 user is created from the persistent file on start; snmpd replaces the line with its keys.
echo "createUser omniterm SHA-256 \"$SNMP_PASSWORD\" AES \"$SNMP_PASSWORD\"" >/var/lib/net-snmp/snmpd.conf
# snmpd reads /etc/snmp/snmpd.conf by default; naming it again with -c would bind the port twice.
exec snmpd -f -Lo
