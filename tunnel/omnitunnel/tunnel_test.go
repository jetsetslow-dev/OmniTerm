package omnitunnel

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/curve25519"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

type keyPair struct{ private, public []byte }

func newKeys(t *testing.T) keyPair {
	priv := make([]byte, 32)
	if _, err := rand.Read(priv); err != nil {
		t.Fatal(err)
	}
	priv[0] &= 248
	priv[31] = (priv[31] & 127) | 64
	pub, err := curve25519.X25519(priv, curve25519.Basepoint)
	if err != nil {
		t.Fatal(err)
	}
	return keyPair{priv, pub}
}

func b64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

// peer is the far side: a WireGuard device on its own netstack at 10.77.0.1, listening on loopback
// UDP, with a TCP echo service on port 22 of its tunnel address and a refusing port 23.
type peer struct {
	dev  *device.Device
	port int
	keys keyPair
}

func startPeer(t *testing.T, client keyPair) *peer {
	t.Helper()
	keys := newKeys(t)
	udp, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	port := udp.LocalAddr().(*net.UDPAddr).Port
	udp.Close()
	tunDev, tnet, err := netstack.CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.77.0.1")}, nil, 1420)
	if err != nil {
		t.Fatal(err)
	}
	dev := device.NewDevice(tunDev, conn.NewDefaultBind(), device.NewLogger(device.LogLevelSilent, ""))
	uapi := fmt.Sprintf("private_key=%s\nlisten_port=%d\npublic_key=%s\nallowed_ip=10.77.0.2/32\n",
		hex.EncodeToString(keys.private), port, hex.EncodeToString(client.public))
	if err := dev.IpcSet(uapi); err != nil {
		t.Fatal(err)
	}
	if err := dev.Up(); err != nil {
		t.Fatal(err)
	}
	ln, err := tnet.ListenTCPAddrPort(netip.MustParseAddrPort("10.77.0.1:22"))
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
	t.Cleanup(func() { ln.Close(); dev.Close() })
	return &peer{dev, port, keys}
}

func clientConf(client keyPair, p *peer, endpointHost string, extra string) string {
	return fmt.Sprintf("[Interface]\nPrivateKey = %s\nAddress = 10.77.0.2/32\n%s\n[Peer]\nPublicKey = %s\nEndpoint = %s:%d\nAllowedIPs = 10.77.0.0/24\nPersistentKeepalive = 1\n",
		b64(client.private), extra, b64(p.keys.public), endpointHost, p.port)
}

type fakeResolver map[string]string

func (r fakeResolver) Resolve(host string) (string, error) {
	if a, ok := r[host]; ok {
		return a, nil
	}
	return "", errors.New("NXDOMAIN")
}

func fileOf(t *testing.T, fd int) *os.File {
	t.Helper()
	if fd < 0 {
		t.Fatal("no descriptor")
	}
	return os.NewFile(uintptr(fd), "app-end")
}

func TestATunnelCarriesAConnectionBothWays(t *testing.T) {
	client := newKeys(t)
	p := startPeer(t, client)
	tun, err := StartWireGuard(clientConf(client, p, "peer.lab", ""), fakeResolver{"peer.lab": "::1,127.0.0.1", "box.lab": "10.77.0.1"})
	if err != nil {
		t.Fatal(err)
	}
	defer tun.Close()

	fd, err := tun.DialFd("box.lab", 22, 10_000)
	if err != nil {
		t.Fatal(err)
	}
	f := fileOf(t, fd)
	if _, err := f.Write([]byte("hello through the tunnel")); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 64)
	f.SetReadDeadline(time.Now().Add(5 * time.Second))
	n, err := io.ReadAtLeast(f, buf, len("hello through the tunnel"))
	if err != nil || string(buf[:n]) != "hello through the tunnel" {
		t.Fatalf("echo: %q %v", buf[:n], err)
	}
	if tun.Connections() != 1 {
		t.Fatalf("connections %d", tun.Connections())
	}
	if tun.LastHandshake() == 0 || tun.BytesIn() == 0 || tun.BytesOut() == 0 {
		t.Fatal("a handshake and traffic are counted")
	}

	// A big transfer arrives whole and in order.
	big := make([]byte, 3<<20)
	rand.Read(big)
	go f.Write(big)
	got := make([]byte, len(big))
	f.SetReadDeadline(time.Now().Add(30 * time.Second))
	if _, err := io.ReadFull(f, got); err != nil || string(got) != string(big) {
		t.Fatalf("3 MiB echo: %v", err)
	}

	// The app closing its end ends the connection inside the tunnel too.
	f.Close()
	waitFor(t, func() bool { return tun.Connections() == 0 })
}

func TestWhatTheTunnelCannotReachIsRefusedClearly(t *testing.T) {
	client := newKeys(t)
	p := startPeer(t, client)
	tun, err := StartWireGuard(clientConf(client, p, "127.0.0.1", ""), fakeResolver{})
	if err != nil {
		t.Fatal(err)
	}
	defer tun.Close()
	if _, err := tun.DialFd("192.168.1.10", 22, 2_000); err == nil || !strings.Contains(err.Error(), "outside this tunnel's AllowedIPs") {
		t.Fatalf("outside: %v", err)
	}
	if _, err := tun.DialFd("nowhere.lab", 22, 2_000); err == nil || !strings.Contains(err.Error(), "could not be found") {
		t.Fatalf("unknown name: %v", err)
	}
	if _, err := tun.DialFd("10.77.0.1", 23, 5_000); err == nil || !strings.Contains(err.Error(), "refused") {
		t.Fatalf("closed port: %v", err)
	}
	if _, err := tun.DialFd("10.77.0.9", 22, 1_500); err == nil || !strings.Contains(err.Error(), "timeout") {
		t.Fatalf("no such host inside: %v", err)
	}
	if _, err := tun.DialFd("10.77.0.1", 0, 1_000); err == nil {
		t.Fatal("port 0")
	}
}

func TestClosingTheTunnelEndsItsConnections(t *testing.T) {
	client := newKeys(t)
	p := startPeer(t, client)
	tun, err := StartWireGuard(clientConf(client, p, "127.0.0.1", ""), nil)
	if err != nil {
		t.Fatal(err)
	}
	fd, err := tun.DialFd("10.77.0.1", 22, 10_000)
	if err != nil {
		t.Fatal(err)
	}
	f := fileOf(t, fd)
	defer f.Close()
	tun.Close()
	f.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := f.Read(make([]byte, 1)); err != io.EOF {
		t.Fatalf("the app reads the end of the stream, got %v", err)
	}
	if _, err := tun.DialFd("10.77.0.1", 22, 1_000); err == nil || !strings.Contains(err.Error(), "closed") {
		t.Fatalf("after close: %v", err)
	}
	tun.Close() // twice is harmless
}

func TestAWrongPeerKeyNeverConnects(t *testing.T) {
	client := newKeys(t)
	p := startPeer(t, client)
	p.keys = newKeys(t) // the client trusts a key the peer does not have
	tun, err := StartWireGuard(clientConf(client, p, "127.0.0.1", ""), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tun.Close()
	if _, err := tun.DialFd("10.77.0.1", 22, 2_000); err == nil {
		t.Fatal("connected without a handshake")
	}
	if tun.LastHandshake() != 0 {
		t.Fatal("no handshake")
	}
}

func TestAnEndpointThatCannotBeFoundStopsTheStart(t *testing.T) {
	client := newKeys(t)
	p := startPeer(t, client)
	_, err := StartWireGuard(clientConf(client, p, "gone.example", ""), fakeResolver{})
	if err == nil || !strings.Contains(err.Error(), "gone.example could not be found") {
		t.Fatalf("got %v", err)
	}
}

func waitFor(t *testing.T, ok func() bool) {
	t.Helper()
	for i := 0; i < 100; i++ {
		if ok() {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("timed out")
}
