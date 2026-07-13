# OmniTerm

OmniTerm is a native Android app for running your homelab and servers from a phone or tablet: SSH terminals, SFTP and network-share file management, Docker/Podman containers and stacks, live host monitoring, a full network-tools suite, alerts, and Wake-on-LAN — all directly from the device, with **no cloud account and no agent to install on your servers**.

## Features at a glance

- **SSH terminal** — multiple background-capable sessions, **split-screen MultiSSH** (two hosts side-by-side or stacked), persistent `tmux`-backed sessions that survive drops, a special-key bar, swipe-typing, themes, and copy tools.
- **SFTP file manager** — in-app syntax-highlighting editor, editable path bar, multi-select batch operations, search (live filter + recursive), sort, **archive create/extract** (zip/tar/tar.gz), **dual-pane transfer** between two hosts, copy-path, quick bookmarks, authenticated sudo writes, and cancellable transfers.
- **Network shares** — browse and manage files on **SMB, FTP, SFTP, and WebDAV** shares with LAN discovery and saved profiles, at full parity with the SFTP tab (multi-select, search, sort, in-app editing). **Cross-protocol copy/paste** streams multi-GB files between shares, or between a share and an SSH host, in either direction.
- **Network tools** — one tabbed screen: Host Scan, Wake-on-LAN, Ping, Traceroute, Port Scanner, **DNS Lookup**, **WHOIS**, **Speed Test**, and **SSH Tunnels** (port forwarding).
- **Docker & Podman** — containers, stacks, images, and volumes; per-container **live stats** and one-tap **exec-into-shell**; a visual **Compose Builder** with validate-before-deploy.
- **Live monitoring** — CPU, memory, disk, load, uptime, temperature, per-core usage, network/disk I/O rates, SMART health, and process/service/log/cron views.
- **Fleet Broadcast** — run a command across many hosts or groups at once with live per-host output.
- **Scripts, alerts, cron, and Wake-on-LAN** management.
- **Encrypted, selective backups** (AES-256-GCM) of your app data.
- **On-device security** — Keystore-backed credential encryption, SSH host-key pinning, optional app lock and biometrics, and per-host SSH agent forwarding.

## App flavors & installation

OmniTerm ships in two builds with the exact same core features. They differ only in distribution and monetization:

| | Source-available build | Play Store build (free) | Remove Ads | Unlock |
|---|---|---|---|---|
| Saved hosts | Unlimited | 1 | 1 | Unlimited |
| Saved credentials | Unlimited | 1 | 1 | Unlimited |
| Ads | None | Single bottom banner | None | None |
| All other features | Yes | Yes | Yes | Yes |

### Source-available build
Install the APK from the OmniTerm GitHub release page. It has **no host limits, no ads, and no in-app purchases** — no Play Billing code and no ad SDK. It uses the application ID `com.jetsetslow.omniterm.app.oss` so it can co-exist with the Play Store package (`com.jetsetslow.omniterm.app`).

1. Download the latest APK from the GitHub release page.
2. Allow installing apps from your download source in Android settings.
3. Open the APK and install OmniTerm.

### Play Store build
Free with a 1-host limit and a single bottom banner. Both purchases are **one-time** (not subscriptions):
- **Remove Ads** hides the banner.
- **Unlock OmniTerm** removes the banner *and* lifts the host/credential limits (so you never need both).
- Purchases are tied to your Google account — use **Restore purchase** on the unlock screen after a reinstall or device switch.

*OmniTerm source is available under the PolyForm Noncommercial License 1.0.0. Personal, educational, evaluation, and other noncommercial source builds are allowed. Commercial redistribution, paid forks, third-party app-store publication, hosted/managed paid builds, and monetized derivatives require separate written permission.*

## Architecture

OmniTerm is built natively for Android in Kotlin and Jetpack Compose.

- **Connection layer** — SSH, SFTP, and port-forward tunnels use JSch (the maintained `com.github.mwiede` fork) directly from the device. Network shares go through a common `RemoteFsClient` abstraction over smbj (SMB2/3), Apache Commons Net (FTP), OkHttp (WebDAV), and JSch (SFTP), so the file browser and the streamed cross-protocol transfer engine behave identically across protocols.
- **Data storage** — SQLite via Room stores hosts, keys, credential profiles, scripts, alert rules, saved shares, tunnels, and local metric history. Schemas are versioned and migrated (current schema v18).
- **Security** — credentials, private keys, sudo passwords, and proxy passwords are encrypted with AES-GCM using a key managed by Android Keystore. Key size and hardware backing depend on the device's Keystore implementation.
- **Execution model** — Foreground services and WakeLocks keep SSH terminal sessions (`tmux`-backed when available) alive across network drops and app backgrounding. Monitoring parses standard Linux `/proc` and utility output, so **zero agents** run on your servers.

## Using OmniTerm

### First run & adding hosts
The first-run flow walks you through creating a server. Authenticate with a password, an imported SSH key, or a reusable credential profile. Open **Servers → add** and enter:
- Display name, hostname/IP, SSH port, username, and authentication method.
- Optional group, color, notes, keepalive, compression, jump host / proxy, sudo password, and **SSH agent forwarding**.

Groups make Fleet Broadcast targeting easier; host colors help you tell servers apart across sessions and dashboards. Use the host picker on operational screens to switch the active server, or **swipe left/right** to move between tabs and subtabs outside the terminal.

### Terminal
Open **Term** for an interactive SSH shell on the selected host.
- **MultiSSH split screen** — tap **SPLIT** to view two sessions at once, side-by-side or stacked (flip with the layout button). The focused pane (cyan border) owns the keyboard and the special-key bar; tap the other pane to move focus. Each pane resizes its own remote PTY and scrolls independently. Tapping a pane's **✕** disconnects just that host and leaves the pane empty (the split stays open); tapping **SINGLE** returns to single-session view while keeping both sessions alive in the background.
- **Persistent `tmux`-backed sessions** survive network drops and app restarts, and reconnect automatically.
- Multiple background sessions with session switching and explicit disconnect prompts.
- Adjustable, persisted font size with reflowing scrollback on resize.
- Themes: App theme (follows app light/dark/AMOLED/high-contrast), Omni Dark, Solarized Dark, Matrix, and Light.
- Hardware and soft keyboard input, a compact special-key bar, and swipe-typing mode.
- Natural touch scrolling stays inside the terminal; app-level tab swipes and pull-to-refresh are disabled on the terminal screen.
- Long-press copy tools for the visible screen or full scrollback; a **Bottom** button jumps to the live tail without covering the last terminal rows.

See the [terminal compatibility matrix](docs/TERMINAL_COMPATIBILITY.md) for the implemented xterm/VT subset, tmux control-mode status, and known protocol limitations.

### Files (SFTP · Transfers · Bookmarks · Shares)
Open **Files** to work with remote filesystems.

**SFTP** browses the selected SSH host (the host picker lives here):
- Upload, download, rename, delete, create folders, and **edit text files** in the built-in code editor (line numbers, syntax highlighting, find/replace, sudo-assisted writes).
- **Multi-select** for batch copy/cut/download/delete; **sort** by name/size/date/type; **search** with a live folder filter, recursive tree search, and glob wildcards.
- **Archive** the selection to zip/tar/tar.gz, or **extract here** an archive into a same-named subfolder — all server-side.
- **Dual-pane** — toggle a second SFTP browser to view another host alongside the first, and copy/cut files across for a streamed transfer between the two.
- **Editable path bar** — tap it to type a destination and jump straight there.
- **Sudo mode** is gated behind device biometrics/PIN before it can be enabled.

**Bookmarks** span every SSH host and network share: star a folder in the SFTP or Shares browser and it appears here labelled with its endpoint (offline endpoints are greyed out).

**Transfers** shows per-file rows with a running rollup; individual transfers (or all of them) can be **cancelled** mid-flight, and they keep running as you navigate the app.

### Network shares
Open the **Shares** subtab for network file shares separate from your SSH hosts.
- **Discovery & profiles** — scan a subnet (e.g. `192.168.1.0/24`, or leave blank on Wi-Fi) to find SMB, FTP, SFTP, NFS, and WebDAV services and save them as reusable profiles. Protocol filter chips cut scan noise; SMB hosts expand into their share names when anonymous enumeration is allowed. Credentials can be inline or linked to a shared profile.
- **Browsing at SFTP parity** — for SMB/FTP/SFTP/WebDAV shares: navigate, create/rename/delete, upload/download, plus **multi-select batch operations, search (filter + recursive), sort, and in-app text editing**. WebDAV shares carry an explicit **Use HTTPS** toggle. (NFS and custom profiles are save-only for now.)
- **Cross-protocol copy/paste** — copy or cut in a share and paste into another folder, another share, or the SFTP host (and vice versa). Same-host SFTP pastes run server-side (`cp`/`mv`); everything else streams through the device without buffering the whole file, so multi-GB transfers work. Whole **folders** copy recursively when you tick **Include folders**.
- **Progress** — every surface shows a Windows-style rollup (files, bytes of total, combined speed, ETA) plus per-file cancel in the Transfers tab.

### Network tools
Open **Network** for a tabbed suite of diagnostics:
- **Host Scan** — sweep the LAN and identify devices; the shared scan cache feeds every host picker.
- **Wake-on-LAN** — save targets, send magic packets, and ping their live status.
- **Ping** and **Traceroute** — against any host, with LAN host pickers.
- **Port Scanner** — concurrent TCP sweep with banner grabbing and HTTP service probes.
- **DNS Lookup** — native A/AAAA/MX/CNAME/TXT/NS queries against a public resolver.
- **WHOIS** — native port-43 lookups that follow registry/registrar referrals.
- **Speed Test** — HTTP download-throughput test with a live Mbps gauge, bytes counter, and time-to-first-byte.
- **Tunnels** — user-defined SSH port forwards: **local (-L)**, **remote (-R)**, and **dynamic SOCKS (-D)**, each running over a saved host. Start/stop per tunnel; they stay up until you stop them or leave the app.

### Monitoring
Open **Monitor** for live host metrics — CPU, memory, disk, load, uptime, process count, temperature, per-core usage, and network/disk I/O rates — plus disk mounts with SMART health, and process/service/log/scripts/cron views (including visual cron schedule management).

### Docker, Podman & stacks
Open **Infra** to manage containers, compose stacks, images, and volumes (Docker and Podman are detected automatically).
- **Containers & stacks** — summary health; expand for ports, streaming **logs**, per-container **stats** (CPU/memory/network/block I/O), one-tap **exec-into-shell**, start/stop/restart/pause, and full stack lifecycle actions.
- **Compose Builder** — a visual editor for `docker-compose.yml`; deploy new stacks or surgically edit existing ones, with `compose config` validation before every fail-safe deploy.

### Fleet Broadcast
Open **Fleet → Broadcast** to run a command across selected online hosts or host groups, with live per-host streaming output and built-in/saved fleet scripts.

### Scripts, alerts & Wake-on-LAN
- **Tools → Scripts** — create, edit, and organize saved scripts; mark each for quick per-host execution, fleet broadcast, or both.
- **Tools → Alerts & Rules** — CPU/memory/disk/latency threshold rules evaluated during in-app metrics refresh, with an Alerts Center for active and historical incidents. Alert history retention is capped per host.
- **Tools → Wake on LAN** — save wake targets and send magic packets; scan the LAN from the editor to pick discovered devices.

## Settings & customization
Open **Tools → Settings**:
- App lock and biometric unlock.
- App theme (System / Dark / AMOLED / Light), high-contrast mode, and text scale.
- Metrics refresh interval and retention window.
- Terminal font size, theme, and scrollback limit.
- Background session keepalive.
- Alert history entries per host (10–100) and SFTP transfer warnings.

**About → Device & diagnostics** shows app version, build, device info, and an on-device crash-history viewer for bug reports.

## Backup & restore
Open **Tools → Backups Hub** to export or restore a selective backup of OmniTerm's app data (hosts, SSH keys, credential profiles, scripts, alert data, saved shares, tunnels, and settings).
- Backups containing sensitive sections are compressed and encrypted with AES-256-GCM using a passphrase-derived key.
- App backups never copy files from your remote hosts.
- OmniTerm does not store the backup passphrase — keep it safe.

## Security & privacy
- **No OmniTerm backend, no server agents** — administration traffic goes directly from your device to the hosts you configure. The Play Store flavor separately contacts Google for ads, consent, and billing; the source-available flavor omits those SDKs.
- **On-device encryption** — credentials, private keys, sudo passwords, and proxy passwords use AES-GCM with an Android Keystore-managed key (hardware-backed where the device supports it).
- **SSH host-key pinning** — the host key is pinned on first connect; a changed key later (possible MITM) is actively rejected until you review it.
- **SSH agent forwarding** — optional per host, so onward hops can authenticate with your key without copying it to the server. Off by default; enable only for hosts you trust.
- **Biometric app lock** — lock the whole app behind biometrics or a PIN.
- **Authenticated sudo** — enabling sudo-assisted SFTP writes requires device authentication first.
- **Encrypted backups** — sensitive backup sections are AES-256-GCM encrypted with a passphrase the app never stores.
- **Ads data (Play Store only)** — the free tier shows one AdMob banner, which may access your advertising ID. The source-available build has no ads SDK and accesses no advertising ID.

## Troubleshooting
- **Host offline** — check hostname/IP, SSH port, network route, and firewalls.
- **Auth fails** — verify username, password/key, and proxy/jump-host config.
- **Empty monitoring** — confirm the host has the expected platform tools (Linux gives the richest metrics).
- **Infra issues** — confirm Docker/Podman is installed and the SSH user may run it.
- **Tunnel won't start** — confirm the bind port is free and the destination is reachable *from the SSH host* (for `-L`) or *from this device* (for `-R`).

**Support:** open a GitHub issue with diagnostic logs from **About → Device & diagnostics**, or reach the community on GitHub.

## Support the project
- Buy **Unlock OmniTerm** in the Play Store build.
- Star the repository on GitHub.
- Tell other developers and homelab enthusiasts.

## Build from source
The project defaults to conservative Gradle settings (usable on a Raspberry Pi 5):
```bash
./gradlew rpiCheck --no-daemon
```
On a larger workstation, full verification:
```bash
./gradlew assembleDebug test -Dorg.gradle.jvmargs=-Xmx4g --max-workers=4
```

Contributors should also read [CONTRIBUTING.md](CONTRIBUTING.md) and the
[AI-first development policy](AI_FIRST_DEVELOPMENT.md); maintainers should use
the [release runbook](docs/RELEASE_RUNBOOK.md) and
[repository security checklist](docs/REPOSITORY_SECURITY.md).
