package omnitunnel

import (
	"bufio"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net/netip"
	"strconv"
	"strings"
)

// wireGuardConf is a wg-quick configuration as OmniTerm uses it: one interface, its peers, and
// nothing that wg-quick would run on the system (PostUp, Table and the like are read and ignored,
// because a tunnel here never touches the phone's own network).
type wireGuardConf struct {
	privateKey string // hex, for the UAPI
	listenPort int
	addresses  []netip.Addr
	dns        []netip.Addr
	mtu        int
	peers      []wireGuardPeer
}

type wireGuardPeer struct {
	publicKey    string // hex
	presharedKey string // hex, or empty
	endpoint     string // host:port as written; resolved when the tunnel starts
	allowed      []netip.Prefix
	keepalive    int
}

const defaultMTU = 1420

// confError is a problem with the configuration a user pasted. Its text names the line and the
// field but never repeats a value, so a key can never end up in a message.
type confError struct {
	line int
	msg  string
}

func (e *confError) Error() string {
	if e.line == 0 {
		return e.msg
	}
	return fmt.Sprintf("Line %d: %s", e.line, e.msg)
}

func parseWireGuard(text string) (*wireGuardConf, error) {
	conf := &wireGuardConf{mtu: defaultMTU}
	section := ""
	var peer *wireGuardPeer
	sawInterface := false
	scanner := bufio.NewScanner(strings.NewReader(text))
	scanner.Buffer(make([]byte, 0, 4096), 1<<20)
	for n := 1; scanner.Scan(); n++ {
		line := scanner.Text()
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = line[:i]
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.ToLower(strings.TrimSpace(line[1 : len(line)-1]))
			switch section {
			case "interface":
				if sawInterface {
					return nil, &confError{n, "there is a second [Interface]."}
				}
				sawInterface = true
			case "peer":
				conf.peers = append(conf.peers, wireGuardPeer{})
				peer = &conf.peers[len(conf.peers)-1]
			default:
				return nil, &confError{n, "only [Interface] and [Peer] sections are understood."}
			}
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			return nil, &confError{n, "expected Key = value."}
		}
		key = strings.ToLower(strings.TrimSpace(key))
		value = strings.TrimSpace(value)
		var err error
		switch section {
		case "interface":
			err = conf.set(key, value)
		case "peer":
			err = peer.set(key, value)
		default:
			return nil, &confError{n, "a setting comes before any [Interface] or [Peer]."}
		}
		if err != nil {
			return nil, &confError{n, err.Error()}
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, &confError{0, "The configuration could not be read."}
	}
	switch {
	case !sawInterface:
		return nil, &confError{0, "There is no [Interface] section."}
	case conf.privateKey == "":
		return nil, &confError{0, "[Interface] has no PrivateKey."}
	case len(conf.addresses) == 0:
		return nil, &confError{0, "[Interface] has no Address."}
	case len(conf.peers) == 0:
		return nil, &confError{0, "There is no [Peer] section."}
	}
	reachable := false
	for i, p := range conf.peers {
		if p.publicKey == "" {
			return nil, &confError{0, fmt.Sprintf("[Peer] %d has no PublicKey.", i+1)}
		}
		if len(p.allowed) == 0 {
			return nil, &confError{0, fmt.Sprintf("[Peer] %d has no AllowedIPs, so nothing would go through it.", i+1)}
		}
		if p.endpoint != "" {
			reachable = true
		}
	}
	if !reachable {
		return nil, &confError{0, "No [Peer] has an Endpoint, so the tunnel could never connect."}
	}
	return conf, nil
}

func (c *wireGuardConf) set(key, value string) error {
	switch key {
	case "privatekey":
		k, err := wireGuardKey(value)
		if err != nil {
			return fmt.Errorf("PrivateKey %w", err)
		}
		c.privateKey = k
	case "address":
		for _, item := range list(value) {
			addr, err := addressOf(item)
			if err != nil {
				return fmt.Errorf("Address is not an IP address or prefix.")
			}
			c.addresses = append(c.addresses, addr)
		}
	case "dns":
		// wg-quick also takes search domains here; only the servers matter to a tunnel.
		for _, item := range list(value) {
			if addr, err := netip.ParseAddr(item); err == nil {
				c.dns = append(c.dns, addr)
			}
		}
	case "mtu":
		mtu, err := strconv.Atoi(value)
		if err != nil || mtu < 576 || mtu > 65535 {
			return fmt.Errorf("MTU must be a number from 576 to 65535.")
		}
		c.mtu = mtu
	case "listenport":
		port, err := strconv.Atoi(value)
		if err != nil || port < 0 || port > 65535 {
			return fmt.Errorf("ListenPort must be a port number.")
		}
		c.listenPort = port
	case "table", "fwmark", "saveconfig", "preup", "postup", "predown", "postdown":
		// Settings for the system's own interface. A tunnel here has none, so they do nothing.
	default:
		return fmt.Errorf("%s is not an [Interface] setting.", key)
	}
	return nil
}

func (p *wireGuardPeer) set(key, value string) error {
	switch key {
	case "publickey":
		k, err := wireGuardKey(value)
		if err != nil {
			return fmt.Errorf("PublicKey %w", err)
		}
		p.publicKey = k
	case "presharedkey":
		k, err := wireGuardKey(value)
		if err != nil {
			return fmt.Errorf("PresharedKey %w", err)
		}
		p.presharedKey = k
	case "endpoint":
		host, port, err := splitEndpoint(value)
		if err != nil {
			return err
		}
		p.endpoint = joinHostPort(host, port)
	case "allowedips":
		for _, item := range list(value) {
			prefix, err := prefixOf(item)
			if err != nil {
				return fmt.Errorf("AllowedIPs has an entry that is not an IP prefix.")
			}
			p.allowed = append(p.allowed, prefix)
		}
	case "persistentkeepalive":
		if strings.EqualFold(value, "off") {
			p.keepalive = 0
			return nil
		}
		seconds, err := strconv.Atoi(value)
		if err != nil || seconds < 0 || seconds > 65535 {
			return fmt.Errorf("PersistentKeepalive must be a number of seconds or off.")
		}
		p.keepalive = seconds
	default:
		return fmt.Errorf("%s is not a [Peer] setting.", key)
	}
	return nil
}

// uapi is the configuration in wireguard-go's own protocol, with endpoints already resolved.
func (c *wireGuardConf) uapi(endpoints []string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "private_key=%s\n", c.privateKey)
	if c.listenPort != 0 {
		fmt.Fprintf(&b, "listen_port=%d\n", c.listenPort)
	}
	b.WriteString("replace_peers=true\n")
	for i, p := range c.peers {
		fmt.Fprintf(&b, "public_key=%s\n", p.publicKey)
		if p.presharedKey != "" {
			fmt.Fprintf(&b, "preshared_key=%s\n", p.presharedKey)
		}
		if endpoints[i] != "" {
			fmt.Fprintf(&b, "endpoint=%s\n", endpoints[i])
		}
		if p.keepalive > 0 {
			fmt.Fprintf(&b, "persistent_keepalive_interval=%d\n", p.keepalive)
		}
		b.WriteString("replace_allowed_ips=true\n")
		for _, prefix := range p.allowed {
			fmt.Fprintf(&b, "allowed_ip=%s\n", prefix)
		}
	}
	return b.String()
}

func (c *wireGuardConf) allowedPrefixes() []netip.Prefix {
	var all []netip.Prefix
	for _, p := range c.peers {
		all = append(all, p.allowed...)
	}
	return all
}

func wireGuardKey(text string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(text)
	if err != nil || len(raw) != 32 {
		return "", fmt.Errorf("is not a WireGuard key.")
	}
	return hex.EncodeToString(raw), nil
}

func list(value string) []string {
	var out []string
	for _, item := range strings.Split(value, ",") {
		if item = strings.TrimSpace(item); item != "" {
			out = append(out, item)
		}
	}
	return out
}

func addressOf(item string) (netip.Addr, error) {
	if prefix, err := netip.ParsePrefix(item); err == nil {
		return prefix.Addr(), nil
	}
	return netip.ParseAddr(item)
}

func prefixOf(item string) (netip.Prefix, error) {
	if prefix, err := netip.ParsePrefix(item); err == nil {
		return prefix.Masked(), nil
	}
	addr, err := netip.ParseAddr(item)
	if err != nil {
		return netip.Prefix{}, err
	}
	return netip.PrefixFrom(addr, addr.BitLen()), nil
}

func splitEndpoint(value string) (string, int, error) {
	var host, portText string
	if strings.HasPrefix(value, "[") {
		end := strings.Index(value, "]:")
		if end < 0 {
			return "", 0, fmt.Errorf("Endpoint must be host:port.")
		}
		host, portText = value[1:end], value[end+2:]
	} else {
		i := strings.LastIndexByte(value, ':')
		if i <= 0 || strings.Count(value, ":") > 1 {
			return "", 0, fmt.Errorf("Endpoint must be host:port, with an IPv6 address in brackets.")
		}
		host, portText = value[:i], value[i+1:]
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 1 || port > 65535 || host == "" {
		return "", 0, fmt.Errorf("Endpoint must be host:port.")
	}
	return host, port, nil
}

func joinHostPort(host string, port int) string {
	if strings.Contains(host, ":") {
		return fmt.Sprintf("[%s]:%d", host, port)
	}
	return fmt.Sprintf("%s:%d", host, port)
}
