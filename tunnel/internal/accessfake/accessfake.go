// Package accessfake is a contract fake of a Cloudflare Access TCP application, from our reading
// of cloudflared, not a Cloudflare service. The fixture container (cmd/accesslab) and the
// carrier's tests share it.
package accessfake

import (
	"context"
	"crypto/subtle"
	"io"
	"net"
	"net/http"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
)

// Idle is how long the fake keeps a WebSocket that carries nothing in either direction: no data,
// no ping and no pong. Cloudflare closes such a connection
// (developers.cloudflare.com/network/websockets/) and recommends a client-side ping/pong heartbeat
// against it, without giving the time. 100 seconds is our assumption, not Cloudflare's figure.
const Idle = 100 * time.Second

// Handler answers the four fixture names, and bridges ssh.access.test's binary WebSocket to target
// for a request with the service token id and secret. A WebSocket silent for idle is closed.
func Handler(target, id, secret string, idle time.Duration) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" || r.Header.Get("Sec-WebSocket-Protocol") != "" || r.Header.Get("Cf-Access-Jump-Destination") != "" {
			http.Error(w, "not supported", 400)
			return
		}
		switch r.Host {
		case "login.access.test":
			http.Redirect(w, r, "https://login.access.test/cdn-cgi/access/login/ssh.access.test", http.StatusFound)
			return
		case "ordinary.access.test":
			http.Error(w, "ordinary web application", http.StatusOK)
			return
		case "reject.access.test":
			http.Error(w, "denied", http.StatusForbidden)
			return
		case "ssh.access.test":
		default:
			http.NotFound(w, r)
			return
		}
		if subtle.ConstantTimeCompare([]byte(r.Header.Get("CF-Access-Client-Id")), []byte(id)) != 1 ||
			subtle.ConstantTimeCompare([]byte(r.Header.Get("CF-Access-Client-Secret")), []byte(secret)) != 1 {
			http.Error(w, "denied", http.StatusForbidden)
			return
		}
		tcp, err := net.DialTimeout("tcp", target, 5*time.Second)
		if err != nil {
			http.Error(w, "origin unavailable", 502)
			return
		}
		defer tcp.Close()
		var last atomic.Int64
		heard := func() { last.Store(time.Now().UnixNano()) }
		heard()
		ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{
			OnPingReceived: func(context.Context, []byte) bool { heard(); return true },
			OnPongReceived: func(context.Context, []byte) { heard() },
		})
		if err != nil {
			return
		}
		defer ws.CloseNow()
		done := make(chan struct{})
		defer close(done)
		go func() {
			tick := time.NewTicker(idle / 10)
			defer tick.Stop()
			for {
				select {
				case <-done:
					return
				case <-tick.C:
					if time.Since(time.Unix(0, last.Load())) > idle {
						// As an idle timeout does: no close handshake, the connection just ends.
						ws.CloseNow()
						tcp.Close()
						return
					}
				}
			}
		}()
		stream := &heardConn{Conn: websocket.NetConn(context.Background(), ws, websocket.MessageBinary), heard: heard}
		copied := make(chan struct{})
		go func() { _, _ = io.Copy(tcp, stream); _ = tcp.Close(); close(copied) }()
		_, _ = io.Copy(stream, tcp)
		_ = stream.Close()
		<-copied
	}
}

// heardConn counts data either way as activity.
type heardConn struct {
	net.Conn
	heard func()
}

func (c *heardConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	if n > 0 {
		c.heard()
	}
	return n, err
}

func (c *heardConn) Write(p []byte) (int, error) {
	n, err := c.Conn.Write(p)
	if n > 0 {
		c.heard()
	}
	return n, err
}
