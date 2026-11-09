// Package omnitunnel carries OmniTerm's connections to a host through a tunnel the user set up for
// it, entirely inside the app: the tunnel's network stack is gVisor's netstack, so the phone's
// system VPN slot is never used and nothing else on the phone goes through it.
//
// Kotlin asks a running [Tunnel] to dial a host and gets back one end of a private socket pair; the
// other end is joined to the TCP connection inside the tunnel. Nothing listens on any port.
package omnitunnel

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

// Resolver looks a host name up with the phone's own DNS, for names the tunnel has no DNS server
// for (a peer's Endpoint, or every name when the configuration sets no DNS). It returns the
// addresses joined by commas.
type Resolver interface {
	Resolve(host string) (string, error)
}

// Tunnel is one running tunnel.
type Tunnel struct {
	dev      *device.Device
	tnet     *netstack.Net
	allowed  []netip.Prefix
	hasDNS   bool
	resolver Resolver

	mu     sync.Mutex
	closed bool
	pairs  map[*pair]struct{}
}

// CheckWireGuard says what is wrong with a wg-quick configuration, or "" when it can be used.
func CheckWireGuard(conf string) string {
	if _, err := parseWireGuard(conf); err != nil {
		return err.Error()
	}
	return ""
}

// StartWireGuard brings a WireGuard tunnel up from a wg-quick configuration.
func StartWireGuard(conf string, resolver Resolver) (*Tunnel, error) {
	c, err := parseWireGuard(conf)
	if err != nil {
		return nil, err
	}
	endpoints := make([]string, len(c.peers))
	for i, p := range c.peers {
		if p.endpoint == "" {
			continue
		}
		host, port, _ := splitEndpoint(p.endpoint)
		addr, err := resolveOne(host, resolver)
		if err != nil {
			return nil, fmt.Errorf("The peer's Endpoint %s could not be found.", host)
		}
		endpoints[i] = netip.AddrPortFrom(addr, uint16(port)).String()
	}
	tunDev, tnet, err := netstack.CreateNetTUN(c.addresses, c.dns, c.mtu)
	if err != nil {
		return nil, fmt.Errorf("The tunnel could not be set up: %v", err)
	}
	dev := device.NewDevice(tunDev, conn.NewDefaultBind(), device.NewLogger(device.LogLevelSilent, ""))
	if err := dev.IpcSet(c.uapi(endpoints)); err != nil {
		dev.Close()
		return nil, errors.New("WireGuard refused the configuration.")
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		return nil, fmt.Errorf("The tunnel could not start: %v", err)
	}
	return &Tunnel{
		dev:      dev,
		tnet:     tnet,
		allowed:  c.allowedPrefixes(),
		hasDNS:   len(c.dns) > 0,
		resolver: resolver,
		pairs:    map[*pair]struct{}{},
	}, nil
}

// DialFd connects to host:port through the tunnel and returns the app's end of a socket pair
// joined to that connection. The caller owns the descriptor and closes it when done.
func (t *Tunnel) DialFd(host string, port int, timeoutMs int) (int, error) {
	if port < 1 || port > 65535 {
		return -1, errors.New("The port must be from 1 to 65535.")
	}
	if timeoutMs <= 0 {
		timeoutMs = 15_000
	}
	t.mu.Lock()
	closed := t.closed
	t.mu.Unlock()
	if closed {
		return -1, errors.New("The tunnel is closed.")
	}
	deadline := time.Now().Add(time.Duration(timeoutMs) * time.Millisecond)
	ctx, cancel := context.WithDeadline(context.Background(), deadline)
	defer cancel()

	addrs, err := t.lookup(ctx, host)
	if err != nil {
		return -1, err
	}
	var inside []netip.Addr
	for _, a := range addrs {
		if t.routes(a) {
			inside = append(inside, a)
		}
	}
	if len(inside) == 0 {
		return -1, fmt.Errorf("%s is outside this tunnel's AllowedIPs.", host)
	}
	var lastErr error
	for i, a := range inside {
		left := time.Until(deadline)
		if left <= 0 {
			break
		}
		share := left / time.Duration(len(inside)-i)
		dctx, dcancel := context.WithTimeout(ctx, share)
		tcp, err := t.tnet.DialContextTCPAddrPort(dctx, netip.AddrPortFrom(a, uint16(port)))
		dcancel()
		if err != nil {
			lastErr = err
			continue
		}
		fd, err := t.join(tcp)
		if err != nil {
			tcp.Close()
			return -1, err
		}
		return fd, nil
	}
	if lastErr == nil || errors.Is(lastErr, context.DeadlineExceeded) || strings.Contains(lastErr.Error(), "timed out") {
		return -1, errors.New("timeout: socket is not established")
	}
	return -1, fmt.Errorf("Connection refused through the tunnel: %v", lastErr)
}

// HasDNS says whether the configuration names DNS servers inside the tunnel.
func (t *Tunnel) HasDNS() bool { return t.hasDNS }

// Connections is how many connections are open through the tunnel.
func (t *Tunnel) Connections() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return len(t.pairs)
}

// LastHandshake is when the newest handshake with any peer completed, in Unix seconds, or 0.
func (t *Tunnel) LastHandshake() int64 { return t.stat("last_handshake_time_sec", true) }

// BytesIn is how much has come in from every peer.
func (t *Tunnel) BytesIn() int64 { return t.stat("rx_bytes", false) }

// BytesOut is how much has gone out to every peer.
func (t *Tunnel) BytesOut() int64 { return t.stat("tx_bytes", false) }

// Close takes the tunnel down and ends every connection through it.
func (t *Tunnel) Close() {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return
	}
	t.closed = true
	pairs := t.pairs
	t.pairs = map[*pair]struct{}{}
	t.mu.Unlock()
	for p := range pairs {
		p.close()
	}
	t.dev.Close()
}

func (t *Tunnel) routes(a netip.Addr) bool {
	for _, p := range t.allowed {
		if p.Contains(a.Unmap()) {
			return true
		}
	}
	return false
}

func (t *Tunnel) lookup(ctx context.Context, host string) ([]netip.Addr, error) {
	host = strings.TrimSuffix(strings.TrimPrefix(host, "["), "]")
	if a, err := netip.ParseAddr(host); err == nil {
		return []netip.Addr{a.Unmap()}, nil
	}
	if t.hasDNS {
		names, err := t.tnet.LookupContextHost(ctx, host)
		if err != nil || len(names) == 0 {
			return nil, fmt.Errorf("%s could not be found through the tunnel's DNS.", host)
		}
		return parseAddrs(names), nil
	}
	if t.resolver == nil {
		return nil, fmt.Errorf("%s could not be found.", host)
	}
	text, err := t.resolver.Resolve(host)
	if err != nil {
		return nil, fmt.Errorf("%s could not be found.", host)
	}
	addrs := parseAddrs(strings.Split(text, ","))
	if len(addrs) == 0 {
		return nil, fmt.Errorf("%s could not be found.", host)
	}
	return addrs, nil
}

func resolveOne(host string, resolver Resolver) (netip.Addr, error) {
	if a, err := netip.ParseAddr(host); err == nil {
		return a.Unmap(), nil
	}
	if resolver == nil {
		return netip.Addr{}, errors.New("no resolver")
	}
	text, err := resolver.Resolve(host)
	if err != nil {
		return netip.Addr{}, err
	}
	addrs := parseAddrs(strings.Split(text, ","))
	if len(addrs) == 0 {
		return netip.Addr{}, errors.New("no address")
	}
	// An IPv4 address first: a phone on IPv4-only mobile data cannot reach a v6 endpoint.
	for _, a := range addrs {
		if a.Is4() {
			return a, nil
		}
	}
	return addrs[0], nil
}

func parseAddrs(items []string) []netip.Addr {
	var out []netip.Addr
	for _, item := range items {
		if a, err := netip.ParseAddr(strings.TrimSpace(item)); err == nil {
			out = append(out, a.Unmap())
		}
	}
	return out
}

func (t *Tunnel) stat(key string, newest bool) int64 {
	text, err := t.dev.IpcGet()
	if err != nil {
		return 0
	}
	var total int64
	for _, line := range strings.Split(text, "\n") {
		k, v, ok := strings.Cut(line, "=")
		if !ok || k != key {
			continue
		}
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			continue
		}
		if newest {
			total = max(total, n)
		} else {
			total += n
		}
	}
	return total
}

// pair is one connection: the Go end of the socket pair and the TCP connection in the tunnel.
type pair struct {
	app  *net.UnixConn
	tcp  net.Conn
	once sync.Once
}

func (p *pair) close() {
	p.once.Do(func() {
		p.app.Close()
		p.tcp.Close()
	})
}

func (t *Tunnel) join(tcp net.Conn) (int, error) {
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		return -1, fmt.Errorf("The connection could not be handed to the app: %v", err)
	}
	file := os.NewFile(uintptr(fds[0]), "omnitunnel")
	fc, err := net.FileConn(file)
	file.Close()
	if err != nil {
		syscall.Close(fds[1])
		return -1, fmt.Errorf("The connection could not be handed to the app: %v", err)
	}
	p := &pair{app: fc.(*net.UnixConn), tcp: tcp}
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		p.close()
		syscall.Close(fds[1])
		return -1, errors.New("The tunnel is closed.")
	}
	t.pairs[p] = struct{}{}
	t.mu.Unlock()
	go t.splice(p)
	return fds[1], nil
}

// splice copies both ways. When the app closes its end the whole connection ends; when the host
// closes, the app reads the end of the stream and then closes its end.
func (t *Tunnel) splice(p *pair) {
	done := make(chan struct{})
	go func() {
		copyAll(p.app, p.tcp)
		_ = p.app.CloseWrite()
		close(done)
	}()
	copyAll(p.tcp, p.app)
	p.close()
	<-done
	t.mu.Lock()
	delete(t.pairs, p)
	t.mu.Unlock()
}

func copyAll(dst, src net.Conn) {
	buf := make([]byte, 32*1024)
	for {
		n, err := src.Read(buf)
		if n > 0 {
			if _, werr := dst.Write(buf[:n]); werr != nil {
				return
			}
		}
		if err != nil {
			return
		}
	}
}
