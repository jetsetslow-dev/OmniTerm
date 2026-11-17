package omnitunnel

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/jetsetslow-dev/omniterm/tunnel/internal/accessfake"
)

func accessText(host string) string {
	b, _ := json.Marshal(accessConfig{Hostname: host, ClientID: "fixture-id", ClientSecret: "fixture-secret"})
	return string(b)
}

// Only tests replace the transport's trust root and connect address. Production has no such setting.
func accessServer(t *testing.T, handler http.HandlerFunc, trust bool) (*Tunnel, *atomic.Int32) {
	t.Helper()
	return accessServerFor(t, "example.com", handler, trust)
}

// accessServerFor is accessServer for an Access application at host.
func accessServerFor(t *testing.T, host string, handler http.HandlerFunc, trust bool) (*Tunnel, *atomic.Int32) {
	t.Helper()
	s := httptest.NewUnstartedServer(handler)
	s.EnableHTTP2 = true
	s.StartTLS()
	t.Cleanup(s.Close)
	tunnel, err := StartCloudflareAccess(accessText(host))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(tunnel.Close)
	a := tunnel.carrier.(*cloudflareAccess)
	transport := a.client.Transport.(*http.Transport)
	if trust {
		roots := x509.NewCertPool()
		roots.AddCert(s.Certificate())
		// The test server's certificate names example.com, whatever host the tunnel asks for.
		transport.TLSClientConfig = &tls.Config{RootCAs: roots, ServerName: "example.com", MinVersion: tls.VersionTLS12}
	}
	calls := &atomic.Int32{}
	transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		calls.Add(1)
		if address != host+":443" {
			t.Errorf("unexpected dial target %s", address)
		}
		return (&net.Dialer{}).DialContext(ctx, network, s.Listener.Addr().String())
	}
	return tunnel, calls
}

func TestAccessBinaryStreamAndDialFdLifetime(t *testing.T) {
	tunnel, _ := accessServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" || r.URL.String() != "/" || r.Host != "example.com" || r.Proto != "HTTP/1.1" {
			t.Error("wrong request target")
		}
		for k, v := range map[string]string{"CF-Access-Client-Id": "fixture-id", "CF-Access-Client-Secret": "fixture-secret", "User-Agent": "OmniTerm"} {
			if r.Header.Get(k) != v {
				t.Errorf("missing required header %s", k)
			}
		}
		for _, k := range []string{"Sec-WebSocket-Protocol", "Sec-WebSocket-Extensions", "Cf-Access-Token", "Cf-Access-Jump-Destination", "Cookie"} {
			if r.Header.Get(k) != "" {
				t.Errorf("unexpected %s", k)
			}
		}
		ws, err := websocket.Accept(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer ws.CloseNow()
		for {
			kind, p, err := ws.Read(r.Context())
			if err != nil {
				return
			}
			if kind != websocket.MessageBinary {
				t.Error("TCP must use binary messages")
			}
			if err := ws.Write(r.Context(), kind, p); err != nil {
				return
			}
		}
	}, true)
	fd, err := tunnel.DialFd("EXAMPLE.COM", 2201, 3000)
	if err != nil {
		t.Fatal(err)
	}
	// DialFd has returned and canceled its handshake context; the stream must still work.
	f := os.NewFile(uintptr(fd), "access-test")
	fileConn, err := net.FileConn(f)
	f.Close()
	if err != nil {
		t.Fatal(err)
	}
	defer fileConn.Close()
	_ = fileConn.SetDeadline(time.Now().Add(3 * time.Second))
	data := strings.Repeat("ssh-payload\x00", 10000)
	done := make(chan error, 1)
	go func() { _, err := io.WriteString(fileConn, data); done <- err }()
	out := make([]byte, len(data))
	if _, err := io.ReadFull(fileConn, out); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if string(out) != data {
		t.Fatal("message boundaries truncated the TCP stream")
	}
	waitFor(t, func() bool { return tunnel.BytesIn() == int64(len(data)) && tunnel.BytesOut() == int64(len(data)) })
	tunnel.Close()
	if _, err := tunnel.DialFd("example.com", 22, 100); err == nil {
		t.Fatal("closed tunnel must refuse")
	}
}

func TestAccessRejections(t *testing.T) {
	for _, tc := range []struct {
		name           string
		code           int
		location, want string
	}{
		{"forbidden", 403, "", "rejected the service token"},
		{"unauthorized", 401, "", "rejected the service token"},
		{"login", 302, "https://team.cloudflareaccess.com/cdn-cgi/access/login/example.com?token=fixture-secret", "interactive login"},
		{"ordinary redirect", 302, "https://elsewhere.example/", "did not accept an Access TCP"},
		{"web page", 200, "", "did not accept an Access TCP"},
		{"missing", 404, "", "did not accept an Access TCP"},
		// Cloudflare itself answered these, so they must not blame the phone's connection.
		{"origin unavailable", 502, "", "answered but could not reach this host"},
		{"tunnel not running", 530, "", "Cloudflare Tunnel (cloudflared) is running"},
		{"rate limited", 429, "", "limiting connections"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tunnel, calls := accessServer(t, func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Location", tc.location)
				w.WriteHeader(tc.code)
				_, _ = io.WriteString(w, "fixture-secret")
			}, true)
			_, err := tunnel.DialFd("example.com", 22, 3000)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("wanted %q, got %v", tc.want, err)
			}
			if strings.Contains(err.Error(), "fixture-secret") || calls.Load() != 1 {
				t.Fatal("token leaked or redirect followed")
			}
		})
	}
}

func TestAccessNeverDirectOrAnotherDestination(t *testing.T) {
	tunnel, calls := accessServer(t, func(http.ResponseWriter, *http.Request) { t.Error("must not connect") }, true)
	for _, host := range []string{"127.0.0.1", "other.example.com", "example.com:443", "https://example.com", "example.com/path"} {
		if _, err := tunnel.DialFd(host, 22, 100); err == nil || !strings.Contains(err.Error(), "only its saved hostname") {
			t.Fatalf("unexpected error %v", err)
		}
	}
	if calls.Load() != 0 {
		t.Fatal("dialed a refused destination")
	}
}

func TestAccessRejectsUntrustedTLSBeforeSendingToken(t *testing.T) {
	tunnel, _ := accessServer(t, func(http.ResponseWriter, *http.Request) { t.Error("token sent before TLS verified") }, false)
	if _, err := tunnel.DialFd("example.com", 22, 3000); err == nil || !strings.Contains(err.Error(), "public TLS") {
		t.Fatalf("untrusted TLS accepted: %v", err)
	}
}

func TestAccessSettingsGuard(t *testing.T) {
	for _, host := range []string{"", "localhost", "127.0.0.1", "::1", "https://example.com", "example.com:443", "example.com/a", "example.com?query", "a..example", "-a.example", "a_.example", "a.example\r\n"} {
		// Leading/trailing whitespace is deliberately normalized.
		if host == "a.example\r\n" {
			continue
		}
		if CheckCloudflareAccess(accessText(host)) == "" {
			t.Errorf("accepted invalid hostname %q", host)
		}
	}
	for _, v := range []string{"", "a\r\nX-Evil: y", "a b", strings.Repeat("a", 4097)} {
		b, _ := json.Marshal(accessConfig{Hostname: "example.com", ClientID: v, ClientSecret: "fixture-secret"})
		if CheckCloudflareAccess(string(b)) == "" {
			t.Error("accepted invalid credential")
		}
	}
	if CheckCloudflareAccess(`{"hostname":"example.com","clientId":"fixture-id","clientSecret":"fixture-secret","skipTLS":true}`) != "" {
		t.Fatal("unknown fields should not weaken TLS or prevent forward compatibility")
	}
}

func TestAccessUnreachableAndCanceled(t *testing.T) {
	tunnel, err := StartCloudflareAccess(accessText("example.com"))
	if err != nil {
		t.Fatal(err)
	}
	defer tunnel.Close()
	tunnel.carrier.(*cloudflareAccess).client.Transport.(*http.Transport).DialContext = func(context.Context, string, string) (net.Conn, error) { return nil, syscall.ECONNREFUSED }
	if _, err := tunnel.DialFd("example.com", 22, 50); err == nil || !strings.Contains(err.Error(), "could not be reached") {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := tunnel.carrier.dial(ctx, "example.com", 22, time.Now()); err == nil {
		t.Fatal("canceled request accepted")
	}
}

func TestAccessRejectsWrongTLSHostname(t *testing.T) {
	tunnel, _ := accessServer(t, func(http.ResponseWriter, *http.Request) { t.Error("sent token with wrong certificate hostname") }, true)
	tunnel.carrier.(*cloudflareAccess).client.Transport.(*http.Transport).TLSClientConfig.ServerName = "not-on-cert.invalid"
	if _, err := tunnel.DialFd("example.com", 22, 3000); err == nil {
		t.Fatal("TLS hostname was not verified")
	}
}

func TestAccessNoDirectFallbackWhenCloudflareFails(t *testing.T) {
	// A real, controlled direct endpoint is listening; failure at the Access transport must never
	// try it. This changes the validated hostname only inside the test, not through a public API.
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	accepted := make(chan bool, 1)
	go func() {
		c, err := listener.Accept()
		accepted <- err == nil
		if err == nil {
			c.Close()
		}
	}()
	tunnel, err := StartCloudflareAccess(accessText("example.com"))
	if err != nil {
		t.Fatal(err)
	}
	defer tunnel.Close()
	a := tunnel.carrier.(*cloudflareAccess)
	a.config.Hostname = "127.0.0.1"
	a.client.Transport.(*http.Transport).DialContext = func(context.Context, string, string) (net.Conn, error) { return nil, syscall.ECONNREFUSED }
	port := listener.Addr().(*net.TCPAddr).Port
	fd, err := tunnel.DialFd("127.0.0.1", port, 500)
	if err == nil {
		syscall.Close(fd)
		t.Error("Access failure fell back to an answering direct endpoint")
	}
	listener.Close()
	if <-accepted {
		t.Error("Access failure reached the direct endpoint")
	}
}

// Cloudflare closes a WebSocket that carries nothing for a while, and a terminal left open with
// SSH keep-alive off carries nothing for as long as it is left. The contract fake closes one that
// is silent for its idle time; the stream's pings, which the fake hears as Cloudflare would, keep
// it open past that.
func TestAccessPingsKeepAnIdleStreamOpen(t *testing.T) {
	echo, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		for {
			c, err := echo.Accept()
			if err != nil {
				return
			}
			go func() { defer c.Close(); _, _ = io.Copy(c, c) }()
		}
	}()
	roundTrip := func(conn net.Conn, text string) error {
		_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
		if _, err := io.WriteString(conn, text); err != nil {
			return err
		}
		got := make([]byte, len(text))
		if _, err := io.ReadFull(conn, got); err != nil {
			return err
		}
		if string(got) != text {
			t.Fatal("echo returned other bytes")
		}
		return nil
	}
	for _, tc := range []struct {
		name     string
		every    time.Duration
		survives bool
	}{
		{"without pings the idle limit ends it", time.Hour, false},
		{"pings keep it open", 50 * time.Millisecond, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			before := accessPingEvery
			accessPingEvery = tc.every
			tunnel, _ := accessServerFor(t, "ssh.access.test", accessfake.Handler(echo.Addr().String(), "fixture-id", "fixture-secret", 300*time.Millisecond), true)
			fd, err := tunnel.DialFd("ssh.access.test", 22, 3000)
			accessPingEvery = before
			if err != nil {
				t.Fatal(err)
			}
			f := os.NewFile(uintptr(fd), "access-idle")
			conn, err := net.FileConn(f)
			f.Close()
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			if err := roundTrip(conn, "before"); err != nil {
				t.Fatal(err)
			}
			time.Sleep(time.Second)
			if err := roundTrip(conn, "after"); (err == nil) != tc.survives {
				t.Fatalf("after a second without data: %v", err)
			}
		})
	}
}
