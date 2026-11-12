package omnitunnel

import "tailscale.com/net/netmon"

func setDefaultInterface(name string) { netmon.UpdateLastKnownDefaultRouteInterface(name) }
