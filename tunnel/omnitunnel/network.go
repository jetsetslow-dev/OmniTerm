package omnitunnel

import (
	"net"
	"net/netip"
	"strconv"
	"strings"

	"tailscale.com/net/netmon"
)

// Network tells Tailscale about the phone's network interfaces, which Android does not let Go read
// itself (netlink is closed to apps), as the Tailscale Android app does.
type Network interface {
	// Interfaces lists the interfaces, one per line: name, index, MTU, flags and addresses, split
	// by spaces. The flags are letters: u (up), l (loopback), p (point-to-point), m (multicast),
	// b (broadcast), or "-" for none. The addresses are prefixes split by commas, or "-".
	Interfaces() string
}

// SetNetwork makes every Tailscale tunnel ask network for the interfaces.
func SetNetwork(network Network) {
	netmon.RegisterInterfaceGetter(func() ([]netmon.Interface, error) {
		return parseInterfaces(network.Interfaces()), nil
	})
}

// NetworkChanged tells the Tailscale tunnels that are up that the phone's connections now go over
// the interface named defaultInterface ("" for none), so they find their paths again at once.
func NetworkChanged(defaultInterface string) {
	setDefaultInterface(defaultInterface)
	nebulaNetworkChanged()
	live.each(func(ts *tailscale) {
		if mon, ok := ts.srv.Sys().NetMon.GetOK(); ok {
			mon.InjectEvent()
		}
	})
}

func parseInterfaces(text string) []netmon.Interface {
	var out []netmon.Interface
	for _, line := range strings.Split(text, "\n") {
		fields := strings.Fields(line)
		if len(fields) != 5 {
			continue
		}
		index, err1 := strconv.Atoi(fields[1])
		mtu, err2 := strconv.Atoi(fields[2])
		if err1 != nil || err2 != nil {
			continue
		}
		var flags net.Flags
		for _, f := range fields[3] {
			switch f {
			case 'u':
				flags |= net.FlagUp | net.FlagRunning
			case 'l':
				flags |= net.FlagLoopback
			case 'p':
				flags |= net.FlagPointToPoint
			case 'm':
				flags |= net.FlagMulticast
			case 'b':
				flags |= net.FlagBroadcast
			}
		}
		addrs := []net.Addr{}
		for _, item := range strings.Split(fields[4], ",") {
			p, err := netip.ParsePrefix(item)
			if err != nil {
				continue
			}
			addrs = append(addrs, &net.IPNet{IP: p.Addr().AsSlice(), Mask: net.CIDRMask(p.Bits(), p.Addr().BitLen())})
		}
		out = append(out, netmon.Interface{
			Interface: &net.Interface{Index: index, MTU: mtu, Name: fields[0], Flags: flags},
			AltAddrs:  addrs,
		})
	}
	return out
}
