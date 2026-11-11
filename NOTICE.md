# Notices

Required Notice: Copyright (c) 2026 jetsetslow and OmniTerm contributors

OmniTerm is licensed under the GNU General Public License, version 3 (GPL-3.0-only);
see [LICENSE](LICENSE).

The open-source Android flavor uses application id `com.jetsetslow.omniterm.app.oss`.
The Play Store flavor uses application id `com.jetsetslow.omniterm.app`. This keeps
a build made from this repository from replacing the Play Store package, while
keeping the app features the same. The Play Store flavor also includes Google's
proprietary SDKs (billing, ads, consent, in-app review), which are not part of
this repository.

## Acknowledgements

OmniTerm credits the open-source projects whose ideas and bug reports shaped its features. No
code from them is included; see the README's Acknowledgements for what came from each.

- Semaphore UI — https://github.com/semaphoreui/semaphore
- Termix — https://github.com/Termix-SSH/Termix
- ssh-mcp-server — https://github.com/classfang/ssh-mcp-server
- ssh-mcp — https://github.com/tufantunc/ssh-mcp
- Komodo — https://github.com/moghtech/komodo
- Haven — https://github.com/GlassHaven/Haven
- ConnectBot — https://github.com/connectbot/connectbot
- ServerBox — https://github.com/lollipopkit/flutter_server_box
- Nexterm — https://github.com/gnmyt/Nexterm
- Beszel — https://github.com/henrygd/beszel
- Uptime Kuma — https://github.com/louislam/uptime-kuma
- Home Assistant for Android — https://github.com/home-assistant/android
- Termux:Tasker — https://github.com/termux/termux-tasker
- electerm — https://github.com/electerm/electerm
- Material Files — https://github.com/zhanghai/MaterialFiles
- Model Context Protocol specification — https://modelcontextprotocol.io

## Bundled Go libraries (VPN tunnels)

The VPN tunnel library (`tunnel/`) is built from these, each under its own licence; the full module list with versions is in `tunnel/go.mod`:

- wireguard-go (MIT) — https://git.zx2c4.com/wireguard-go
- gVisor network stack (Apache-2.0) — https://github.com/google/gvisor
- Go extended libraries golang.org/x/crypto, net, sys, time (BSD-3-Clause) — https://go.googlesource.com
- gomobile (BSD-3-Clause), used to build the Android library — https://pkg.go.dev/golang.org/x/mobile
- google/btree (Apache-2.0) — https://github.com/google/btree
