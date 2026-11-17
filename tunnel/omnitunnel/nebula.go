package omnitunnel

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"maps"
	"net"
	"net/netip"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	neb "github.com/slackhq/nebula"
	"github.com/slackhq/nebula/cert"
	"github.com/slackhq/nebula/config"
	"github.com/slackhq/nebula/logging"
	"github.com/slackhq/nebula/overlay"
	"github.com/slackhq/nebula/service"
	"go.yaml.in/yaml/v3"
)

// Only identity, discovery and the two settings every node of a network must share (its cipher
// and its revoked-certificate blocklist) are imported, with the certificate version a node that
// has both starts handshakes with. In particular no file paths, device, management listener,
// system DNS, metrics exporter, relay service or firewall is imported.
type nebulaInput struct {
	PKI struct {
		CA, Cert, Key     string
		Blocklist         []string
		InitiatingVersion uint32 `yaml:"initiating_version"`
	}
	Cipher        string
	StaticHostMap map[string][]string `yaml:"static_host_map"`
	Lighthouse    struct{ Hosts []string }
	Tun           struct {
		UnsafeRoutes yaml.Node `yaml:"unsafe_routes,omitempty"`
	}
	UnsafeRoutes yaml.Node `yaml:"unsafe_routes,omitempty"`
}

type nebulaConfig struct {
	input nebulaInput
	// identity is the certificate whose networks the node has: its v2 one when it has both, as in
	// Nebula (pki.go, newCertState), since a v2 certificate's networks are a superset.
	identity cert.Certificate
	// named is whether a static_host_map endpoint is a host name, looked up on each start and
	// after each network change.
	named bool
}

// CheckNebula validates an inline Nebula YAML configuration without opening files or sockets.
// Errors deliberately contain none of the supplied text (including YAML parser diagnostics).
func CheckNebula(text string) string {
	if _, err := parseNebula(text); err != nil {
		return err.Error()
	}
	return ""
}

func parseNebula(text string) (*nebulaConfig, error) {
	if len(text) > 64*1024 {
		return nil, errors.New("The Nebula configuration must be at most 64 KB.")
	}
	var in nebulaInput
	decoder := yaml.NewDecoder(strings.NewReader(text))
	if decoder.Decode(&in) != nil {
		return nil, errors.New("The Nebula configuration could not be read. Check its YAML indentation.")
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		return nil, errors.New("Use one Nebula configuration in this file.")
	}
	if in.Tun.UnsafeRoutes.Kind != 0 || in.UnsafeRoutes.Kind != 0 {
		return nil, errors.New("Unsafe routes are not supported by Nebula inside OmniTerm. Use a host's Nebula address instead.")
	}
	// Never let Nebula interpret a certificate or key as a file name or PKCS#11 URI.
	if !strings.HasPrefix(strings.TrimSpace(in.PKI.CA), "-----BEGIN NEBULA CERTIFICATE") ||
		!strings.HasPrefix(strings.TrimSpace(in.PKI.Cert), "-----BEGIN NEBULA CERTIFICATE") ||
		!strings.HasPrefix(strings.TrimSpace(in.PKI.Key), "-----BEGIN NEBULA") {
		return nil, errors.New("Paste the CA certificate, host certificate and private key inline under pki.ca, pki.cert and pki.key, using YAML's | blocks. File paths are not supported.")
	}
	// Every node must use the network's cipher or no handshake completes; Nebula's default is aes.
	if in.Cipher != "" && in.Cipher != "aes" && in.Cipher != "chachapoly" {
		return nil, errors.New("Nebula's cipher must be aes or chachapoly, the same as every other node in the network.")
	}
	pool, err := cert.NewCAPoolFromPEM([]byte(in.PKI.CA))
	if err != nil {
		return nil, errors.New("The Nebula CA certificate is invalid or expired. Import a current CA certificate.")
	}
	for i, fingerprint := range in.PKI.Blocklist {
		fingerprint = strings.ToLower(strings.TrimSpace(fingerprint))
		if b, err := hex.DecodeString(fingerprint); err != nil || len(b) != sha256.Size {
			return nil, errors.New("Each pki.blocklist entry must be a certificate fingerprint of 64 hexadecimal characters.")
		}
		in.PKI.Blocklist[i] = fingerprint
		pool.BlocklistFingerprint(fingerprint)
	}
	key, rest, curve, err := cert.UnmarshalPrivateKeyFromPEM([]byte(in.PKI.Key))
	if err != nil || len(strings.TrimSpace(string(rest))) != 0 {
		return nil, errors.New("The private key does not match this Nebula host certificate. Import its matching unencrypted key.")
	}
	identity, hasV1, err := hostCertificates(pool, in.PKI.Cert, curve, key)
	if err != nil {
		return nil, err
	}
	switch in.PKI.InitiatingVersion {
	case 0, 2:
	case 1:
		// As Nebula: a node starts handshakes with v1 only when it has a v1 certificate.
		if !hasV1 {
			return nil, errors.New("pki.initiating_version 1 needs a v1 certificate under pki.cert.")
		}
	default:
		return nil, errors.New("pki.initiating_version must be 1 or 2.")
	}
	c := &nebulaConfig{input: in, identity: identity}
	if len(in.StaticHostMap) > 64 || len(in.Lighthouse.Hosts) > 32 {
		return nil, errors.New("Use at most 64 static hosts and 32 lighthouses.")
	}
	for address, endpoints := range in.StaticHostMap {
		a, err := netip.ParseAddr(address)
		if err != nil || !c.routes(a) || len(endpoints) == 0 || len(endpoints) > 16 {
			return nil, errors.New("Each static host needs a Nebula address inside the certificate's network and 1 to 16 endpoints.")
		}
		for _, endpoint := range endpoints {
			host, port, err := net.SplitHostPort(endpoint)
			if err != nil {
				return nil, errors.New("Each static host endpoint must be an IP address or host name and a port, such as 192.0.2.1:4242 or lighthouse.example.com:4242.")
			}
			number, err := strconv.ParseUint(port, 10, 16)
			if a, aerr := netip.ParseAddr(host); err != nil || number == 0 || (aerr == nil && (a.IsUnspecified() || a.IsMulticast())) {
				return nil, errors.New("Use a reachable IP address or host name and a port from 1 to 65535 for each static host endpoint.")
			} else if aerr != nil {
				if !isHostName(host) {
					return nil, errors.New("Each static host endpoint must be an IP address or host name and a port, such as 192.0.2.1:4242 or lighthouse.example.com:4242.")
				}
				c.named = true
			}
		}
	}
	for _, address := range in.Lighthouse.Hosts {
		a, err := netip.ParseAddr(address)
		if err != nil || !c.routes(a) || len(in.StaticHostMap[address]) == 0 {
			return nil, errors.New("Each lighthouse needs its Nebula address inside the certificate's network and an endpoint in static_host_map.")
		}
	}
	if len(in.StaticHostMap) == 0 {
		return nil, errors.New("Add a lighthouse or peer's endpoint, such as 192.0.2.1:4242, under static_host_map.")
	}
	return c, nil
}

// hostCertificates reads pki.cert as Nebula does (pki.go, newCertStateFromConfig): a host
// certificate, or a v1 and a v2 one of the same key, curve and first network, so the node can
// talk to peers of either version. A certificate of a version or curve this Nebula does not know
// is skipped, as Nebula skips it. Each one must be valid, signed by the CA, not revoked and match
// the key. It returns the certificate whose networks the node has, and whether it has a v1 one.
func hostCertificates(pool *cert.CAPool, text string, curve cert.Curve, key []byte) (cert.Certificate, bool, error) {
	var v1, v2 cert.Certificate
	rest := []byte(text)
	for len(bytes.TrimSpace(rest)) != 0 {
		crt, next, err := cert.UnmarshalCertificateFromPEM(rest)
		if errors.Is(err, cert.ErrUnknownVersion) || errors.Is(err, cert.ErrUnknownCurve) {
			rest = next
			continue
		}
		if err != nil || crt.IsCA() {
			return nil, false, errors.New("Use Nebula host certificates, not a CA certificate, under pki.cert: one, or a v1 and a v2 one of the same host.")
		}
		rest = next
		switch {
		case crt.Version() == cert.Version1 && v1 == nil:
			v1 = crt
		case crt.Version() == cert.Version2 && v2 == nil:
			v2 = crt
		default:
			return nil, false, errors.New("pki.cert may hold one v1 and one v2 certificate, not two of the same version.")
		}
		if _, err := pool.VerifyCertificate(time.Now(), crt); errors.Is(err, cert.ErrBlockListed) {
			return nil, false, errors.New("This host certificate is revoked by the configuration's pki.blocklist. Import a current certificate.")
		} else if err != nil {
			return nil, false, errors.New("The host certificate is expired, not yet valid, or not signed by this CA. Import current matching certificates.")
		}
		if crt.VerifyPrivateKey(curve, key) != nil {
			return nil, false, errors.New("The private key does not match this Nebula host certificate. Import its matching unencrypted key.")
		}
		if len(crt.Networks()) == 0 {
			return nil, false, errors.New("The host certificate needs a Nebula network address.")
		}
	}
	// Each certificate matched the one pki.key above, so a v1 and a v2 one share their key and
	// curve, as Nebula requires; the first address is theirs to agree on.
	if v1 != nil && v2 != nil {
		if v1.Networks()[0] != v2.Networks()[0] {
			return nil, false, errors.New("The v1 and v2 certificates under pki.cert must have the same first Nebula address, as Nebula requires.")
		}
	}
	if v2 != nil {
		return v2, v1 != nil, nil
	}
	if v1 != nil {
		return v1, true, nil
	}
	return nil, false, errors.New("Use one Nebula host certificate, not a CA certificate, under pki.cert.")
}

func (c *nebulaConfig) routes(a netip.Addr) bool {
	for _, p := range c.identity.Networks() {
		if p.Contains(a.Unmap()) {
			return true
		}
	}
	return false
}

// staticHosts is static_host_map with each host name looked up with the phone's own DNS
// (resolver), as WireGuard's Endpoint is, an IPv4 address first: Nebula never looks a name up
// itself, nor through a tunnel. A name that cannot be found now is left out; only when no
// endpoint is left at all does it fail.
func (c *nebulaConfig) staticHosts(resolver Resolver) (map[string][]string, error) {
	out := make(map[string][]string, len(c.input.StaticHostMap))
	found := 0
	for address, endpoints := range c.input.StaticHostMap {
		list := []string{}
		for _, endpoint := range endpoints {
			host, port, _ := net.SplitHostPort(endpoint)
			number, _ := strconv.ParseUint(port, 10, 16)
			a, err := resolveOne(host, resolver)
			// A name some DNS filters answer with 0.0.0.0 is as good as not found.
			if err != nil || a.IsUnspecified() || a.IsMulticast() {
				continue
			}
			list = append(list, netip.AddrPortFrom(a, uint16(number)).String())
		}
		found += len(list)
		out[address] = list
	}
	if found == 0 {
		return nil, errors.New("No static_host_map endpoint could be found. Check the phone's connection and the host names there.")
	}
	return out, nil
}

// runtime constructs a fresh allowlist. Imported sections cannot enable any ancillary service.
// hosts is static_host_map with its names looked up (staticHosts).
func (c *nebulaConfig) runtime(hosts map[string][]string) (*config.C, error) {
	raw, err := c.settings(hosts)
	if err != nil {
		return nil, err
	}
	out := config.NewC(logging.NewLogger(io.Discard))
	if err := out.LoadString(raw); err != nil {
		return nil, err
	}
	return out, nil
}

func (c *nebulaConfig) settings(hosts map[string][]string) (string, error) {
	cipher := c.input.Cipher
	if cipher == "" {
		cipher = "aes"
	}
	pki := map[string]any{"ca": c.input.PKI.CA, "cert": c.input.PKI.Cert, "key": c.input.PKI.Key, "blocklist": c.input.PKI.Blocklist}
	if c.input.PKI.InitiatingVersion != 0 {
		pki["initiating_version"] = c.input.PKI.InitiatingVersion
	}
	settings := map[string]any{
		"pki":             pki,
		"cipher":          cipher,
		"static_host_map": hosts,
		"lighthouse":      map[string]any{"hosts": c.input.Lighthouse.Hosts, "am_lighthouse": false, "interval": 0},
		"listen":          map[string]any{"host": "0.0.0.0", "port": 0},
		"tun":             map[string]any{"disabled": false, "mtu": 1280},
		"firewall": map[string]any{
			"outbound": []map[string]any{{"port": "any", "proto": "tcp", "host": "any"}},
			"inbound":  []any{},
		},
		"punchy":   map[string]any{"punch": true},
		"routines": 1,
	}
	raw, err := yaml.Marshal(settings)
	return string(raw), err
}

type nebulaControl interface {
	State() neb.RunState
	RebindUDPServer()
}

type nebula struct {
	svc     *service.Service
	control nebulaControl
	config  *nebulaConfig
	payloadCounters

	// For static_host_map's host names: looked up again after each network change.
	resolver Resolver
	settings *config.C
	lookups  atomic.Int64 // the newest lookup; an older one that finishes later is dropped
	mu       sync.Mutex   // guards hosts and closed, and reloads
	hosts    map[string][]string
	closed   bool
}

var nebulaNodes sync.Map // *nebula -> struct{}; only NetworkChanged walks it, no poller

// NebulaNode is what makes a configuration one node of its Nebula network: its certificate's
// first Nebula address, which a v1 and a v2 certificate of one node share; "" when it is not
// valid. Peers keep one tunnel per first address and take the newest handshake for it
// (HandshakeManager.CheckAndComplete in Nebula's handshake_manager.go), so a second node with that
// address, under any key, takes the first one's place there.
func NebulaNode(text string) string {
	c, err := parseNebula(text)
	if err != nil {
		return ""
	}
	return "nebula:" + c.identity.Networks()[0].Addr().String()
}

// StartNebula runs Nebula's userspace service. The sole outside listener is an ephemeral UDP
// socket for Nebula's encrypted transport. No TUN, system VPN or incoming app service is opened.
// resolver is the phone's own DNS, for static_host_map's host names.
func StartNebula(text string, resolver Resolver) (*Tunnel, error) {
	c, err := parseNebula(text)
	if err != nil {
		return nil, err
	}
	hosts, err := c.staticHosts(resolver)
	if err != nil {
		return nil, err
	}
	runtime, err := c.runtime(hosts)
	if err != nil {
		return nil, errors.New("The Nebula settings could not be prepared.")
	}
	control, err := neb.Main(runtime, false, "OmniTerm", logging.NewLogger(io.Discard), overlay.NewUserDeviceFromConfig)
	if err != nil {
		return nil, errors.New("Nebula could not start. Check the certificates and static host map.")
	}
	svc, err := service.New(control)
	if err != nil {
		control.Stop()
		return nil, errors.New("Nebula could not open its private network inside the app.")
	}
	n := &nebula{svc: svc, control: control, config: c, resolver: resolver, settings: runtime, hosts: hosts}
	nebulaNodes.Store(n, struct{}{})
	return newTunnel(n), nil
}

func (n *nebula) dial(ctx context.Context, host string, port int, _ time.Time) (net.Conn, error) {
	if n.state() != StateRunning {
		return nil, errors.New("This Nebula tunnel is not running. Check its certificate and reconnect.")
	}
	// Only numeric addresses go into Service.DialContext: it must never resolve a name on the
	// phone or choose an outside address. The service owns the only TCP dialer we call.
	a, err := netip.ParseAddr(strings.TrimSuffix(strings.TrimPrefix(host, "["), "]"))
	if err != nil {
		return nil, errors.New("Use this host's numeric Nebula address. Nebula host names are not supported.")
	}
	if !n.config.routes(a) {
		return nil, errors.New("This address is outside the Nebula certificate's network.")
	}
	conn, err := n.svc.DialContext(ctx, "tcp", net.JoinHostPort(a.Unmap().String(), strconv.Itoa(port)))
	if err != nil {
		return nil, dialFailure(err)
	}
	return n.payloadCounters.wrap(conn), nil
}

func (n *nebula) hasDNS() bool    { return false }
func (n *nebula) authURL() string { return "" }
func (n *nebula) addresses() string {
	var addresses []string
	for _, p := range n.config.identity.Networks() {
		addresses = append(addresses, p.Addr().String())
	}
	return strings.Join(addresses, ",")
}
func (n *nebula) lastHandshake() int64 { return 0 }
func (n *nebula) bytesIn() int64       { return n.rx.Load() }
func (n *nebula) bytesOut() int64      { return n.tx.Load() }
func (n *nebula) state() string {
	if n.control.State() == neb.StateStarted && !n.config.identity.Expired(time.Now()) {
		return StateRunning
	}
	return StateFailed
}
func (n *nebula) problem() string {
	if n.state() != StateRunning {
		return "Nebula has stopped or its certificate has expired. Import current certificates and reconnect."
	}
	return ""
}
func (n *nebula) close() {
	nebulaNodes.Delete(n)
	n.mu.Lock()
	n.closed = true
	n.mu.Unlock()
	_ = n.svc.Close()
	_ = n.svc.Wait()
}

func nebulaNetworkChanged() {
	nebulaNodes.Range(func(key, _ any) bool {
		n := key.(*nebula)
		n.control.RebindUDPServer()
		if n.config != nil && n.config.named {
			go n.resolveAgain()
		}
		return true
	})
}

// resolveAgain looks static_host_map's host names up again on the network the phone is on now,
// where they may have other addresses (a home DNS, a new public address), and gives Nebula the
// new endpoints when they changed. Its tunnels to peers stay up. When nothing can be found, as on
// a network whose DNS is not ready, the last endpoints stay.
func (n *nebula) resolveAgain() {
	lookup := n.lookups.Add(1)
	hosts, err := n.config.staticHosts(n.resolver)
	if err != nil {
		return
	}
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.closed || lookup != n.lookups.Load() || maps.EqualFunc(hosts, n.hosts, slices.Equal) {
		return
	}
	raw, err := n.config.settings(hosts)
	if err != nil {
		return
	}
	if result := n.settings.ReloadConfigString(raw); result.Err == nil && !result.Failed {
		n.hosts = hosts
	}
}
