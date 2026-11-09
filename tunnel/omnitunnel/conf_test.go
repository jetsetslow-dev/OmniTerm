package omnitunnel

import (
	"encoding/base64"
	"encoding/hex"
	"strings"
	"testing"
)

var (
	keyA = base64.StdEncoding.EncodeToString([]byte(strings.Repeat("a", 32)))
	keyB = base64.StdEncoding.EncodeToString([]byte(strings.Repeat("b", 32)))
	keyC = base64.StdEncoding.EncodeToString([]byte(strings.Repeat("c", 32)))
)

func goodConf() string {
	return `# exported from a router
[Interface]
PrivateKey = ` + keyA + `
Address = 10.77.0.2/32, fd77::2/128
DNS = 10.77.0.1, lab.internal
MTU = 1380
PostUp = iptables -A FORWARD -j ACCEPT

[Peer]
PublicKey = ` + keyB + `
PresharedKey = ` + keyC + `
Endpoint = vpn.example.org:51820
AllowedIPs = 10.77.0.0/24, 172.30.0.7
PersistentKeepalive = 25
`
}

func TestAWgQuickFileIsRead(t *testing.T) {
	c, err := parseWireGuard(goodConf())
	if err != nil {
		t.Fatal(err)
	}
	if c.privateKey != hex.EncodeToString([]byte(strings.Repeat("a", 32))) {
		t.Fatal("private key")
	}
	if len(c.addresses) != 2 || c.addresses[0].String() != "10.77.0.2" || c.addresses[1].String() != "fd77::2" {
		t.Fatalf("addresses %v", c.addresses)
	}
	if len(c.dns) != 1 || c.dns[0].String() != "10.77.0.1" {
		t.Fatalf("a search domain is not a server: %v", c.dns)
	}
	if c.mtu != 1380 {
		t.Fatal("mtu")
	}
	p := c.peers[0]
	if p.endpoint != "vpn.example.org:51820" || p.keepalive != 25 || p.presharedKey == "" {
		t.Fatalf("peer %+v", p)
	}
	if got := c.allowedPrefixes(); len(got) != 2 || got[1].String() != "172.30.0.7/32" {
		t.Fatalf("a bare address is one host: %v", got)
	}
	u := c.uapi([]string{"192.0.2.9:51820"})
	for _, want := range []string{"replace_peers=true\n", "endpoint=192.0.2.9:51820\n", "persistent_keepalive_interval=25\n", "allowed_ip=10.77.0.0/24\n", "preshared_key="} {
		if !strings.Contains(u, want) {
			t.Fatalf("uapi lacks %q", want)
		}
	}
	if strings.Contains(u, "iptables") {
		t.Fatal("PostUp is never run or passed on")
	}
}

func TestBadConfigurationsSayWhyWithoutRepeatingAKey(t *testing.T) {
	secret := base64.StdEncoding.EncodeToString([]byte("too short but secret"))
	cases := map[string]string{
		"":                                     "no [Interface]",
		"[Interface]\nAddress = 10.0.0.2/32\n": "no PrivateKey",
		"[Interface]\nPrivateKey = " + secret:  "not a WireGuard key",
		"[Interface]\nPrivateKey = " + keyA:    "no Address",
		"[Interface]\nPrivateKey=" + keyA + "\nAddress=10.0.0.2\n":                                                                   "no [Peer]",
		"[Interface]\nPrivateKey=" + keyA + "\nAddress=10.0.0.2\n[Peer]\nPublicKey=" + keyB + "\nAllowedIPs=10.0.0.0/24\n":           "never connect",
		"[Interface]\nPrivateKey=" + keyA + "\nAddress=10.0.0.2\n[Peer]\nPublicKey=" + keyB + "\nEndpoint=h:1\n":                     "no AllowedIPs",
		"[Interface]\nPrivateKey=" + keyA + "\nAddress=10.0.0.2\n[Peer]\nPublicKey=" + keyB + "\nEndpoint=fe80::1:51820\n":           "brackets",
		"[Interface]\nPrivateKey=" + keyA + "\nAddress=10.0.0.2\n[Peer]\nPublicKey=" + keyB + "\nEndpoint=h:0\nAllowedIPs=0.0.0.0/0": "host:port",
		"[Interface]\nPrivateKey=" + keyA + "\nAddress=10.0.0.2\nMTU=99\n":                                                           "MTU",
		"[Interface]\nPrivateKey=" + keyA + "\nAddress=10.0.0.2\nBogus=1\n":                                                          "bogus is not an [Interface] setting",
		"[Interface]\n[Interface]\n": "second [Interface]",
		"[Wat]\n":                    "only [Interface] and [Peer]",
		"PrivateKey = " + keyA:       "before any",
		"[Interface]\nnonsense\n":    "Key = value",
	}
	for conf, want := range cases {
		msg := CheckWireGuard(conf)
		if !strings.Contains(msg, want) {
			t.Errorf("%q: got %q, want it to say %q", conf, msg, want)
		}
		if strings.Contains(msg, secret) || strings.Contains(msg, keyA) || strings.Contains(msg, keyB) {
			t.Errorf("%q: the message repeats a key: %q", conf, msg)
		}
	}
	if msg := CheckWireGuard(goodConf()); msg != "" {
		t.Fatal(msg)
	}
	if !strings.HasPrefix(CheckWireGuard("[Interface]\nnonsense\n"), "Line 2: ") {
		t.Fatal("the line is named")
	}
}

func TestEndpointsAndPrefixes(t *testing.T) {
	for in, want := range map[string]string{"[2001:db8::1]:51820": "[2001:db8::1]:51820", "1.2.3.4:5": "1.2.3.4:5", "host.example:443": "host.example:443"} {
		h, p, err := splitEndpoint(in)
		if err != nil || joinHostPort(h, p) != want {
			t.Errorf("%s: %s %d %v", in, h, p, err)
		}
	}
	if p, _ := prefixOf("10.1.2.3/8"); p.String() != "10.0.0.0/8" {
		t.Fatalf("masked: %s", p)
	}
}
