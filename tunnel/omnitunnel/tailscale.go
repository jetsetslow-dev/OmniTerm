package omnitunnel

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/dns/dnsmessage"
	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/net/dns"
	"tailscale.com/net/tsdial"
	"tailscale.com/tsnet"
	"tailscale.com/types/logger"
	"tailscale.com/util/dnsname"
)

// StateStore keeps a Tailscale node's state (its keys and its sign-in) for the app, which encrypts
// it at rest: nothing of the node's identity is written to a file by this library.
type StateStore interface {
	// Load returns what Save last gave, or "" for a node that has never started.
	Load() string
	// Save keeps state, replacing what was kept before. An error tells the node it was not kept.
	Save(state string) error
}

// tailscaleConf is a Tailscale tunnel's settings, as the app stores them (JSON).
type tailscaleConf struct {
	// ControlURL is the coordination server: "" for Tailscale's own, or a Headscale server.
	ControlURL string `json:"controlUrl"`
	// AuthKey signs a new node in without a browser; "" signs in through AuthURL instead.
	AuthKey string `json:"authKey"`
	// Hostname is the device's name in the tailnet.
	Hostname string `json:"hostname"`
}

// DefaultHostname is a node's name when its settings give none.
const DefaultHostname = "omniterm"

var hostnamePattern = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$`)

func parseTailscale(text string) (*tailscaleConf, error) {
	var c tailscaleConf
	if err := json.Unmarshal([]byte(text), &c); err != nil {
		return nil, errors.New("The Tailscale settings could not be read.")
	}
	c.ControlURL = strings.TrimSpace(c.ControlURL)
	c.AuthKey = strings.TrimSpace(c.AuthKey)
	c.Hostname = strings.TrimSpace(c.Hostname)
	if c.ControlURL != "" {
		u, err := url.Parse(c.ControlURL)
		if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || u.User != nil ||
			(u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" {
			return nil, errors.New("The control server must be an address like https://headscale.example.com, or empty for Tailscale's own.")
		}
		c.ControlURL = strings.TrimSuffix(c.ControlURL, "/")
	}
	if strings.ContainsAny(c.AuthKey, " \t\r\n") {
		return nil, errors.New("The auth key has spaces in it. Paste it again.")
	}
	if len(c.AuthKey) > 512 {
		return nil, errors.New("The auth key is too long to be one.")
	}
	if c.Hostname == "" {
		c.Hostname = DefaultHostname
	}
	if !hostnamePattern.MatchString(c.Hostname) {
		return nil, errors.New("The device name may hold letters, digits and hyphens, up to 63, and cannot start or end with a hyphen.")
	}
	return &c, nil
}

// CheckTailscale says what is wrong with a Tailscale tunnel's settings, or "" when they can be used.
func CheckTailscale(conf string) string {
	if _, err := parseTailscale(conf); err != nil {
		return err.Error()
	}
	return ""
}

// tailscale carries a tunnel through a Tailscale node, a tsnet server inside the app.
type tailscale struct {
	srv     *tsnet.Server
	lc      *local.Client
	dialer  *tsdial.Dialer
	cancel  context.CancelFunc
	control string

	// changed wakes StartTailscale on news; wake wakes poll once the node stops running.
	changed chan struct{}
	wake    chan struct{}

	mu      sync.Mutex
	st      ipn.State
	url     string
	refused string // the control server's refusal: the tunnel has failed
	note    string // what the user should know that does not stop the tunnel
	ips     string
	rx, tx  int64
	shake   int64
	readAt  time.Time
}

// StartTailscale brings a Tailscale node up from its settings ([CheckTailscale]), keeping its state
// in store and nothing but scratch in dir. It waits up to waitMs for the node to run, or to need a
// sign-in, whose page AuthURL then gives; the tunnel then stays up, signing in, without carrying
// connections. It fails when the control server refuses the node or does not answer.
func StartTailscale(conf string, dir string, store StateStore, waitMs int) (*Tunnel, error) {
	c, err := parseTailscale(conf)
	if err != nil {
		return nil, err
	}
	if dir == "" || store == nil {
		return nil, errors.New("The tunnel has nowhere to keep its state.")
	}
	if waitMs <= 0 {
		waitMs = 30_000
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("The tunnel could not be set up: %v", err)
	}
	control := c.ControlURL
	if control == "" {
		control = "Tailscale"
	}
	// The library asks where to keep logs even though this build keeps none (ts_omit_logtail), and
	// on Android, which offers it no home, cache or temporary directory, that question panics. The
	// tunnel's own folder answers it; nothing is written there.
	os.Setenv("TS_LOGS_DIR", dir)
	state := newAppStore(store)
	srv := &tsnet.Server{
		Dir:        dir,
		Store:      state,
		Hostname:   c.Hostname,
		ControlURL: c.ControlURL,
		AuthKey:    c.AuthKey,
		// The sign-in page is shown by the app, not written to the phone's log.
		UserLogf: logger.Discard,
	}
	if err := srv.Start(); err != nil {
		srv.Close()
		return nil, fmt.Errorf("Tailscale could not start: %v", err)
	}
	// tsnet keeps a random ID for log uploads there. This build uploads no logs (ts_omit_logtail),
	// so the file serves nothing; a new ID each start tells the control server less.
	_ = os.Remove(filepath.Join(dir, "tailscaled.log.conf"))
	lc, err := srv.LocalClient()
	if err != nil {
		srv.Close()
		return nil, fmt.Errorf("Tailscale could not start: %v", err)
	}
	dialer, ok := srv.Sys().Dialer.GetOK()
	if !ok {
		srv.Close()
		return nil, errors.New("Tailscale could not start: it has no dialer.")
	}
	ctx, cancel := context.WithCancel(context.Background())
	// Routes other nodes offer (subnet routers) are used, as the Tailscale apps for phones do: the
	// default for Android, set here so every platform the library runs on behaves the same.
	if _, err := lc.EditPrefs(ctx, &ipn.MaskedPrefs{Prefs: ipn.Prefs{RouteAll: true}, RouteAllSet: true}); err != nil {
		cancel()
		srv.Close()
		return nil, fmt.Errorf("Tailscale could not start: %v", err)
	}
	ts := &tailscale{srv: srv, lc: lc, dialer: dialer, cancel: cancel, control: control,
		changed: make(chan struct{}, 1), wake: make(chan struct{}, 1)}
	if state.unreadable {
		ts.note = "This tunnel's saved sign-in could not be read, so it signs in again."
	}
	go ts.watch(ctx)
	go ts.poll(ctx)
	live.add(ts)

	deadline := time.NewTimer(time.Duration(waitMs) * time.Millisecond)
	defer deadline.Stop()
	for {
		ts.mu.Lock()
		st, link, refused := ts.st, ts.url, ts.refused
		ts.mu.Unlock()
		switch {
		case refused != "":
			ts.close()
			return nil, fmt.Errorf("The control server refused this device: %s", refused)
		case st == ipn.Running, st == ipn.NeedsMachineAuth, st == ipn.NeedsLogin && link != "":
			return newTunnel(ts), nil
		}
		select {
		case <-ts.changed:
		case <-deadline.C:
			ts.close()
			return nil, fmt.Errorf("%s's control server did not answer in time.", control)
		}
	}
}

// watch follows the node's state as it changes, watching again if the watch is lost.
func (ts *tailscale) watch(ctx context.Context) {
	for ctx.Err() == nil {
		ts.watchOnce(ctx)
		select {
		case <-ctx.Done():
		case <-time.After(time.Second):
		}
	}
}

func (ts *tailscale) watchOnce(ctx context.Context) {
	w, err := ts.lc.WatchIPNBus(ctx, ipn.NotifyInitialState)
	if err != nil {
		return
	}
	defer w.Close()
	for {
		n, err := w.Next()
		if err != nil {
			return
		}
		lost := false
		ts.mu.Lock()
		if n.State != nil {
			ts.setState(*n.State)
		}
		if n.BrowseToURL != nil {
			ts.url = *n.BrowseToURL
		}
		if n.ErrMessage != nil {
			refused, note, again := sortBusError(*n.ErrMessage, ts.control)
			if refused != "" {
				ts.refused = refused
			}
			if note != "" {
				ts.note = note
			}
			lost = again
		}
		ts.mu.Unlock()
		ts.pulse()
		if lost {
			return
		}
	}
}

// setState records the node's state; ts.mu is held.
func (ts *tailscale) setState(st ipn.State) {
	ts.st = st
	if st == ipn.Running {
		ts.url, ts.note = "", ""
		return
	}
	select {
	case ts.wake <- struct{}{}:
	default:
	}
}

// sortBusError sorts an error the node reports: the control server refusing it (a refused auth key,
// a device it will not take) ends the start; the server being busy and the watch lagging pass, and
// the node tries again by itself. again is whether the watch has to be made again.
func sortBusError(msg, control string) (refused, note string, again bool) {
	switch {
	case strings.HasPrefix(msg, "IPN bus consumer fell behind"):
		return "", "", true
	case strings.Contains(msg, "rate limited"):
		return "", control + "'s control server is busy. The tunnel tries again by itself.", false
	}
	return msg, "", false
}

// poll reads what the bus does not say: the sign-in page asked for before watch began and the
// node's addresses, every second until it runs; then it waits until the node stops running.
func (ts *tailscale) poll(ctx context.Context) {
	for {
		ts.read(ctx)
		ts.mu.Lock()
		running := ts.st == ipn.Running
		ts.mu.Unlock()
		var next <-chan time.Time
		if !running {
			next = time.After(time.Second)
		}
		select {
		case <-ctx.Done():
			return
		case <-next:
		case <-ts.wake:
		}
	}
}

// read asks the node for its status: its state, its addresses and its traffic.
func (ts *tailscale) read(ctx context.Context) {
	qctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	status, err := ts.lc.Status(qctx)
	cancel()
	if err != nil {
		return
	}
	var ips []string
	for _, a := range status.TailscaleIPs {
		ips = append(ips, a.String())
	}
	var rx, tx, shake int64
	for _, p := range status.Peer {
		rx += p.RxBytes
		tx += p.TxBytes
		if !p.LastHandshake.IsZero() {
			shake = max(shake, p.LastHandshake.Unix())
		}
	}
	ts.mu.Lock()
	if st, ok := ipn.StateFromString(status.BackendState); ok && st != ts.st {
		ts.setState(st)
	}
	if ts.st == ipn.NeedsLogin && status.AuthURL != "" {
		ts.url = status.AuthURL
	}
	ts.ips, ts.rx, ts.tx, ts.shake, ts.readAt = strings.Join(ips, ","), rx, tx, shake, time.Now()
	ts.mu.Unlock()
	ts.pulse()
}

// counters is the node's traffic, read again when what was read is older than countersFor.
func (ts *tailscale) counters() (rx, tx, shake int64) {
	ts.mu.Lock()
	stale := time.Since(ts.readAt) > countersFor
	ts.mu.Unlock()
	if stale {
		ts.read(context.Background())
	}
	ts.mu.Lock()
	defer ts.mu.Unlock()
	return ts.rx, ts.tx, ts.shake
}

const countersFor = 2 * time.Second

func (ts *tailscale) pulse() {
	select {
	case ts.changed <- struct{}{}:
	default:
	}
}

func (ts *tailscale) dial(ctx context.Context, host string, port int, _ time.Time) (net.Conn, error) {
	switch ts.state() {
	case StateRunning:
	case StateNeedsLogin:
		return nil, errors.New("This Tailscale tunnel is not signed in. Sign it in under Tools, VPN tunnels.")
	case StateNeedsApproval:
		return nil, errors.New("This device is waiting for the tailnet's admin to approve it.")
	default:
		return nil, errors.New("The tunnel is not connected to its tailnet yet.")
	}
	host = strings.TrimSuffix(strings.TrimPrefix(host, "["), "]")
	ipp, err := ts.resolve(ctx, host, port)
	if err != nil {
		return nil, err
	}
	if ts.dialer.UseNetstackForIP == nil || ts.dialer.NetstackDialTCP == nil || !ts.dialer.UseNetstackForIP(ipp.Addr()) {
		return nil, fmt.Errorf("%s is not in this tailnet.", host)
	}
	c, err := ts.dialer.NetstackDialTCP(ctx, ipp)
	if err != nil {
		return nil, dialFailure(err)
	}
	return c, nil
}

// resolve finds host's address. A name the tailnet's DNS servers cover (split DNS, or every name
// when its admin overrides local DNS) is asked of them, through the tailnet, and nothing else;
// MagicDNS names are looked up in the tailnet; any other name with the phone's DNS. Whichever way,
// dial then reaches only an address the tailnet routes.
func (ts *tailscale) resolve(ctx context.Context, host string, port int) (netip.AddrPort, error) {
	if mgr, ok := ts.srv.Sys().DNSManager.GetOK(); ok {
		if _, err := netip.ParseAddr(host); err != nil {
			if fqdn, err := dnsname.ToFQDN(host); err == nil && len(mgr.Resolver().GetUpstreamResolvers(fqdn)) > 0 {
				addr, err := askTailnet(ctx, mgr, fqdn)
				if err != nil {
					return netip.AddrPort{}, fmt.Errorf("%s could not be found by the tailnet's DNS.", host)
				}
				return netip.AddrPortFrom(addr, uint16(port)), nil
			}
		}
	}
	ipp, _, err := ts.dialer.UserDialPlan(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		return netip.AddrPort{}, fmt.Errorf("%s could not be found in the tailnet.", host)
	}
	return ipp, nil
}

// askTailnet asks the tailnet's DNS for name's address: IPv4 first, then IPv6.
func askTailnet(ctx context.Context, mgr *dns.Manager, name dnsname.FQDN) (netip.Addr, error) {
	qname, err := dnsmessage.NewName(string(name))
	if err != nil {
		return netip.Addr{}, err
	}
	for i, qtype := range []dnsmessage.Type{dnsmessage.TypeA, dnsmessage.TypeAAAA} {
		b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: uint16(i + 1), RecursionDesired: true})
		b.EnableCompression()
		if err := b.StartQuestions(); err != nil {
			return netip.Addr{}, err
		}
		if err := b.Question(dnsmessage.Question{Name: qname, Type: qtype, Class: dnsmessage.ClassINET}); err != nil {
			return netip.Addr{}, err
		}
		query, err := b.Finish()
		if err != nil {
			return netip.Addr{}, err
		}
		qctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		answer, err := mgr.Query(qctx, query, "tcp", netip.AddrPort{})
		cancel()
		if err != nil {
			continue
		}
		var p dnsmessage.Parser
		if h, err := p.Start(answer); err != nil || h.RCode != dnsmessage.RCodeSuccess {
			continue
		}
		if err := p.SkipAllQuestions(); err != nil {
			continue
		}
		for {
			rh, err := p.AnswerHeader()
			if err != nil {
				break
			}
			switch rh.Type {
			case dnsmessage.TypeA:
				if r, err := p.AResource(); err == nil {
					return netip.AddrFrom4(r.A), nil
				}
			case dnsmessage.TypeAAAA:
				if r, err := p.AAAAResource(); err == nil {
					return netip.AddrFrom16(r.AAAA), nil
				}
			default:
				// A CNAME and the like: the address records follow it.
				_ = p.SkipAnswer()
			}
		}
	}
	return netip.Addr{}, errors.New("no address")
}

func (ts *tailscale) state() string {
	ts.mu.Lock()
	defer ts.mu.Unlock()
	switch {
	case ts.st == ipn.Running:
		return StateRunning
	case ts.st == ipn.NeedsMachineAuth:
		return StateNeedsApproval
	case ts.st == ipn.NeedsLogin:
		return StateNeedsLogin
	case ts.refused != "":
		return StateFailed
	}
	return StateStarting
}

func (ts *tailscale) authURL() string {
	ts.mu.Lock()
	defer ts.mu.Unlock()
	if ts.st != ipn.NeedsLogin {
		return ""
	}
	return ts.url
}

func (ts *tailscale) problem() string {
	ts.mu.Lock()
	defer ts.mu.Unlock()
	if ts.refused != "" {
		return ts.refused
	}
	return ts.note
}

func (ts *tailscale) addresses() string {
	ts.mu.Lock()
	defer ts.mu.Unlock()
	return ts.ips
}

func (ts *tailscale) hasDNS() bool { return true }

func (ts *tailscale) lastHandshake() int64 {
	_, _, shake := ts.counters()
	return shake
}

func (ts *tailscale) bytesIn() int64 {
	rx, _, _ := ts.counters()
	return rx
}

func (ts *tailscale) bytesOut() int64 {
	_, tx, _ := ts.counters()
	return tx
}

func (ts *tailscale) close() {
	live.remove(ts)
	ts.cancel()
	ts.srv.Close()
}

// appStore is tsnet's state store over the app's [StateStore]: every key in one blob, which the app
// encrypts and keeps; nothing reaches a file.
type appStore struct {
	app  StateStore
	mu   sync.Mutex
	keys map[ipn.StateKey][]byte
	// unreadable is whether the app's blob could not be read, so the node starts afresh.
	unreadable bool
}

func newAppStore(app StateStore) *appStore {
	s := &appStore{app: app, keys: map[ipn.StateKey][]byte{}}
	if blob := app.Load(); blob != "" {
		// A blob that cannot be read starts the node afresh: it signs in again, and is told why.
		if err := json.Unmarshal([]byte(blob), &s.keys); err != nil {
			s.keys, s.unreadable = map[ipn.StateKey][]byte{}, true
		}
	}
	return s
}

func (s *appStore) ReadState(id ipn.StateKey) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	bs, ok := s.keys[id]
	if !ok {
		return nil, ipn.ErrStateNotExist
	}
	return append([]byte(nil), bs...), nil
}

func (s *appStore) WriteState(id ipn.StateKey, bs []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if bs == nil {
		delete(s.keys, id)
	} else {
		s.keys[id] = append([]byte(nil), bs...)
	}
	blob, err := json.Marshal(s.keys)
	if err != nil {
		return err
	}
	return s.app.Save(string(blob))
}

// liveNodes is every Tailscale node that is up, for NetworkChanged.
type liveNodes struct {
	mu    sync.Mutex
	nodes map[*tailscale]struct{}
}

var live = &liveNodes{nodes: map[*tailscale]struct{}{}}

func (l *liveNodes) add(ts *tailscale) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.nodes[ts] = struct{}{}
}

func (l *liveNodes) remove(ts *tailscale) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.nodes, ts)
}

func (l *liveNodes) each(f func(*tailscale)) {
	l.mu.Lock()
	nodes := make([]*tailscale, 0, len(l.nodes))
	for ts := range l.nodes {
		nodes = append(nodes, ts)
	}
	l.mu.Unlock()
	for _, ts := range nodes {
		f(ts)
	}
}
