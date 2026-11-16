// nebulalab is the repository's disposable Nebula lighthouse and SSH node. It uses the same
// pinned MIT userspace service as the phone; no kernel device, privileged container or host VPN.
package main

import (
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/slackhq/nebula"
	"github.com/slackhq/nebula/cert"
	"github.com/slackhq/nebula/config"
	"github.com/slackhq/nebula/logging"
	"github.com/slackhq/nebula/overlay"
	"github.com/slackhq/nebula/service"
)

func main() {
	state := flag.String("state", "/state", "private generated configuration folder")
	generate := flag.Bool("generate", false, "generate a fresh fixture identity set and exit")
	endpoint := flag.String("endpoint", "10.0.2.2:4242", "lighthouse's address as reached by the emulator")
	target := flag.String("target", "internal-a:2222", "repository SSH fixture reached by the Nebula node")
	flag.Parse()
	if *generate {
		if err := generateConfigs(*state, *endpoint); err != nil {
			fmt.Fprintln(os.Stderr, "Could not generate the Nebula fixture:", err)
			os.Exit(1)
		}
		return
	}
	lighthouse, err := start(filepath.Join(*state, "lighthouse.json"))
	if err != nil {
		fmt.Fprintln(os.Stderr, "Could not start the fixture lighthouse")
		os.Exit(1)
	}
	defer stop(lighthouse)
	node, err := start(filepath.Join(*state, "node.json"))
	if err != nil {
		fmt.Fprintln(os.Stderr, "Could not start the fixture node")
		os.Exit(1)
	}
	defer stop(node)
	listener, err := node.Listen("tcp4", ":22")
	if err != nil {
		fmt.Fprintln(os.Stderr, "Could not listen inside the fixture Nebula network")
		os.Exit(1)
	}
	defer listener.Close()
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go bridge(conn, *target)
		}
	}()
	fmt.Println("Nebula fixture ready: lighthouse 10.88.0.1, SSH node 10.88.0.3:22")
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	<-signals
}

func stop(s *service.Service) { _ = s.Close(); _ = s.Wait() }

func start(path string) (*service.Service, error) {
	c := config.NewC(logging.NewLogger(io.Discard))
	if err := c.Load(path); err != nil {
		return nil, err
	}
	control, err := nebula.Main(c, false, "OmniTerm fixture", logging.NewLogger(io.Discard), overlay.NewUserDeviceFromConfig)
	if err != nil {
		return nil, err
	}
	s, err := service.New(control)
	if err != nil {
		control.Stop()
	}
	return s, err
}

func bridge(inside net.Conn, target string) {
	defer inside.Close()
	outside, err := net.DialTimeout("tcp", target, 5*time.Second)
	if err != nil {
		return
	}
	defer outside.Close()
	finished := make(chan struct{})
	go func() { _, _ = io.Copy(inside, outside); _ = inside.Close(); close(finished) }()
	_, _ = io.Copy(outside, inside)
	_ = outside.Close()
	<-finished
}

func generateConfigs(dir, endpoint string) error {
	if _, err := netip.ParseAddrPort(endpoint); err != nil {
		return fmt.Errorf("endpoint must be IP:port")
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	pub, caKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	now := time.Now().Add(-time.Minute)
	ca, err := (&cert.TBSCertificate{
		Version: cert.Version2, Curve: cert.Curve_CURVE25519, Name: "OmniTerm disposable lab CA",
		IsCA: true, PublicKey: pub, NotBefore: now, NotAfter: now.Add(24 * time.Hour),
	}).Sign(nil, cert.Curve_CURVE25519, caKey)
	if err != nil {
		return err
	}
	caPEM, err := ca.MarshalPEM()
	if err != nil {
		return err
	}
	for i, name := range []string{"lighthouse", "phone", "node"} {
		key, err := ecdh.X25519().GenerateKey(rand.Reader)
		if err != nil {
			return err
		}
		identity, err := (&cert.TBSCertificate{
			Version: cert.Version2, Curve: cert.Curve_CURVE25519, Name: name,
			PublicKey: key.PublicKey().Bytes(), Networks: []netip.Prefix{netip.MustParsePrefix(fmt.Sprintf("10.88.0.%d/24", i+1))},
			NotBefore: now, NotAfter: now.Add(23 * time.Hour),
		}).Sign(ca, cert.Curve_CURVE25519, caKey)
		if err != nil {
			return err
		}
		identityPEM, err := identity.MarshalPEM()
		if err != nil {
			return err
		}
		underlay := "127.0.0.1:4242"
		if name == "phone" {
			underlay = endpoint
		}
		settings := map[string]any{
			"pki":             map[string]string{"ca": string(caPEM), "cert": string(identityPEM), "key": string(cert.MarshalPrivateKeyToPEM(cert.Curve_CURVE25519, key.Bytes()))},
			"static_host_map": map[string][]string{"10.88.0.1": {underlay}},
			"lighthouse":      map[string]any{"hosts": []string{"10.88.0.1"}, "interval": 1},
			"listen":          map[string]any{"host": "0.0.0.0", "port": 0},
			"firewall": map[string]any{
				"inbound":  []map[string]string{{"proto": "tcp", "port": "22", "host": "any"}},
				"outbound": []map[string]string{{"proto": "any", "port": "any", "host": "any"}},
			},
		}
		if name == "lighthouse" {
			settings["lighthouse"] = map[string]any{"am_lighthouse": true}
			settings["listen"] = map[string]any{"host": "0.0.0.0", "port": 4242}
			settings["static_host_map"] = map[string]any{}
		}
		// JSON is YAML too, and escaping the inline PEMs this way cannot corrupt indentation.
		raw, err := json.MarshalIndent(settings, "", "  ")
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(dir, name+".json"), raw, 0600); err != nil {
			return err
		}
	}
	return nil
}
