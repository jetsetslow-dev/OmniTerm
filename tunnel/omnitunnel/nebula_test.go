package omnitunnel

import (
	"context"
	"errors"
	"io"
	"net"
	"net/netip"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/DefinedNet/dnsconfig"
	neb "github.com/slackhq/nebula"
	"github.com/slackhq/nebula/cert"
	"github.com/slackhq/nebula/cert_test"
	"github.com/slackhq/nebula/config"
	"github.com/slackhq/nebula/logging"
	"github.com/slackhq/nebula/overlay"
	"github.com/slackhq/nebula/service"
	"go.yaml.in/yaml/v3"
)

func nebulaIdentity(t *testing.T, ca cert.Certificate, caKey []byte, address string, v cert.Version) string {
	t.Helper()
	_, _, key, pem := cert_test.NewTestCert(v, cert.Curve_CURVE25519, ca, caKey, "phone", time.Now().Add(-time.Minute), time.Now().Add(time.Hour), []netip.Prefix{netip.MustParsePrefix(address)}, nil, nil)
	caPEM, err := ca.MarshalPEM()
	if err != nil {
		t.Fatal(err)
	}
	raw, err := yaml.Marshal(map[string]any{
		"pki":             map[string]string{"ca": string(caPEM), "cert": string(pem), "key": string(key)},
		"static_host_map": map[string][]string{"10.88.0.1": {"127.0.0.1:4242"}},
		"lighthouse":      map[string]any{"hosts": []string{"10.88.0.1"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// nebulaDualIdentity is nebulaIdentity with a v1 and a v2 certificate of one key under pki.cert,
// as a network moving from v1 to v2 gives its nodes. A v1Address gives the v1 certificate, same
// key, another first address instead, which Nebula refuses.
func nebulaDualIdentity(t *testing.T, ca cert.Certificate, caKey []byte, address string, v1Address ...string) string {
	t.Helper()
	v2, _, key, v2PEM := cert_test.NewTestCert(cert.Version2, cert.Curve_CURVE25519, ca, caKey, "phone", time.Now().Add(-time.Minute), time.Now().Add(time.Hour), []netip.Prefix{netip.MustParsePrefix(address)}, nil, nil)
	_, v1PEM := cert_test.NewTestCertDifferentVersion(v2, cert.Version1, ca, caKey)
	for _, other := range v1Address {
		v1, err := (&cert.TBSCertificate{
			Version: cert.Version1, Curve: v2.Curve(), Name: v2.Name(), PublicKey: v2.PublicKey(),
			Networks:  []netip.Prefix{netip.MustParsePrefix(other)},
			NotBefore: time.Unix(v2.NotBefore().Unix(), 0), NotAfter: time.Unix(v2.NotAfter().Unix(), 0),
		}).Sign(ca, ca.Curve(), caKey)
		if err != nil {
			t.Fatal(err)
		}
		if v1PEM, err = v1.MarshalPEM(); err != nil {
			t.Fatal(err)
		}
	}
	return withNebulaSettings(t, nebulaIdentity(t, ca, caKey, address, cert.Version2), func(s map[string]any) {
		pki := s["pki"].(map[string]any)
		pki["cert"], pki["key"] = string(v1PEM)+string(v2PEM), string(key)
	})
}

func nebulaCA() (cert.Certificate, []byte) {
	ca, _, key, _ := cert_test.NewTestCaCert(cert.Version2, cert.Curve_CURVE25519, time.Now().Add(-time.Hour), time.Now().Add(2*time.Hour), nil, nil, nil)
	return ca, key
}

func TestNebulaInlineIdentityValidation(t *testing.T) {
	ca, key := nebulaCA()
	text := nebulaIdentity(t, ca, key, "10.88.0.2/24", cert.Version2)
	own, err := parseNebula(text)
	if err != nil {
		t.Fatal(err)
	}
	ownFingerprint, err := own.identity.Fingerprint()
	if err != nil {
		t.Fatal(err)
	}
	dual := nebulaDualIdentity(t, ca, key, "10.88.0.2/24")
	otherKey := nebulaDualIdentity(t, ca, key, "10.88.0.2/24")
	var otherCerts nebulaInput
	if err := yaml.Unmarshal([]byte(otherKey), &otherCerts); err != nil {
		t.Fatal(err)
	}
	v1Of := func(text string) string { return text[:strings.Index(text, "-----BEGIN NEBULA CERTIFICATE V2")] }
	pkiOf := func(text string, change func(map[string]any)) string {
		return withNebulaSettings(t, text, func(s map[string]any) { change(s["pki"].(map[string]any)) })
	}
	blocklist := func(entries ...string) string {
		return withNebulaSettings(t, text, func(s map[string]any) { s["pki"].(map[string]any)["blocklist"] = entries })
	}
	for name, conf := range map[string]string{
		"valid":            text,
		"v1":               nebulaIdentity(t, ca, key, "10.88.0.3/24", cert.Version1),
		"chachapoly":       text + "cipher: chachapoly\n",
		"other revocation": blocklist(strings.Repeat("ab", 32)),
		// A real network names its lighthouse; the phone's DNS finds it when the tunnel starts.
		"endpoint DNS":           strings.ReplaceAll(text, "127.0.0.1:4242", "lighthouse.example.com:4242"),
		"endpoint IPv6":          strings.ReplaceAll(text, "127.0.0.1:4242", "'[2001:db8::1]:4242'"),
		"v1 and v2":              dual,
		"v1 and v2, initiate v2": withNebulaSettings(t, dual, func(s map[string]any) { s["pki"].(map[string]any)["initiating_version"] = 2 }),
		"v1 and v2, initiate v1": withNebulaSettings(t, dual, func(s map[string]any) { s["pki"].(map[string]any)["initiating_version"] = 1 }),
	} {
		t.Run(name, func(t *testing.T) {
			if message := CheckNebula(conf); message != "" {
				t.Fatal(message)
			}
		})
	}
	for name, conf := range map[string]string{
		"file path":             "pki: {ca: /tmp/never-open, cert: /tmp/never-open, key: /tmp/never-open}",
		"unsafe routes":         text + "tun: {unsafe_routes: [{route: 192.0.2.0/24, via: 10.88.0.1}]}\n",
		"bad key":               strings.Replace(text, "NEBULA X25519 PRIVATE KEY", "NEBULA INVALID PRIVATE KEY", -1),
		"wrong CA":              strings.Replace(text, "NEBULA CERTIFICATE V2", "INVALID CA", 1),
		"multiple documents":    text + "\n---\n" + text,
		"duplicate keys":        text + "pki: {}\n",
		"oversized":             strings.Repeat("#", 65537),
		"outside static host":   strings.Replace(text, "10.88.0.1:", "192.0.2.1:", 1),
		"endpoint name not DNS": strings.ReplaceAll(text, "127.0.0.1:4242", "lighthouse_1.example:4242"),
		"endpoint single label": strings.ReplaceAll(text, "127.0.0.1:4242", "lighthouse:4242"),
		"endpoint without port": strings.ReplaceAll(text, "127.0.0.1:4242", "lighthouse.example.com"),
		"endpoint port zero":    strings.ReplaceAll(text, "127.0.0.1:4242", "lighthouse.example.com:0"),
		"endpoint URL":          strings.ReplaceAll(text, "127.0.0.1:4242", "'https://lighthouse.example.com:4242'"),
		"two v2 certificates":   pkiOf(text, func(p map[string]any) { p["cert"] = p["cert"].(string) + p["cert"].(string) }),
		"v1 and v2 of other keys": pkiOf(dual, func(p map[string]any) {
			p["cert"] = v1Of(otherCerts.PKI.Cert) + p["cert"].(string)[len(v1Of(p["cert"].(string))):]
		}),
		"v1 and v2 of other first addresses": nebulaDualIdentity(t, ca, key, "10.88.0.2/24", "10.88.0.5/24"),
		"initiate v1 without v1":             pkiOf(text, func(p map[string]any) { p["initiating_version"] = 1 }),
		"initiate v3":                        pkiOf(dual, func(p map[string]any) { p["initiating_version"] = 3 }),
		"missing lighthouse endpoint":        strings.Replace(text, "hosts:", "hosts: [10.88.0.9]\n  ignored:", 1),
		"unknown cipher":                     text + "cipher: des\n",
		"malformed blocklist":                blocklist("not-a-fingerprint"),
		"own certificate revoked":            blocklist(ownFingerprint),
	} {
		t.Run(name, func(t *testing.T) {
			if CheckNebula(conf) == "" {
				t.Fatal("unsafe configuration accepted")
			}
		})
	}
}

func TestNebulaDiscardsDeviceListenersAndFirewall(t *testing.T) {
	ca, key := nebulaCA()
	text := nebulaIdentity(t, ca, key, "10.88.0.2/24", cert.Version2) + `
tun: {dev: /dev/net/tun, disabled: true}
listen: {host: 192.0.2.10, port: 9876}
firewall: {inbound: [{port: any, proto: any, host: any}]}
sshd: {enabled: true, host_key: /tmp/never-open, listen: '0.0.0.0:2222'}
stats: {type: prometheus, listen: '0.0.0.0:9999'}
dns: {enabled: true, nameservers: [192.0.2.1]}
control: {enabled: true, path: /tmp/never-open}
relay: {am_relay: true}
logging: {level: debug}
`
	c, err := parseNebula(text)
	if err != nil {
		t.Fatal(err)
	}
	run, err := c.runtime(c.input.StaticHostMap)
	if err != nil {
		t.Fatal(err)
	}
	if run.GetBool("tun.disabled", true) || run.GetString("tun.dev", "") != "" || run.GetInt("listen.port", -1) != 0 || run.GetString("listen.host", "") != "0.0.0.0" {
		t.Fatal("import can open a device or choose a transport listener")
	}
	for _, key := range []string{"sshd", "stats", "dns", "control", "relay", "logging"} {
		if run.IsSet(key) {
			t.Fatalf("import enabled %s", key)
		}
	}
	if len(run.Get("firewall.inbound").([]any)) != 0 {
		t.Fatal("import allows incoming connections")
	}
	// This upstream dependency must stay a no-op on Android/Linux: Main invokes DNS recovery even
	// with dns.enabled false. A future library upgrade must not acquire system DNS ownership.
	if runtime.GOOS == "linux" || runtime.GOOS == "android" {
		if dnsconfig.Detect() != dnsconfig.BackendNoop {
			t.Fatal("Nebula can change system DNS")
		}
	}
}

func TestOnlyTheNebulaNetworkIsDialledNeverTheDirectAddress(t *testing.T) {
	ca, key := nebulaCA()
	text := nebulaIdentity(t, ca, key, "10.88.0.2/24", cert.Version2)
	tunnel, err := StartNebula(text, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tunnel.Close()
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	port := ln.Addr().(*net.TCPAddr).Port
	for _, address := range []string{"127.0.0.1", "::ffff:127.0.0.1", "192.0.2.1", "localhost", "[::1]"} {
		if fd, err := tunnel.DialFd(address, port, 200); err == nil {
			t.Fatalf("dialled outside network at %s (fd %d)", address, fd)
		} else if address != "localhost" && !strings.Contains(err.Error(), "outside") {
			t.Fatalf("outside address was offered to a dialer: %v", err)
		}
	}
	ln.(*net.TCPListener).SetDeadline(time.Now().Add(100 * time.Millisecond))
	if conn, err := ln.Accept(); err == nil {
		conn.Close()
		t.Fatal("direct listener received a connection")
	}
}

// startNebulaPeer runs a userspace lighthouse at 10.88.0.1 that echoes TCP port 22 and returns its
// parsed identity, its service and a phone configuration that reaches it. adjust may change the
// peer's runtime settings, such as the network's cipher.
func startNebulaPeer(t *testing.T, ca cert.Certificate, caKey []byte, adjust func(*config.C)) (*nebulaConfig, *service.Service, string) {
	t.Helper()
	return startNebulaPeerVersion(t, ca, caKey, cert.Version2, adjust)
}

// startNebulaPeerVersion is startNebulaPeer with a peer certificate of version.
func startNebulaPeerVersion(t *testing.T, ca cert.Certificate, caKey []byte, version cert.Version, adjust func(*config.C)) (*nebulaConfig, *service.Service, string) {
	t.Helper()
	peerConf, err := parseNebula(nebulaIdentity(t, ca, caKey, "10.88.0.1/24", version))
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := peerConf.runtime(peerConf.input.StaticHostMap)
	if err != nil {
		t.Fatal(err)
	}
	udpPort := reserveNebulaPort(t)
	cfg.Settings["listen"] = map[string]any{"host": "127.0.0.1", "port": udpPort}
	cfg.Settings["lighthouse"] = map[string]any{"am_lighthouse": true}
	cfg.Settings["static_host_map"] = map[string]any{}
	cfg.Settings["firewall"] = map[string]any{"inbound": []any{map[string]any{"port": "any", "proto": "tcp", "host": "any"}}, "outbound": []any{map[string]any{"port": "any", "proto": "any", "host": "any"}}}
	if adjust != nil {
		adjust(cfg)
	}
	control, err := neb.Main(cfg, false, "test", logging.NewLogger(io.Discard), overlay.NewUserDeviceFromConfig)
	if err != nil {
		t.Fatal(err)
	}
	peer, err := service.New(control)
	if err != nil {
		control.Stop()
		t.Fatal(err)
	}
	t.Cleanup(func() { peer.Close(); peer.Wait() })
	ln, err := peer.Listen("tcp4", ":22")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func() { defer conn.Close(); _, _ = io.Copy(conn, conn) }()
		}
	}()
	phone := strings.ReplaceAll(nebulaIdentity(t, ca, caKey, "10.88.0.2/24", cert.Version2), "127.0.0.1:4242", net.JoinHostPort("127.0.0.1", strconv.Itoa(udpPort)))
	return peerConf, peer, phone
}

// nebulaEcho sends a few bytes to the peer's echo port through the tunnel and checks the reply.
func nebulaEcho(n *nebula, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	conn, err := n.dial(ctx, "10.88.0.1", 22, time.Now().Add(timeout))
	cancel()
	if err != nil {
		return err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := conn.Write([]byte("nebula")); err != nil {
		return err
	}
	got := make([]byte, 6)
	if _, err := io.ReadFull(conn, got); err != nil {
		return err
	} else if string(got) != "nebula" {
		return errors.New("echo returned different bytes")
	}
	return nil
}

// withNebulaSettings rewrites a generated YAML configuration through a map.
func withNebulaSettings(t *testing.T, text string, change func(map[string]any)) string {
	t.Helper()
	var settings map[string]any
	if err := yaml.Unmarshal([]byte(text), &settings); err != nil {
		t.Fatal(err)
	}
	change(settings)
	raw, err := yaml.Marshal(settings)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

func TestNebulaUserspaceRoundTripAndNetworkChange(t *testing.T) {
	ca, key := nebulaCA()
	_, peer, text := startNebulaPeer(t, ca, key, nil)
	tunnel, err := StartNebula(text, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tunnel.Close()
	n := tunnel.carrier.(*nebula)
	for _, change := range []bool{false, true} {
		if change {
			NetworkChanged("test-network")
		}
		if err := nebulaEcho(n, 10*time.Second); err != nil {
			t.Fatalf("userspace TCP failed: %v", err)
		}
	}
	if n.bytesIn() != 12 || n.bytesOut() != 12 || n.lastHandshake() != 0 || n.addresses() != "10.88.0.2" || n.state() != StateRunning {
		t.Fatal("incorrect on-demand status")
	}
	// The app never opens a listener in the service, even if the import asked for one.
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if conn, err := peer.DialContext(ctx, "tcp", "10.88.0.2:22"); err == nil {
		conn.Close()
		t.Fatal("phone accepts incoming TCP")
	}
	tunnel.Close()
	if _, found := nebulaNodes.Load(n); found || n.state() != StateFailed {
		t.Fatal("closed tunnel retained")
	}
}

// Every node of a network must share its cipher, and a revoked certificate must not be trusted.
func TestNebulaUsesTheNetworksCipherAndBlocklist(t *testing.T) {
	ca, key := nebulaCA()
	_, _, phone := startNebulaPeer(t, ca, key, func(c *config.C) { c.Settings["cipher"] = "chachapoly" })
	tunnel, err := StartNebula(phone+"cipher: chachapoly\n", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tunnel.Close()
	if err := nebulaEcho(tunnel.carrier.(*nebula), 10*time.Second); err != nil {
		t.Fatalf("a chachapoly network was unreachable: %v", err)
	}

	peerConf, _, phone := startNebulaPeer(t, ca, key, nil)
	revoked, err := peerConf.identity.Fingerprint()
	if err != nil {
		t.Fatal(err)
	}
	blocked := withNebulaSettings(t, phone, func(s map[string]any) {
		s["pki"].(map[string]any)["blocklist"] = []string{strings.ToUpper(revoked)}
	})
	tunnel, err = StartNebula(blocked, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tunnel.Close()
	if err := nebulaEcho(tunnel.carrier.(*nebula), 3*time.Second); err == nil {
		t.Fatal("connected to a peer whose certificate is on pki.blocklist")
	}
}

func reserveNebulaPort(t *testing.T) int {
	t.Helper()
	conn, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	return conn.LocalAddr().(*net.UDPAddr).Port
}

// A certificate can even cover loopback: it still cannot turn the service into a system dialer.
func TestNebulaNeverUsesTheSystemDialerEvenForAnAllowedAddress(t *testing.T) {
	ca, key := nebulaCA()
	text := nebulaIdentity(t, ca, key, "127.0.0.2/8", cert.Version2)
	text = strings.ReplaceAll(text, "10.88.0.1", "127.0.0.1")
	tunnel, err := StartNebula(text, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tunnel.Close()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if _, err := tunnel.DialFd("127.0.0.1", listener.Addr().(*net.TCPAddr).Port, 200); err == nil {
		t.Fatal("used the system dialer for an address allowed by the certificate")
	}
	listener.(*net.TCPListener).SetDeadline(time.Now().Add(100 * time.Millisecond))
	if conn, err := listener.Accept(); err == nil {
		conn.Close()
		t.Fatal("system listener received tunnel traffic")
	}
}

type networkChangeControl struct{ calls atomic.Int64 }

func (c *networkChangeControl) State() neb.RunState { return neb.StateStarted }
func (c *networkChangeControl) RebindUDPServer()    { c.calls.Add(1) }

func TestNebulaNetworkNotificationsRebindOnlyLiveNodes(t *testing.T) {
	control := &networkChangeControl{}
	node := &nebula{control: control}
	nebulaNodes.Store(node, struct{}{})
	defer nebulaNodes.Delete(node)
	NetworkChanged("wlan0")
	if control.calls.Load() != 1 {
		t.Fatal("live Nebula node missed the network change")
	}
	nebulaNodes.Delete(node)
	NetworkChanged("rmnet0")
	if control.calls.Load() != 1 {
		t.Fatal("closed Nebula node was rebound")
	}
}

func TestNebulaRejectsMismatchedAndExpiredIdentityMaterial(t *testing.T) {
	ca, key := nebulaCA()
	text := nebulaIdentity(t, ca, key, "10.88.0.2/24", cert.Version2)
	var first, second nebulaInput
	if err := yaml.Unmarshal([]byte(text), &first); err != nil {
		t.Fatal(err)
	}
	if err := yaml.Unmarshal([]byte(nebulaIdentity(t, ca, key, "10.88.0.3/24", cert.Version2)), &second); err != nil {
		t.Fatal(err)
	}
	first.PKI.Key = second.PKI.Key
	raw, err := yaml.Marshal(first)
	if err != nil {
		t.Fatal(err)
	}
	if CheckNebula(string(raw)) == "" {
		t.Fatal("mismatched private key accepted")
	}
	var in nebulaInput
	if err := yaml.Unmarshal([]byte(text), &in); err != nil {
		t.Fatal(err)
	}
	otherCA, _ := nebulaCA()
	otherPEM, _ := otherCA.MarshalPEM()
	in.PKI.CA = string(otherPEM)
	raw, err = yaml.Marshal(in)
	if err != nil {
		t.Fatal(err)
	}
	if CheckNebula(string(raw)) == "" {
		t.Fatal("certificate signed by a different CA accepted")
	}
	_, _, expiredKey, expiredPEM := cert_test.NewTestCert(cert.Version2, cert.Curve_CURVE25519, ca, key, "expired", time.Now().Add(-time.Hour), time.Now().Add(-time.Minute), []netip.Prefix{netip.MustParsePrefix("10.88.0.2/24")}, nil, nil)
	if err := yaml.Unmarshal([]byte(text), &in); err != nil {
		t.Fatal(err)
	}
	in.PKI.Cert, in.PKI.Key = string(expiredPEM), string(expiredKey)
	raw, err = yaml.Marshal(in)
	if err != nil {
		t.Fatal(err)
	}
	if CheckNebula(string(raw)) == "" {
		t.Fatal("expired certificate accepted")
	}
	c, err := parseNebula(text)
	if err != nil {
		t.Fatal(err)
	}
	expired, _, err := cert.UnmarshalCertificateFromPEM(expiredPEM)
	if err != nil {
		t.Fatal(err)
	}
	c.identity = expired
	node := &nebula{control: &networkChangeControl{}, config: c}
	if node.state() != StateFailed || node.problem() == "" {
		t.Fatal("expired running node still accepted")
	}
	if conn, err := node.dial(context.Background(), "10.88.0.1", 22, time.Now()); err == nil {
		conn.Close()
		t.Fatal("expired node dialled")
	}
}

// changingResolver is the phone's DNS, whose answer for a name changes with the network.
type changingResolver struct {
	mu     sync.Mutex
	answer string
	asked  []string
}

func (r *changingResolver) Resolve(host string) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.asked = append(r.asked, host)
	if r.answer == "" {
		return "", errors.New("NXDOMAIN")
	}
	return r.answer, nil
}

func (r *changingResolver) set(answer string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.answer = answer
}

// A lighthouse given by name is looked up with the phone's DNS when the tunnel starts and again
// after a network change, where it can have another address. The name is not in any real DNS, so
// reaching the peer at all proves neither Nebula nor Go looked it up themselves.
func TestNebulaStaticHostNamesUseThePhonesDNSAndFollowNetworkChanges(t *testing.T) {
	ca, key := nebulaCA()
	_, _, phone := startNebulaPeer(t, ca, key, nil)
	named := strings.ReplaceAll(phone, "127.0.0.1:", "lighthouse.nebula.invalid:")
	if _, err := StartNebula(named, nil); err == nil || !strings.Contains(err.Error(), "could be found") {
		t.Fatalf("a name was looked up without the phone's DNS: %v", err)
	}
	// On the first network the name points where no lighthouse answers.
	resolver := &changingResolver{answer: "127.0.0.3"}
	tunnel, err := StartNebula(named, resolver)
	if err != nil {
		t.Fatal(err)
	}
	defer tunnel.Close()
	n := tunnel.carrier.(*nebula)
	if err := nebulaEcho(n, 2*time.Second); err == nil {
		t.Fatal("reached the lighthouse at an address the phone's DNS did not give")
	}
	resolver.set("127.0.0.1")
	NetworkChanged("wlan1")
	deadline := time.Now().Add(20 * time.Second)
	for err := nebulaEcho(n, 3*time.Second); err != nil; err = nebulaEcho(n, 3*time.Second) {
		if time.Now().After(deadline) {
			t.Fatalf("the lighthouse's new address was not used after the network changed: %v", err)
		}
	}
	resolver.mu.Lock()
	defer resolver.mu.Unlock()
	for _, host := range resolver.asked {
		if host != "lighthouse.nebula.invalid" {
			t.Fatalf("the phone's DNS was asked for %q", host)
		}
	}
	if len(resolver.asked) < 2 {
		t.Fatal("the name was not looked up again after the network changed")
	}
}

// A node with a v1 and a v2 certificate reaches peers that have either, as Nebula's own does.
func TestNebulaWithV1AndV2CertificatesReachesPeersOfEitherVersion(t *testing.T) {
	ca, key := nebulaCA()
	for _, version := range []cert.Version{cert.Version1, cert.Version2} {
		t.Run("v"+strconv.Itoa(int(version)), func(t *testing.T) {
			_, _, phone := startNebulaPeerVersion(t, ca, key, version, nil)
			port := phone[strings.Index(phone, "127.0.0.1:")+len("127.0.0.1:"):]
			port = port[:strings.IndexAny(port, "\n'\"")]
			dual := strings.ReplaceAll(nebulaDualIdentity(t, ca, key, "10.88.0.2/24"), "127.0.0.1:4242", "127.0.0.1:"+port)
			tunnel, err := StartNebula(dual, nil)
			if err != nil {
				t.Fatal(err)
			}
			defer tunnel.Close()
			if err := nebulaEcho(tunnel.carrier.(*nebula), 10*time.Second); err != nil {
				t.Fatalf("a v%d peer was unreachable: %v", version, err)
			}
		})
	}
}

// Configurations with one first Nebula address are one node, even with other settings or another
// key (a reissued certificate): its peers would take either's handshake for the other's. Another
// address is another node, and an invalid configuration is none.
func TestNebulaNodeIdentity(t *testing.T) {
	ca, key := nebulaCA()
	dual := nebulaDualIdentity(t, ca, key, "10.88.0.2/24")
	v2Only := withNebulaSettings(t, dual, func(s map[string]any) {
		pki := s["pki"].(map[string]any)
		pki["cert"] = pki["cert"].(string)[strings.Index(pki["cert"].(string), "-----BEGIN NEBULA CERTIFICATE V2"):]
	})
	node := NebulaNode(dual)
	reissued := nebulaDualIdentity(t, ca, key, "10.88.0.2/24")
	if node != "nebula:10.88.0.2" || NebulaNode(dual+"cipher: chachapoly\n") != node || NebulaNode(v2Only) != node || NebulaNode(reissued) != node {
		t.Fatal("one node's configurations differ")
	}
	if NebulaNode(nebulaDualIdentity(t, ca, key, "10.88.0.5/24")) == node || NebulaNode("pki: {}") != "" {
		t.Fatal("another node or an invalid configuration matched")
	}
}

func TestNebulaValidationDoesNotEchoPrivateInput(t *testing.T) {
	if message := CheckNebula("pki: sensitive\n"); message == "" || strings.Contains(message, "sensitive") {
		t.Fatal("validation echoed private input or accepted invalid YAML")
	}
}
