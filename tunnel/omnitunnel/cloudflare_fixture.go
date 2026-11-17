//go:build omniterm_access_fixture

// This file is absent from normal app builds. The opt-in device suite injects a fixture CA and
// endpoint into a separately built test AAR, leaving TLS chain and hostname checks enabled.
package omnitunnel

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"net"
	"net/http"
	"sync"
)

var accessFixture struct {
	sync.Mutex
	roots    *x509.CertPool
	endpoint string
}

// CloudflareFixture is available only with the explicit omniterm_access_fixture test build tag.
func CloudflareFixture(ca, endpoint string) error {
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM([]byte(ca)) {
		return errors.New("invalid fixture CA")
	}
	if _, _, err := net.SplitHostPort(endpoint); err != nil {
		return errors.New("invalid fixture endpoint")
	}
	accessFixture.Lock()
	defer accessFixture.Unlock()
	accessFixture.roots, accessFixture.endpoint = roots, endpoint
	return nil
}

func accessTransport() *http.Transport {
	transport := accessDefaultTransport()
	accessFixture.Lock()
	defer accessFixture.Unlock()
	if accessFixture.roots != nil {
		transport.TLSClientConfig = &tls.Config{RootCAs: accessFixture.roots, MinVersion: tls.VersionTLS12}
		endpoint := accessFixture.endpoint
		transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(address)
			if err != nil || port != "443" || !(host == "ssh.access.test" || host == "login.access.test" || host == "reject.access.test" || host == "ordinary.access.test") {
				return nil, errors.New("only repository fixture names are allowed")
			}
			return (&net.Dialer{}).DialContext(ctx, network, endpoint)
		}
	}
	return transport
}
