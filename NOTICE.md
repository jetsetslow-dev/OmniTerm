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

OmniTerm credits the projects, most of them open source, whose ideas and bug reports shaped its
features. No code from them is included; see the README's Acknowledgements for what came from each.

- Semaphore UI — https://github.com/semaphoreui/semaphore
- Termix — https://github.com/Termix-SSH/Termix
- Termius (not open source; ideas only) — https://termius.com
- ssh-mcp-server — https://github.com/classfang/ssh-mcp-server
- ssh-mcp — https://github.com/tufantunc/ssh-mcp
- Komodo — https://github.com/moghtech/komodo
- Ansible — https://github.com/ansible/ansible
- ClusterShell — https://github.com/cea-hpc/clustershell
- pdsh — https://github.com/chaos/pdsh
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
- Watchtower — https://github.com/containrrr/watchtower
- Cup — https://github.com/sergi0g/cup
- LibreNMS — https://github.com/librenms/librenms
- Proxmox VE API documentation — https://pve.proxmox.com/pve-docs/api-viewer/
- Kubernetes API reference — https://kubernetes.io/docs/reference/kubernetes-api/
- Model Context Protocol specification — https://modelcontextprotocol.io

## Bundled Go libraries (VPN tunnels)

The VPN tunnel library (`tunnel/`) is built from these, each under its own licence; the full module list with versions is in `tunnel/go.mod`:

- wireguard-go (MIT) — https://git.zx2c4.com/wireguard-go
- Tailscale's `tsnet` and the libraries it is built on (BSD-3-Clause, with Tailscale's patent grant in its PATENTS file) — https://github.com/tailscale/tailscale
- gVisor network stack (Apache-2.0) — https://github.com/google/gvisor
- Go extended libraries golang.org/x/crypto, net, sys, time (BSD-3-Clause) — https://go.googlesource.com
- gomobile (BSD-3-Clause), used to build the Android library — https://pkg.go.dev/golang.org/x/mobile
- google/btree (Apache-2.0) — https://github.com/google/btree
- The other modules Tailscale needs, each listed in `tunnel/go.mod`, are under BSD-2-Clause, BSD-3-Clause, MIT, ISC or Apache-2.0; `scripts/check-licenses.py` reads every one
