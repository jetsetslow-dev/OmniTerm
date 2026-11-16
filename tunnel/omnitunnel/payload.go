package omnitunnel

import (
	"net"
	"sync/atomic"
)

// TCP payload totals, without claiming a network handshake timestamp that a carrier cannot read.
type payloadCounters struct{ rx, tx atomic.Int64 }

func (p *payloadCounters) wrap(c net.Conn) net.Conn { return &payloadConnection{Conn: c, totals: p} }

type payloadConnection struct {
	net.Conn
	totals *payloadCounters
}

func (c *payloadConnection) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	c.totals.rx.Add(int64(n))
	return n, err
}
func (c *payloadConnection) Write(p []byte) (int, error) {
	n, err := c.Conn.Write(p)
	c.totals.tx.Add(int64(n))
	return n, err
}
