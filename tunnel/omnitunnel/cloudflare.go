package omnitunnel

// Protocol reference only: cloudflare/cloudflared (Apache-2.0), carrier/websocket.go,
// cmd/cloudflared/access/carrier.go and websocket/connection.go. No upstream code copied.
import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

type accessConfig struct {
	Hostname     string `json:"hostname"`
	ClientID     string `json:"clientId"`
	ClientSecret string `json:"clientSecret"`
}

func parseAccess(text string) (*accessConfig, error) {
	var c accessConfig
	if json.Unmarshal([]byte(text), &c) != nil {
		return nil, errors.New("Enter the Cloudflare Access settings again.")
	}
	c.Hostname = strings.ToLower(strings.TrimSpace(c.Hostname))
	if !isHostName(c.Hostname) {
		return nil, errors.New("Enter the Access application's hostname only, such as ssh.example.com, without a URL, path or port.")
	}
	for _, v := range []string{c.ClientID, c.ClientSecret} {
		if v == "" || len(v) > 4096 {
			return nil, errors.New("Enter both the service token's client ID and secret.")
		}
		for _, ch := range v {
			if ch < 33 || ch > 126 {
				return nil, errors.New("The service token must contain only visible characters without spaces.")
			}
		}
	}
	return &c, nil
}

// CheckCloudflareAccess validates locally; it never contacts Cloudflare.
func CheckCloudflareAccess(text string) string {
	_, err := parseAccess(text)
	if err != nil {
		return err.Error()
	}
	return ""
}

type cloudflareAccess struct {
	config *accessConfig
	client *http.Client
	payloadCounters
}

// StartCloudflareAccess prepares an opt-in service-token carrier; only DialFd makes a request.
// Each record is restricted to one published hostname, HTTPS port 443 and path /. The host's
// port is used for its direct Wi-Fi route only: Cloudflare's origin configuration selects the
// SSH destination. Arbitrary destinations/bastion mode, UDP and interactive login are unsupported.
func StartCloudflareAccess(text string) (*Tunnel, error) {
	c, err := parseAccess(text)
	if err != nil {
		return nil, err
	}
	transport := accessTransport()
	// Normal platform public roots and hostname verification. No user-configurable TLS bypass.
	return newTunnel(&cloudflareAccess{config: c, client: &http.Client{
		Transport:     transport,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}), nil
}

func (a *cloudflareAccess) dial(ctx context.Context, host string, _ int, _ time.Time) (net.Conn, error) {
	if !strings.EqualFold(host, a.config.Hostname) {
		return nil, errors.New("This Cloudflare Access tunnel reaches only its saved hostname. Set Address through the tunnel to that hostname; other destinations are not supported.")
	}
	headers := make(http.Header)
	headers.Set("CF-Access-Client-Id", a.config.ClientID)
	headers.Set("CF-Access-Client-Secret", a.config.ClientSecret)
	headers.Set("User-Agent", "OmniTerm")
	ws, resp, err := websocket.Dial(ctx, "https://"+a.config.Hostname+"/", &websocket.DialOptions{
		HTTPClient: a.client, HTTPHeader: headers, CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		return nil, accessFailure(resp)
	}
	// Dial's deadline must not cancel a successfully opened stream when DialFd returns.
	stream := &accessStream{Conn: websocket.NetConn(context.Background(), ws, websocket.MessageBinary), done: make(chan struct{})}
	go accessKeepAlive(ws, accessPingEvery, stream.done)
	return a.payloadCounters.wrap(stream), nil
}

// accessPingEvery is how often an open stream pings Cloudflare. Cloudflare closes a WebSocket
// that carries nothing for a while and asks clients for a ping/pong heartbeat
// (developers.cloudflare.com/network/websockets/), and a terminal left idle with SSH keep-alive
// off carries nothing. cloudflared's client side sends no pings (carrier/websocket.go); its
// origin side pings every 54 s (websocket/connection.go, defaultPingPeriod = defaultPongWait*9/10
// with defaultPongWait 60 s), and that period is used here.
var accessPingEvery = 54 * time.Second

// accessKeepAlive pings until done closes. A ping that gets no pong changes nothing: SSH's own
// keep-alive decides when a connection is dead. Pongs are read while the stream reads, which the
// tunnel's copy always is.
func accessKeepAlive(ws *websocket.Conn, every time.Duration, done <-chan struct{}) {
	tick := time.NewTicker(every)
	defer tick.Stop()
	for {
		select {
		case <-done:
			return
		case <-tick.C:
			ctx, cancel := context.WithTimeout(context.Background(), every)
			_ = ws.Ping(ctx)
			cancel()
		}
	}
}

// accessStream ends its pings when the connection is closed.
type accessStream struct {
	net.Conn
	once sync.Once
	done chan struct{}
}

func (s *accessStream) Close() error {
	s.once.Do(func() { close(s.done) })
	return s.Conn.Close()
}

// Never return server bodies, Location queries or underlying request errors: they may reflect
// either token. A denial cannot tell an expired token from a policy that refuses that token.
func accessFailure(resp *http.Response) error {
	if resp == nil {
		return errors.New("Cloudflare could not be reached. Check your connection and try again; also check the hostname and its public TLS certificate.")
	}
	// Cloudflare answered: 502, 521-523 and 530 (error 1033) mean its tunnel or the SSH service
	// behind it is down, which the phone's connection cannot fix.
	if resp.StatusCode >= 500 {
		return errors.New("Cloudflare answered but could not reach this host. Check that its Cloudflare Tunnel (cloudflared) is running and its SSH service is up.")
	}
	if resp.StatusCode == 429 {
		return errors.New("Cloudflare is limiting connections to this hostname. Wait a minute and try again.")
	}
	if resp.StatusCode == 401 || resp.StatusCode == 403 {
		return errors.New("Cloudflare rejected the service token. Check its client ID, secret and expiry, and that the Access policy allows this token.")
	}
	if resp.StatusCode >= 300 && resp.StatusCode < 400 {
		if location, err := url.Parse(resp.Header.Get("Location")); err == nil && strings.HasPrefix(location.Path, "/cdn-cgi/access/login") {
			return errors.New("This Access application wants an interactive login. Its policy must allow a service token with Service Auth; OmniTerm cannot sign in with a browser.")
		}
	}
	return errors.New("This hostname did not accept an Access TCP connection. Check that it is an Access application publishing SSH through a Cloudflare Tunnel.")
}

func (a *cloudflareAccess) hasDNS() bool         { return true }
func (a *cloudflareAccess) state() string        { return StateRunning }
func (a *cloudflareAccess) authURL() string      { return "" }
func (a *cloudflareAccess) problem() string      { return "" }
func (a *cloudflareAccess) addresses() string    { return a.config.Hostname }
func (a *cloudflareAccess) lastHandshake() int64 { return 0 }
func (a *cloudflareAccess) bytesIn() int64       { return a.rx.Load() }
func (a *cloudflareAccess) bytesOut() int64      { return a.tx.Load() }
func (a *cloudflareAccess) close()               { a.client.CloseIdleConnections() }

func accessDefaultTransport() *http.Transport {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	// RFC 6455 upgrade, matching cloudflared; do not negotiate HTTP/2 extended CONNECT.
	transport.Protocols = new(http.Protocols)
	transport.Protocols.SetHTTP1(true)
	return transport
}
