package omnitunnel

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
	"tailscale.com/derp/derpserver"
	"tailscale.com/ipn"
	"tailscale.com/ipn/store/mem"
	"tailscale.com/net/netns"
	"tailscale.com/net/stun/stuntest"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/dnstype"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
	"tailscale.com/types/nettype"
)

// The far side of these tests is a real Tailscale control server, DERP relay and peer, all in this
// process: tailscale.com's own test control server (testcontrol), as tsnet's tests use it.

const testKey = "tskey-auth-omniterm-test"

func startTestControl(t *testing.T, configure func(*testcontrol.Server)) *testcontrol.Server {
	t.Helper()
	netns.SetEnabled(false)
	t.Cleanup(func() { netns.SetEnabled(true) })
	control := &testcontrol.Server{
		DERPMap:        startTestRelay(t),
		DNSConfig:      &tailcfg.DNSConfig{Proxied: true},
		MagicDNSDomain: "lab.ts.net",
		Logf:           logger.Discard,
	}
	if configure != nil {
		configure(control)
	}
	control.HTTPTestServer = httptest.NewUnstartedServer(control)
	control.HTTPTestServer.Start()
	t.Cleanup(control.HTTPTestServer.Close)
	return control
}

// startTestRelay runs a DERP relay and a STUN server on loopback, as the tailnet's only region.
func startTestRelay(t *testing.T) *tailcfg.DERPMap {
	t.Helper()
	d := derpserver.New(key.NewNode(), logger.Discard)
	srv := httptest.NewUnstartedServer(derpserver.Handler(d))
	srv.Config.TLSNextProto = map[string]func(*http.Server, *tls.Conn, http.Handler){}
	srv.StartTLS()
	stunAddr, stunDone := stuntest.ServeWithPacketListener(t, nettype.Std{})
	t.Cleanup(func() {
		srv.CloseClientConnections()
		srv.Close()
		d.Close()
		stunDone()
	})
	return &tailcfg.DERPMap{Regions: map[tailcfg.DERPRegionID]*tailcfg.DERPRegion{
		1: {RegionID: 1, RegionCode: "test", Nodes: []*tailcfg.DERPNode{{
			Name: "t1", RegionID: 1, HostName: "127.0.0.1", IPv4: "127.0.0.1", IPv6: "none",
			STUNPort: stunAddr.Port, DERPPort: srv.Listener.Addr().(*net.TCPAddr).Port,
			InsecureForTests: true, STUNTestIP: "127.0.0.1",
		}}},
	}}
}

// startTestPeer is a node in the tailnet named "server" with an echo service on its port 22, the
// way the device fixture's node leads to internal-a.
func startTestPeer(t *testing.T, control *testcontrol.Server, authKey string) string {
	t.Helper()
	ip, _ := startTestRouter(t, control, authKey, false)
	return ip
}

// The subnet the test router offers, an address in it, the tailnet domain its DNS server answers
// for, and an address in no route.
const (
	testSubnet    = "10.123.0.0/24"
	testBehind    = "10.123.0.5"
	testLanDomain = "lab.internal"
	testNowhere   = "10.124.0.5"
)

// startTestRouter is startTestPeer, and with route also a subnet router for [testSubnet] with a DNS
// server on its tailnet address that answers for router.[testLanDomain] with [testBehind], the way
// a homelab's LAN and its DNS sit behind one. (Connections over the route are carried end to end
// on the device, against a real tailscaled subnet router: E2eTailscaleTunnelTest.)
func startTestRouter(t *testing.T, control *testcontrol.Server, authKey string, route bool) (string, *tsnet.Server) {
	t.Helper()
	s := &tsnet.Server{
		Dir:        t.TempDir(),
		ControlURL: control.HTTPTestServer.URL,
		Hostname:   "server",
		Store:      new(mem.Store),
		Ephemeral:  true,
		AuthKey:    authKey,
		UserLogf:   logger.Discard,
	}
	t.Cleanup(func() { s.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	status, err := s.Up(ctx)
	if err != nil {
		t.Fatal(err)
	}
	echoOn(t, s, ":22")
	ip := status.TailscaleIPs[0]
	if route {
		prefix := netip.MustParsePrefix(testSubnet)
		lc, err := s.LocalClient()
		if err != nil {
			t.Fatal(err)
		}
		if _, err := lc.EditPrefs(ctx, &ipn.MaskedPrefs{
			Prefs: ipn.Prefs{AdvertiseRoutes: []netip.Prefix{prefix}}, AdvertiseRoutesSet: true,
		}); err != nil {
			t.Fatal(err)
		}
		control.SetSubnetRoutes(status.Self.PublicKey, []netip.Prefix{prefix})
		pc, err := s.ListenPacket("udp", net.JoinHostPort(ip.String(), "53"))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { pc.Close() })
		go answerDNS(pc)
	}
	return ip.String(), s
}

func echoOn(t *testing.T, s *tsnet.Server, addr string) {
	t.Helper()
	ln, err := s.Listen("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				io.Copy(c, c)
			}()
		}
	}()
}

// answerDNS answers router.[testLanDomain] with [testBehind], and any other name with no such name.
func answerDNS(pc net.PacketConn) {
	buf := make([]byte, 1500)
	for {
		n, from, err := pc.ReadFrom(buf)
		if err != nil {
			return
		}
		var p dnsmessage.Parser
		h, err := p.Start(buf[:n])
		if err != nil {
			continue
		}
		q, err := p.Question()
		if err != nil {
			continue
		}
		h.Response, h.Authoritative = true, true
		b := dnsmessage.NewBuilder(nil, h)
		b.StartQuestions()
		b.Question(q)
		b.StartAnswers()
		switch {
		case !strings.EqualFold(q.Name.String(), "router."+testLanDomain+"."):
			h.RCode = dnsmessage.RCodeNameError
			b = dnsmessage.NewBuilder(nil, h)
			b.StartQuestions()
			b.Question(q)
		case q.Type == dnsmessage.TypeA:
			b.AResource(dnsmessage.ResourceHeader{Name: q.Name, Class: dnsmessage.ClassINET, TTL: 60},
				dnsmessage.AResource{A: netip.MustParseAddr(testBehind).As4()})
		}
		if out, err := b.Finish(); err == nil {
			pc.WriteTo(out, from)
		}
	}
}

// memoryStore is the app's side of the state store: what Kotlin encrypts and keeps.
type memoryStore struct {
	mu    sync.Mutex
	blob  string
	saves int
	full  bool // the app cannot keep what it is given
}

func (m *memoryStore) Load() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.blob
}

func (m *memoryStore) Save(state string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.full {
		return errors.New("disk full")
	}
	m.blob = state
	m.saves++
	return nil
}

func tsConf(control *testcontrol.Server, authKey string) string {
	return `{"controlUrl":"` + control.HTTPTestServer.URL + `","authKey":"` + authKey + `","hostname":"phone"}`
}

// echoThrough dials host:22 through the tunnel and checks the echo comes back.
func echoThrough(t *testing.T, tun *Tunnel, host string) {
	t.Helper()
	fd, err := tun.DialFd(host, 22, 20_000)
	if err != nil {
		t.Fatalf("dial %s: %v", host, err)
	}
	f := fileOf(t, fd)
	defer f.Close()
	if _, err := f.Write([]byte("hello " + host)); err != nil {
		t.Fatal(err)
	}
	f.SetReadDeadline(time.Now().Add(10 * time.Second))
	buf := make([]byte, len("hello "+host))
	if _, err := io.ReadFull(f, buf); err != nil {
		t.Fatalf("echo from %s: %v", host, err)
	}
	if string(buf) != "hello "+host {
		t.Fatalf("echo from %s: got %q", host, buf)
	}
}

func TestATailscaleTunnelSignsInWithAKeyAndReachesItsPeerByAddressAndName(t *testing.T) {
	control := startTestControl(t, func(c *testcontrol.Server) { c.RequireAuthKey = testKey })
	peer := startTestPeer(t, control, testKey)
	store := &memoryStore{}
	tun, err := StartTailscale(tsConf(control, testKey), t.TempDir(), store, 60_000)
	if err != nil {
		t.Fatal(err)
	}
	defer tun.Close()
	if tun.State() != StateRunning || tun.AuthURL() != "" {
		t.Fatalf("state %q, sign-in %q", tun.State(), tun.AuthURL())
	}
	waitFor(t, func() bool { return strings.HasPrefix(tun.Addresses(), "100.") })
	if !tun.HasDNS() {
		t.Fatal("MagicDNS finds names in the tailnet")
	}
	echoThrough(t, tun, peer)
	echoThrough(t, tun, "server.lab.ts.net")
	echoThrough(t, tun, "server")
	if tun.Connections() != 0 {
		waitFor(t, func() bool { return tun.Connections() == 0 })
	}
}

func TestWithoutAKeyTheTunnelGivesASignInPageAndRunsOnceSignedIn(t *testing.T) {
	control := startTestControl(t, func(c *testcontrol.Server) { c.RequireAuth = true })
	tun, err := StartTailscale(tsConf(control, ""), t.TempDir(), &memoryStore{}, 60_000)
	if err != nil {
		t.Fatal(err)
	}
	defer tun.Close()
	if tun.State() != StateNeedsLogin {
		t.Fatalf("state %q, want %q", tun.State(), StateNeedsLogin)
	}
	link := tun.AuthURL()
	if !strings.HasPrefix(link, control.HTTPTestServer.URL+"/auth/") {
		t.Fatalf("sign-in page %q", link)
	}
	if _, err := tun.DialFd("100.64.0.1", 22, 2_000); err == nil || !strings.Contains(err.Error(), "not signed in") {
		t.Fatalf("a tunnel that is not signed in carries nothing, and says why: %v", err)
	}
	if !control.CompleteAuth(link) {
		t.Fatal("the test control server did not know the sign-in page")
	}
	waitFor(t, func() bool { return tun.State() == StateRunning })
	if tun.AuthURL() != "" {
		t.Fatalf("a signed-in tunnel shows no sign-in page: %q", tun.AuthURL())
	}
}

func TestAKeyTheControlServerRefusesStopsTheStart(t *testing.T) {
	control := startTestControl(t, func(c *testcontrol.Server) { c.RequireAuthKey = testKey })
	_, err := StartTailscale(tsConf(control, "tskey-auth-wrong"), t.TempDir(), &memoryStore{}, 60_000)
	if err == nil || !strings.Contains(err.Error(), "refused") || !strings.Contains(err.Error(), "invalid authkey") {
		t.Fatalf("got %v", err)
	}
}

func TestAControlServerThatDoesNotAnswerStopsTheStart(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	conf := `{"controlUrl":"http://` + addr + `","authKey":"` + testKey + `"}`
	if _, err := StartTailscale(conf, t.TempDir(), &memoryStore{}, 3_000); err == nil || !strings.Contains(err.Error(), "did not answer") {
		t.Fatalf("got %v", err)
	}
}

func TestTheNodeKeepsItsIdentityInTheAppsStoreAndNoFile(t *testing.T) {
	// Every new node signs in through the page here, and a node the server knows needs no sign-in.
	control := startTestControl(t, func(c *testcontrol.Server) { c.RequireAuth = true })
	store := &memoryStore{}
	dir := t.TempDir()
	first, err := StartTailscale(tsConf(control, ""), dir, store, 60_000)
	if err != nil {
		t.Fatal(err)
	}
	if !control.CompleteAuth(first.AuthURL()) {
		t.Fatalf("no sign-in page: %q", first.AuthURL())
	}
	waitFor(t, func() bool { return first.State() == StateRunning && first.Addresses() != "" })
	addrs := first.Addresses()
	first.Close()
	if store.Load() == "" || store.saves == 0 {
		t.Fatal("the node's state went to the app's store")
	}
	if !strings.Contains(store.Load(), `"_machinekey"`) {
		t.Fatalf("the store holds the node's keys: %.80s", store.Load())
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		t.Errorf("nothing is kept in the tunnel's folder, but it holds %s", e.Name())
	}
	// Started again from the same store, it is the same node, and signed in.
	again, err := StartTailscale(tsConf(control, ""), t.TempDir(), store, 60_000)
	if err != nil {
		t.Fatal(err)
	}
	defer again.Close()
	if again.State() != StateRunning || again.AuthURL() != "" {
		t.Fatalf("state %q, sign-in %q: the kept state signs the node in", again.State(), again.AuthURL())
	}
	waitFor(t, func() bool { return again.Addresses() == addrs })
	// A phone without that state is a new device and signs in again.
	fresh, err := StartTailscale(tsConf(control, ""), t.TempDir(), &memoryStore{}, 60_000)
	if err != nil {
		t.Fatal(err)
	}
	defer fresh.Close()
	if fresh.State() != StateNeedsLogin {
		t.Fatalf("a node without the state is new: %q", fresh.State())
	}
}

func TestOnlyTheTailnetIsDialledNeverTheDirectAddress(t *testing.T) {
	control := startTestControl(t, func(c *testcontrol.Server) { c.RequireAuthKey = testKey })
	tun, err := StartTailscale(tsConf(control, testKey), t.TempDir(), &memoryStore{}, 60_000)
	if err != nil {
		t.Fatal(err)
	}
	defer tun.Close()
	// A service on this machine's own address: reachable directly, but not in the tailnet.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	reached := make(chan struct{}, 1)
	go func() {
		if c, err := ln.Accept(); err == nil {
			reached <- struct{}{}
			c.Close()
		}
	}()
	port := ln.Addr().(*net.TCPAddr).Port
	for _, host := range []string{"127.0.0.1", "localhost"} {
		_, err := tun.DialFd(host, port, 3_000)
		if err == nil || !strings.Contains(err.Error(), "is not in this tailnet") {
			t.Fatalf("%s: got %v", host, err)
		}
	}
	select {
	case <-reached:
		t.Fatal("the direct address was dialled")
	case <-time.After(300 * time.Millisecond):
	}
	if _, err := tun.DialFd("no-such-host.lab.ts.net", 22, 3_000); err == nil {
		t.Fatal("a name the tailnet does not have is not dialled")
	}
}

func TestClosingATailscaleTunnelEndsItsConnections(t *testing.T) {
	control := startTestControl(t, func(c *testcontrol.Server) { c.RequireAuthKey = testKey })
	peer := startTestPeer(t, control, testKey)
	tun, err := StartTailscale(tsConf(control, testKey), t.TempDir(), &memoryStore{}, 60_000)
	if err != nil {
		t.Fatal(err)
	}
	fd, err := tun.DialFd(peer, 22, 20_000)
	if err != nil {
		t.Fatal(err)
	}
	f := fileOf(t, fd)
	defer f.Close()
	waitFor(t, func() bool { return tun.Connections() == 1 })
	tun.Close()
	f.SetReadDeadline(time.Now().Add(10 * time.Second))
	if _, err := f.Read(make([]byte, 1)); !errors.Is(err, io.EOF) {
		t.Fatalf("read after close: %v", err)
	}
	if tun.State() != StateFailed {
		t.Fatalf("a closed tunnel is not running: %q", tun.State())
	}
	if _, err := tun.DialFd(peer, 22, 1_000); err == nil {
		t.Fatal("a closed tunnel dials nothing")
	}
}

func TestTailscaleSettingsAreChecked(t *testing.T) {
	for conf, want := range map[string]string{
		`{}`: "",
		`{"controlUrl":"https://headscale.example.com","authKey":"tskey-auth-abc","hostname":"pixel-8"}`: "",
		`{"controlUrl":"http://10.0.2.2:8085/"}`:                                                         "",
		`{"controlUrl":"headscale.example.com"}`:                                                         "control server",
		`{"controlUrl":"ftp://headscale.example.com"}`:                                                   "control server",
		`{"controlUrl":"https://user@headscale.example.com"}`:                                            "control server",
		`{"controlUrl":"https://h.example.com/x?y=1"}`:                                                   "control server",
		`{"authKey":"tskey auth"}`:                                                                       "spaces",
		`{"hostname":"-phone"}`:                                                                          "device name",
		`{"hostname":"my phone"}`:                                                                        "device name",
		`{"hostname":"` + strings.Repeat("a", 64) + `"}`:                                                 "device name",
		`not json`: "could not be read",
	} {
		got := CheckTailscale(conf)
		if (want == "") != (got == "") || !strings.Contains(got, want) {
			t.Errorf("%s: got %q, want %q", conf, got, want)
		}
	}
	c, _ := parseTailscale(`{"controlUrl":" https://h.example.com/ ","hostname":""}`)
	if c.ControlURL != "https://h.example.com" || c.Hostname != DefaultHostname {
		t.Errorf("got %+v", c)
	}
}

func TestTheAppsStoreKeepsEveryKeyInOneBlob(t *testing.T) {
	app := &memoryStore{}
	s := newAppStore(app)
	if _, err := s.ReadState("k"); !errors.Is(err, ipn.ErrStateNotExist) {
		t.Fatalf("got %v", err)
	}
	s.WriteState("k", []byte{1, 2, 3})
	s.WriteState("other", []byte("x"))
	reread := newAppStore(app)
	if bs, err := reread.ReadState("k"); err != nil || string(bs) != "\x01\x02\x03" {
		t.Fatalf("got %v %v", bs, err)
	}
	reread.WriteState("k", nil)
	if _, err := newAppStore(app).ReadState("k"); !errors.Is(err, ipn.ErrStateNotExist) {
		t.Fatalf("a deleted key is gone: %v", err)
	}
	app.blob = "not json"
	if _, err := newAppStore(app).ReadState("other"); !errors.Is(err, ipn.ErrStateNotExist) {
		t.Fatalf("a blob that cannot be read starts afresh: %v", err)
	}
}

func TestInterfacesComeFromTheAppsList(t *testing.T) {
	got := parseInterfaces("wlan0 30 1500 ubm 192.168.1.20/24,fe80::1/64\nlo 1 65536 ul 127.0.0.1/8\nrmnet0 12 1400 up -\nbroken line\n")
	if len(got) != 3 {
		t.Fatalf("got %d interfaces", len(got))
	}
	w := got[0]
	if w.Name != "wlan0" || w.Index != 30 || w.MTU != 1500 || !w.IsUp() || w.Flags&net.FlagMulticast == 0 || w.IsLoopback() {
		t.Fatalf("wlan0: %+v", w.Interface)
	}
	addrs, _ := w.Addrs()
	if len(addrs) != 2 || addrs[0].String() != "192.168.1.20/24" || addrs[1].String() != "fe80::1/64" {
		t.Fatalf("wlan0 addresses: %v", addrs)
	}
	if !got[1].IsLoopback() {
		t.Fatal("lo is the loopback")
	}
	if a, _ := got[2].Addrs(); len(a) != 0 || got[2].Flags&net.FlagPointToPoint == 0 {
		t.Fatalf("rmnet0: %v %v", a, got[2].Flags)
	}
}

func TestRoutesOtherNodesOfferAreUsedAndNothingOutsideThem(t *testing.T) {
	control := startTestControl(t, func(c *testcontrol.Server) { c.RequireAuthKey = testKey })
	peer, _ := startTestRouter(t, control, testKey, true)
	tun, err := StartTailscale(tsConf(control, testKey), t.TempDir(), &memoryStore{}, 60_000)
	if err != nil {
		t.Fatal(err)
	}
	defer tun.Close()
	ts := tun.carrier.(*tailscale)
	// An address behind the router is dialled inside the tailnet, through it.
	waitFor(t, func() bool { return ts.dialer.UseNetstackForIP(netip.MustParseAddr(testBehind)) })
	// An address no node routes is not dialled at all, through the tailnet or around it.
	if _, err := tun.DialFd(testNowhere, 22, 3_000); err == nil || !strings.Contains(err.Error(), "is not in this tailnet") {
		t.Fatalf("%s: got %v", testNowhere, err)
	}
	// The node's own traffic is counted, read when asked for.
	echoThrough(t, tun, peer)
	waitFor(t, func() bool { return tun.BytesOut() > 0 && tun.BytesIn() > 0 && tun.LastHandshake() > 0 })
}

func TestNamesTheTailnetsDNSServersCoverAreAskedOfThem(t *testing.T) {
	// The tailnet sends lab.internal to the router's DNS server, which is only known once it is up.
	server := &dnstype.Resolver{}
	control := startTestControl(t, func(c *testcontrol.Server) {
		c.RequireAuthKey = testKey
		c.DNSConfig.Routes = map[string][]*dnstype.Resolver{testLanDomain: {server}}
	})
	ip, _ := startTestRouter(t, control, testKey, true)
	server.Addr = ip
	control.AddDNSRecords() // sends the tailnet's DNS settings again, with the server's address
	tun, err := StartTailscale(tsConf(control, testKey), t.TempDir(), &memoryStore{}, 60_000)
	if err != nil {
		t.Fatal(err)
	}
	defer tun.Close()
	ts := tun.carrier.(*tailscale)
	var got netip.AddrPort
	waitFor(t, func() bool {
		got, err = ts.resolve(t.Context(), "router."+testLanDomain, 22)
		return err == nil
	})
	if got.String() != net.JoinHostPort(testBehind, "22") {
		t.Fatalf("router.%s: got %v", testLanDomain, got)
	}
	// A name the server does not have is not then looked up with the phone's DNS.
	if _, err := tun.DialFd("missing."+testLanDomain, 22, 5_000); err == nil || !strings.Contains(err.Error(), "tailnet's DNS") {
		t.Fatalf("got %v", err)
	}
	// MagicDNS names still come from the tailnet, and names it does not cover from the phone.
	echoThrough(t, tun, "server.lab.ts.net")
	if got, err := ts.resolve(t.Context(), "localhost", 22); err != nil || !got.Addr().IsLoopback() {
		t.Fatalf("localhost: %v %v", got, err)
	}
}

func TestOnlyTheControlServersRefusalEndsAStart(t *testing.T) {
	for msg, want := range map[string][3]string{
		"invalid authkey": {"invalid authkey", "", ""},
		"node registration rate limited; will retry after 30s": {"", "busy", ""},
		"IPN bus consumer fell behind; closing watch":          {"", "", "again"},
	} {
		refused, note, again := sortBusError(msg, "Headscale")
		if refused != want[0] || (want[1] == "") != (note == "") || !strings.Contains(note, want[1]) || again != (want[2] != "") {
			t.Errorf("%q: refused %q, note %q, again %v", msg, refused, note, again)
		}
	}
}

// A status read asked before the bus said Running, and answered after, said Starting: applied, it
// made a tunnel that had just started refuse its first dial as not connected yet.
func TestAStatusReadOlderThanTheBusDoesNotUndoIt(t *testing.T) {
	ts := &tailscale{changed: make(chan struct{}, 1), wake: make(chan struct{}, 1)}
	ts.mu.Lock()
	defer ts.mu.Unlock()
	before := ts.busStates
	ts.busState(ipn.Running)
	ts.statusState(before, ipn.Starting)
	if ts.st != ipn.Running {
		t.Fatalf("an older status read undid the bus: %v", ts.st)
	}
	// With no news from the bus since it began, a status read is the newest word.
	ts.statusState(ts.busStates, ipn.NeedsLogin)
	if ts.st != ipn.NeedsLogin {
		t.Fatalf("a current status read was ignored: %v", ts.st)
	}
}

func TestAStateTheAppCannotKeepIsReportedToTheNode(t *testing.T) {
	app := &memoryStore{full: true}
	if err := newAppStore(app).WriteState("k", []byte("x")); err == nil {
		t.Fatal("the node is told its state was not kept")
	}
}

func TestASavedStateThatCannotBeReadSignsInAgainAndSaysWhy(t *testing.T) {
	control := startTestControl(t, func(c *testcontrol.Server) { c.RequireAuth = true })
	tun, err := StartTailscale(tsConf(control, ""), t.TempDir(), &memoryStore{blob: "not json"}, 60_000)
	if err != nil {
		t.Fatal(err)
	}
	defer tun.Close()
	if tun.State() != StateNeedsLogin || !strings.Contains(tun.Problem(), "could not be read") {
		t.Fatalf("state %q, problem %q", tun.State(), tun.Problem())
	}
	if !control.CompleteAuth(tun.AuthURL()) {
		t.Fatalf("no sign-in page: %q", tun.AuthURL())
	}
	waitFor(t, func() bool { return tun.State() == StateRunning && tun.Problem() == "" })
}

func TestATunnelStartsWhereThePhoneOffersNoPlaceForLogs(t *testing.T) {
	// As on Android: no home, no cache directory, no usable temporary directory, and "/" as the
	// working directory. The library still asks where its logs would go.
	control := startTestControl(t, func(c *testcontrol.Server) { c.RequireAuthKey = testKey })
	dir := t.TempDir()
	t.Setenv("TS_LOGS_DIR", "")
	t.Setenv("HOME", "")
	t.Setenv("XDG_CACHE_HOME", "")
	t.Setenv("TMPDIR", "/nonexistent-tmp")
	t.Chdir("/")
	tun, err := StartTailscale(tsConf(control, testKey), dir, &memoryStore{}, 60_000)
	if err != nil {
		t.Fatal(err)
	}
	defer tun.Close()
	if tun.State() != StateRunning {
		t.Fatalf("state %q", tun.State())
	}
}
