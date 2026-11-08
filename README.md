# OmniTerm

OmniTerm is a native Android app for running your homelab and servers from a phone or tablet: SSH terminals, SFTP and network-share file management, Docker/Podman containers and stacks, live host monitoring, a full network-tools suite, alerts, and Wake-on-LAN — all directly from the device, with **no cloud account and no agent to install on your servers**.

## Features at a glance

- **SSH terminal** — multiple background-capable sessions, **split-screen MultiSSH** (two hosts side-by-side or stacked), persistent `tmux`-backed sessions that survive drops, a special-key bar, swipe-typing, themes, and copy tools.
- **SFTP file manager** — in-app syntax-highlighting editor, editable path bar, multi-select batch operations, search (live filter + recursive), sort, **archive create/extract** (zip/tar/tar.gz), **dual-pane transfer** between two hosts, copy-path, quick bookmarks, authenticated sudo writes, and cancellable transfers.
- **Network shares** — browse and manage files on **SMB, FTP, SFTP, and WebDAV** shares with LAN discovery and saved profiles, at full parity with the SFTP tab (multi-select, search, sort, in-app editing). **Cross-protocol copy/paste** streams multi-GB files between shares, or between a share and an SSH host, in either direction.
- **Network tools** — one tabbed screen: Host Scan, Wake-on-LAN, Ping, Traceroute, Port Scanner, **DNS Lookup**, **WHOIS**, **Speed Test**, and **SSH Tunnels** (port forwarding).
- **Docker & Podman** — containers, stacks, images, and volumes; per-container **live stats** and one-tap **exec-into-shell**; a visual **Compose Builder** with validate-before-deploy.
- **Kubernetes** — pods, deployments, services and nodes of the cluster a host's kubectl, k3s or MicroK8s reaches, or of a cluster saved from a kubeconfig: logs, shells, describe, scale, rolling restart and cordon.
- **Live monitoring** — CPU, memory, disk, load, uptime, temperature, per-core usage, network/disk I/O rates, SMART health, a detailed hardware and software spec sheet, and process/service/log/cron views.
- **Fleet Broadcast** — run a command across many hosts or groups at once with live per-host output.
- **Scripts, alerts, cron, and Wake-on-LAN** management.
- **Encrypted, selective backups** (AES-256-GCM) of your app data.
- **On-device security** — Keystore-backed credential encryption, SSH host-key pinning, FIDO2 security keys (USB or NFC) and SSH certificates, optional app lock and biometrics, and per-host SSH agent forwarding.

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
- **Remove Ads** hides the banner. It does *not* lift any limit or unlock any feature.
- **Unlock OmniTerm** removes the banner *and* lifts the host/credential limits (so you never need both). It also enables **Quick connect**, the ad-hoc SSH session to an unsaved host, and the **Telnet** and **USB serial** terminals — the free build must save a host first, so that the 1-host limit still means something.
- Purchases are tied to your Google account — use **Restore purchase** on the unlock screen after a reinstall or device switch.

*OmniTerm source is available under the PolyForm Noncommercial License 1.0.0. Personal, educational, evaluation, and other noncommercial source builds are allowed. Commercial redistribution, paid forks, third-party app-store publication, hosted/managed paid builds, and monetized derivatives require separate written permission.*

## Architecture

OmniTerm is built natively for Android in Kotlin and Jetpack Compose.

- **Connection layer** — SSH, SFTP, and port-forward tunnels use JSch (the maintained `com.github.mwiede` fork) directly from the device. Network shares go through a common `RemoteFsClient` abstraction over smbj (SMB2/3), Apache Commons Net (FTP), OkHttp (WebDAV), and JSch (SFTP), so the file browser and the streamed cross-protocol transfer engine behave identically across protocols.
- **Data storage** — SQLite via Room stores hosts, keys, credential profiles, scripts, alert rules, saved shares, tunnels, and local metric history. Schemas are versioned and migrated (current schema v24).
- **Security** — credentials, private keys, sudo passwords, and proxy passwords are encrypted with AES-GCM using a key managed by Android Keystore. Key size and hardware backing depend on the device's Keystore implementation.
- **Execution model** — Foreground services and WakeLocks keep SSH terminal sessions (`tmux`-backed when available) alive across network drops and app backgrounding. Monitoring parses standard Linux `/proc` and utility output, so **zero agents** run on your servers.

## Using OmniTerm

### First run & adding hosts
The first-run flow walks you through creating a server. Authenticate with a password, an imported SSH key, or a reusable credential profile. Open **Servers → add** and enter:
- Display name, hostname/IP, SSH port, username, and authentication method.
- Optional group, color, notes, keepalive, compression, jump host / proxy, sudo password, and **SSH agent forwarding**.

**Import from ssh_config.** Already have hosts in `~/.ssh/config`? Copy the file to your phone, open **Servers → add**, tap **Import from an ssh_config file…** and pick it. OmniTerm lists every host the file names, with its address, user, port and jump host (`ProxyJump`, or `ProxyCommand ssh -W`), and keeps agent forwarding, compression and keepalive. Tick the ones you want; hosts you already saved start unticked, and one field fills in the user where the file sets none. A host uses your saved key with the same name as its `IdentityFile` (for example `id_ed25519`); otherwise add its password or key by editing it before you connect, as its notes say. `Match` blocks, `Include` and port forwards are not imported, and the dialog says so.

**Two-step sign-in.** When a host asks for more than its password — a verification code from an authenticator app or Duo, or a new password because the old one expired — OmniTerm asks you in a **Sign in to …** dialog when you open a terminal, test the connection or browse its files. A jump host can ask too. After you sign in from a terminal, that host's monitoring, containers and other checks use the same sign-in, so you are not asked again while it stays connected. Those checks never ask on their own: until you sign in, they say the host is waiting for an answer. If the connection drops, the terminal does not keep retrying a sign-in it cannot finish; tap **Retry** and answer again. Files signs in separately, so it may ask once more.

**SSH keys.** Open **Tools → Auth & keys** to import or generate keys. **Import SSH Key** takes a private key in OpenSSH or PEM form. If the key has a passphrase, type it once in **Key passphrase**: OmniTerm opens the key there and stores it encrypted on the phone, so connecting never asks for it. A key protected with chacha20-poly1305 has to be re-protected first (`ssh-keygen -p -Z aes256-ctr -f <file>`), and the import says so.

**Certificates.** If your servers trust an SSH certificate authority, add the key's `-cert.pub` file in the **Certificate** field when you import or edit the key, or load it from a file. OmniTerm then offers the server both the key and its certificate, so it works whether the server lists the key itself or only trusts the authority. The key list shows who the certificate is for and when it expires, and warns once it has expired. A certificate made for a different key, or a host certificate, is refused.

**Security keys.** **Generate Keys** can make a key on a FIDO2 security key (a YubiKey, for example): pick **Ed25519 on a security key**, or ECDSA for keys without Ed25519, and tick **Also ask for the key's PIN** if you want a PIN at every sign-in. Plug the key into the phone or hold it to the back of the phone (NFC) and touch it when asked. The private key never leaves the security key. Add the public key to the server's `authorized_keys` as usual. The **Key file** OmniTerm shows holds no secret; copy it to a computer as `~/.ssh/id_ed25519_sk` to use the same security key there, or import such a file from a computer the same way. Each sign-in asks you to touch the key, so monitoring and other checks of that host use the sign-in from an open terminal, as with two-step sign-in.

Groups make Fleet Broadcast targeting easier; host colors help you tell servers apart across sessions and dashboards. Choose **Blue, Teal, Gold, Copper, Rose, Plum, Olive or Ocean** by name, or **Automatic** for an ID-based color that stays the same when a host is renamed. The muted hues use brighter tones on dark surfaces and deeper tones on light surfaces so host labels stay readable. The selected chip has a checkmark, and you can switch back to Automatic at any time. Every card that stands for a host (terminal sessions, broadcast output, alert rules, bookmarks, tmux sessions) uses that host's color. Connection and health indicators keep their separate status colors and icons. Previously saved color names are recognized without changing the host's connection settings. Use the host picker on operational screens to switch the active server, or **swipe left/right** to move between tabs and subtabs outside the terminal. A pull-to-refresh re-checks hosts without moving the picker off the one you are looking at.

The **Hosts** list can be sorted by name, status, health, or latency. Each card has **PING** next to SSH/SFTP/DOCKER, and the **⋮** menu adds **Ping**, **Traceroute** (both run from the phone, so they work while the host is offline), **Copy SSH command** (including its jump host or proxy), and **System specs**. **Attach existing tmux…** lists the tmux sessions already running on a Linux, macOS or BSD host (one you started from a desktop, say) and joins one, as `tmux attach` does, so every client sees the same window. Terminate in OmniTerm then ends that session on the server; Leave keeps it running. Offline hosts show when they were last seen and, when a saved Wake-on-LAN target has the same address, a **WAKE** button. Renaming a host updates its open and saved sessions; changing its address resets its health until fresh metrics arrive. Select several hosts to delete them together, optionally ending their tmux sessions too. Deleting a host also deletes everything OmniTerm keeps for it — its Files bookmarks, saved tunnels, alert rules, saved tmux sessions, recorded Compose stacks and monitoring history — and the confirmation lists what will go first. Nothing is moved to another host.

### Terminal
Open **Term** for an interactive SSH shell on the selected host.
- A host's sign-in banner (sshd's `Banner`, often a legal notice or a maintenance message) appears at the top of the terminal, as `ssh` shows it. OmniTerm removes any control characters from it first, so a banner cannot clear the screen or change the window title.
- **MultiSSH split screen** — tap **SPLIT** to view two sessions at once, side-by-side or stacked (flip with the layout button). In split mode only, check two hosts in the top picker to load them into the panes. The focused pane and current host are labelled at the top; the cyan-bordered pane owns the keyboard and special-key bar. **OPEN** and each pane's **PICK** menu can attach a background session, resume saved tmux, or start a new host without filling the terminal with a long server list. **BG** frees a pane while keeping its session connected, and **✕** offers either a resumable tmux detach or a background normal SSH session before disconnecting. **SINGLE** returns to single-session view while keeping both sessions available.
- **Quick connect** (**Unlock OmniTerm** only) — **OPEN › Quick connect** SSHes to a host that is not in your saved list, for one-off access. It offers the same options as Add Host (password, saved key, or credential profile; HTTP/SOCKS5 proxy or SSH jump host, optionally filled from a saved host) and enforces the same validation and host-key trust prompts, but writes nothing to the database. The free Play Store build does not include it — save the host instead, within the 1-host limit. **Remove Ads does not unlock it.**
- **Telnet** (**Unlock OmniTerm** only) — **OPEN › Telnet…** opens a terminal on network gear and other hosts that have no SSH, by host name or IP and port (23 by default). Tick **Save this connection** to keep it in the list at the top of that window; tap a saved one to open it, or the bin to remove it. Saved Telnet connections are kept in app backups with the hosts. Telnet is not encrypted: anything you type, passwords included, can be read on the network, so use SSH wherever the device offers it. Window size changes are sent to the host, and what you type is shown until the host takes over echoing it.
- **USB serial** (**Unlock OmniTerm** only) — **OPEN › USB serial…** opens a terminal on a USB serial adapter plugged into the phone with an OTG cable or adapter: a router or switch console cable, a single-board computer's serial console, a microcontroller board. OmniTerm works with standard USB CDC-ACM devices and with FTDI, Silicon Labs CP210x, WCH CH340/CH341 and Prolific PL2303 (not PL2303 HXN) adapters; on adapters with several ports it uses the first. Pick the adapter, its baud rate (115200 by default, or type any rate), data bits, parity and stop bits; OmniTerm remembers them for next time. Android asks once whether OmniTerm may use the adapter. Unplugging it ends the session and keeps what was on screen.
- **Persistent `tmux`-backed sessions** survive network drops and app restarts, and reconnect automatically. Remove one you no longer need from the session picker: **Forget** drops it from this device and leaves it running, **End session** stops it on the server too. On a Mac, OmniTerm finds tmux installed with Homebrew or MacPorts, and can install it with Homebrew.
- Multiple background sessions with session switching and explicit disconnect prompts. The session list and the **OPEN** menu both show when each session started and, once it is in the background, since when.
- When a shell ends on the server (you type `exit`, or tmux ends), its terminal stays open with its scrollback and says how it ended, for example "Session ended (exit 0). Scrollback kept.". Tap **Dismiss** or **✕** when you are done with it.
- Adjustable, persisted font size with reflowing scrollback on resize.
- Themes: App theme (follows app light/dark/AMOLED/high-contrast), Omni Dark, Solarized Dark, Matrix, and Light.
- Hardware and soft keyboard input, a compact special-key bar, and swipe-typing mode.
- Outside the terminal, the keyboard closes when you start something that shows output (a ping, a search, a broadcast, a deploy), so it does not cover the results.
- In landscape, the tabs and the awake, alerts and (free build) **FREE** buttons move to a rail on the left, so every screen keeps its full height. While the keyboard is open in landscape, a screen's header, host picker and tabs (and the free build's ad) step aside until you close it, so what you are typing and its button, such as Fleet's **RUN**, stay in view. The terminal hides the rail too.
- Natural touch scrolling stays inside the terminal; app-level tab swipes and pull-to-refresh are disabled on the terminal screen.
- **Find in terminal** — **⋮ OPT › Find in terminal** searches the scrollback and the screen, ignoring case, and highlights every match. The arrows step through them (the keyboard's search key goes to the next one up), and the count shows which one you are on. The matches follow new output while the bar is open; Back or **✕** closes it.
- Long-press copy tools for the visible screen or full scrollback; a **Bottom** button jumps to the live tail without covering the last terminal rows.

See the [terminal compatibility matrix](docs/TERMINAL_COMPATIBILITY.md) for the implemented xterm/VT subset, tmux control-mode status, and known protocol limitations.

### Files (SFTP · Transfers · Bookmarks · Shares)
Open **Files** to work with remote filesystems.

**SFTP** browses the selected SSH host (the host picker lives here):
- Upload, download, rename, delete, create folders, start a **new text file**, and **edit text files** in the built-in code editor (line numbers, syntax highlighting, find/replace, sudo-assisted writes).
- **New file** shows progress and stays on the host and folder where you started it. Switching hosts while it finishes never opens a file from the new host. A stale browsing connection is replaced once; a failed fresh sign-in is reported without asking for a second one-time code.
- **Multi-select** for batch copy/cut/download/delete; **sort** by name/size/date/type; **search** with a live folder filter, recursive tree search, and glob wildcards.
- **Archive** the selection to zip/tar/tar.gz, or **extract here** an archive into a same-named subfolder — all server-side.
- **Dual-pane** — toggle a second SFTP browser to view another host alongside the first, and copy/cut files across for a streamed transfer between the two.
- **Editable path bar** — tap it to type a destination and jump straight there. A long path wraps onto more lines, so all of it stays in reach.
- **Sudo mode** is gated behind device biometrics/PIN before it can be enabled.

**Bookmarks** span every SSH host and network share: star a folder in the SFTP or Shares browser and it appears here labelled with its endpoint (offline endpoints are greyed out). Only folders you star are saved. Editing a bookmark shows its whole path, however long, with the cursor at the end.

**Transfers** shows per-file rows with a running rollup; individual transfers (or all of them) can be **cancelled** mid-flight, and they keep running as you navigate the app.

### Network shares
Open the **Shares** subtab for network file shares separate from your SSH hosts.
- **Discovery & profiles** — scan a subnet (e.g. `192.168.1.0/24`, or leave blank on Wi-Fi) to find SMB, FTP, SFTP, NFS, and WebDAV services and save them as reusable profiles. Protocol filter chips cut scan noise; SMB hosts expand into their share names when anonymous enumeration is allowed. The scan shows its progress and starts from the subnet of a share you already saved. Credentials can be inline or linked to a shared profile. Saving, deleting or checking shares says what happened in a card above the list.
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
Open **Monitor** for live host metrics — CPU, memory, disk, load, uptime, process count, temperature, per-core usage, and network/disk I/O rates — plus disk mounts with SMART health, and process/service/log/scripts/cron views (including visual cron schedule management). On Linux and Windows hosts the process list also shows how fast each process is reading and writing (on Windows this counts all of a process's I/O, network included, as Task Manager's I/O columns do) and, where the host reports it, how much of the GPU it is using: AMD, Intel and NVIDIA graphics on Linux, and any graphics card on Windows 10 version 1709 or later. You can sort by either. NVIDIA's driver reports per-process use only through `nvidia-smi`; when a host runs the driver without it, the process list says so and offers to install it.

The **Specs** tab (also under **⋮ → System specs** on the Hosts list) lists the host's hardware and software in collapsible sections: system and firmware, processor, memory, storage, graphics and network. It works on Linux, FreeBSD, macOS and Windows hosts, and the copy button copies the whole sheet. A few details — each memory module's size, speed and part number, and each drive's health, temperature and wear — can only be read with administrator rights, so OmniTerm never asks for them on its own: tap **Read with sudo** to fetch them using the sudo password saved for that host. Some details also need a helper program on the host: `dmidecode` for memory modules, `smartmontools` for drive health, and `nvidia-smi` for an NVIDIA card's driver, memory, power limit and temperature. Most USB drive enclosures pass drive health through and are read that way; when an enclosure passes nothing through, the drive is still listed by name and its note says its health cannot be read over USB. Where a helper program is missing, its note has an **Install** button: OmniTerm installs it with the host's own package manager (apt, dnf, yum, pacman, apk, zypper, pkg or Homebrew), shows the output as it goes, and reads the specs again once it is in. Close the output when you are done with it. **Attach existing tmux** offers to install tmux the same way.

Monitoring uses each host's own tools. Services are listed and managed through systemd or OpenRC on Linux, rc.d or `rcctl` on the BSDs, launchd on macOS (the jobs your SSH user can manage), and Windows services on Windows. **Reboot** runs `sudo reboot` on Linux, `sudo shutdown -r now` on BSD and macOS, and `shutdown /r` on Windows, and ending a process uses `kill` or, on Windows, `taskkill`. Windows hosts have no cron, tmux or sudo, so the Cron tab, persistent terminal sessions, sudo mode, container management, and Files' search, archives, folder sizes and same-host paste need a Linux, macOS or BSD host; on Windows they say so instead of failing. Your login shell doesn't matter: OmniTerm's own checks and actions work the same whether the host account uses bash, zsh, fish, csh or tcsh, and on Windows whether OpenSSH starts `cmd` or PowerShell. Commands you type or broadcast yourself still run in your own shell, and the built-in Fleet presets run the right version for each host. Windows output keeps accented and non-Latin text (service names, paths, event messages) instead of garbling it.

### Docker, Podman & stacks
Open **Containers** to manage containers, compose stacks, images, and volumes (Docker and Podman are detected automatically). The host picker lists online hosts; the host you are on stays selected if it goes offline, and so does any host holding unsaved Compose Builder changes, marked offline.
- **Containers & stacks** — summary health; expand for ports, streaming **logs**, per-container **stats** (CPU/memory/network/block I/O), one-tap **exec-into-shell** (bash where the container has it, sh otherwise), start/stop/restart/pause, and full stack lifecycle actions.
- **Podman stacks** — stacks run by podman-compose get the same actions as Docker Compose stacks. **Update** recreates every service so newly pulled images take effect, and **Scale** needs podman-compose 1.4 or later.
- **Compose Builder** — a visual editor for `docker-compose.yml`; deploy new stacks or surgically edit existing ones, with `compose config` validation before every fail-safe deploy. Each host keeps its own unsaved changes while you switch hosts, even while it is offline; Deploy waits until the host is back. Changes are kept until you close the app.
  - Environment variables and dependencies show as rows whichever way the file writes them (`KEY: value` or `KEY=value`, with or without start conditions). Saving keeps the file's own style, indentation and comments.
  - Renaming a service also updates everything that points at it: `depends_on`, `links`, `volumes_from`, `extends` and shared network, IPC or process namespaces.
  - Before you deploy, the builder flags what Compose would refuse. That covers dependencies on services that are missing or commented out, dependency loops, and volumes or networks that are never declared. It also covers a container name shared by several services or replicas, and a stack with every service commented out.

### Kubernetes
Open **Containers → Kubernetes** on a host with kubectl, k3s or MicroK8s to manage the cluster it reaches, as the SSH user, or pick a saved cluster in the **Cluster** menu. Pick a **context** and a **namespace**, or all namespaces; each host and saved cluster keeps its own picks until you close the app. **Events** shows recent events, newest last.
- **Pods** — the status kubectl shows, coloured green when running, amber while starting or stopping, red when failing and grey when completed; ready containers, restarts, node and age. **Logs**, **Follow**, **Previous** (the logs from before the last restart), **Shell** (asks which container when there are several), **Describe** and **Delete**. A deployment replaces a deleted pod with a fresh one.
- **Deployments** — ready, up-to-date and available replicas and their images; **Logs**, **Scale**, **Restart** (replaces the pods a few at a time) and **Describe**.
- **Services** — type, cluster IP, ports and external addresses; **Describe**.
- **Nodes** — ready state, roles, version, address, OS, CPU and memory; **Describe**, **Cordon** (no new pods are placed on it) and **Uncordon**.
- **k3s** lets only root read its cluster config. When that is what stops the tab, it shows the one command that copies the config for your user and can open a terminal that runs it; sudo asks for your password there.
- **Saved clusters** — **Cluster → Import kubeconfig…** reads a kubeconfig file, such as one written by `kubectl config view --raw --flatten`, and saves the contexts you pick. The phone then talks to that cluster's API itself, with no SSH host in between, so each address must be one the phone can reach; edit it when the file says 127.0.0.1. Client certificates and tokens work. A context that gets its credentials from a program (aws, gcloud) or skips checking the cluster's certificate cannot be used, and the import says why. Keys and tokens are stored encrypted, and backups that include hosts include saved clusters. On a saved cluster, **Describe** shows the object as the API holds it, followed by its events. **Remove** in the same menu forgets a cluster.

### Fleet Broadcast
Open **Fleet → Broadcast** to run a command across selected online hosts or host groups, with live per-host streaming output and built-in/saved fleet scripts. **Run** needs a command and at least one online host. A host you picked stays picked if it goes offline: runs skip it, and the confirmation names it, until it is back. Each host's output follows the newest lines; scroll up to read and it stays where you are until you scroll back to the end. When a command does not succeed, its card says why: the exit status, or that the connection was lost before it finished (the command may still be running on the host). Output cards start collapsed, so a run on many hosts shows every host's status at once; tap a host to read its output. They collapse again when you come back to Broadcast from another tab.
- The command box takes several lines: Enter starts a new line, and each line runs as written.
- A saved script picked from **Presets** runs only on hosts with the OS or system it is for: the confirmation names the hosts it leaves out, and a script none of the picked hosts can run says so instead of running. Hosts OmniTerm has not checked yet are tried.
- Destructive commands get a warning before they run, including disk and partition wipes, ZFS and LVM deletes, container and volume prunes, Kubernetes deletes and drains, Proxmox destroy and hard stop, deleting every cron job, Windows recursive deletes and formats, and commands that would stop SSH or lock it out with a firewall.
- **Run in tmux** runs each host's command in its own tmux session, so it keeps running if the connection drops. OmniTerm reconnects every 15 seconds for up to 30 minutes (or tap **Reconnect now**) and finishes with the command's full output. **Attach** opens the running command in the terminal. Each tmux session closes, and its log is removed, when its command ends or you tap **Stop**. A host without tmux waits for you to choose **Install tmux** or **Run without tmux**.
- **Rolling run** runs on 1, 2, 5 or 10 hosts at a time instead of all at once, in the order the confirmation lists them. With **Stop if a host fails** on, a batch where any host fails, or does not finish, leaves the remaining hosts **not run**, so a bad update stops at the first few hosts. **Stop** during a rolling run also leaves the waiting hosts not run. Each batch gets the full 10-minute limit.
- When a run ends, **Retry** runs the same command, with the same values, again on just the hosts that failed or were not run, after you confirm; the other hosts keep their results.
- **Share output** sends the whole run (the command, then each host's status and output) to any app you pick, as a text file plus the message text when it is short enough.

### Scripts, alerts & Wake-on-LAN
- **Tools → Scripts** — create, edit, and organize saved scripts; mark each for quick per-host execution, fleet broadcast, or both, and pick the OS or system it is for (Linux, FreeBSD, macOS, Windows; Proxmox, CasaOS, Home Assistant, Raspberry Pi, Docker, Podman, Kubernetes, Synology, TrueNAS, Unraid, OpenWrt, pfSense, OPNsense).
- **Values asked when a script runs** — write `{{name}}` in a script, such as `qm start {{vmid}}`, and OmniTerm asks for that value each time it runs, from Monitor's Scripts tab or Fleet. `{{name=default}}` fills in a starting value. Each value reaches the host as one word, quoted for that host's shell, so a value can never run as a command of its own; don't put quotes around the placeholder yourself. On Windows hosts a value cannot contain `"`, `%`, `!`, `$`, backticks or line breaks, because cmd or PowerShell would expand them. The Proxmox presets **PVE: start VM** and **PVE: shut down VM** now ask which VM (they used to act on VM 100), and shutdown is a clean ACPI shutdown. Copies of the old presets you never edited are updated.
- **Updates available** checks with whichever package manager the host has: apt, dnf, yum, zypper, pacman, apk or FreeBSD's pkg. **Syslog errors** reads the journal, OpenWrt's logread, or the classic log files, whichever the host keeps.
- **Tools → Alerts & rules** — CPU/memory/disk/latency threshold rules evaluated during in-app metrics refresh, with an Alerts Center for active and historical incidents. Alert history retention is capped per host.
- **TLS expiry and URL checks** — two more rule types the phone checks itself, so they keep working when a host is down or has no SSH. **TLS Expiry** reads a server's certificate and alerts when it has that many days or fewer left (14 by default); leave its address blank to check each picked host's own address on port 443, or type a host, `host:port` or URL. A certificate the phone does not trust (self-signed, say) is still read; only its expiry matters. **URL Check** fetches an address about once a minute and alerts when it does not answer, returns an HTTP error, or takes longer than your threshold. The rule list shows what each check last saw. Checks run from the phone while OmniTerm is running, like the other alerts, so the address must be reachable from where the phone is.
- **Ping, TCP port and DNS checks** — three more checks the phone runs itself, about once a minute, each giving up after 3 seconds. **Ping** sends one ping to the host's own address, or to a host or address you type, and alerts when there is no reply or the reply takes longer than your threshold (200 ms by default). **TCP Port** connects to a port and alerts when nothing accepts the connection or it is slow (1000 ms): type just a port, such as `5432`, to check each picked host's own address, or `host:port` for one address. **DNS** asks a DNS server for a name's address and alerts when nothing answers, the answer is an error such as NXDOMAIN, there is no address for the name, or the reply is slow (500 ms): type just a name to ask each picked host, for hosts that are DNS servers such as Pi-hole or AdGuard Home, or `name@server` (optionally with `:port`) to ask another one. Like TLS and URL checks, they need the address to be reachable from where the phone is, and record nothing while the phone has no network.
- **Host checks** — rule types about a host's state rather than a usage figure. **Host Offline**: the host has not answered over SSH for the chosen time (2 minutes by default); nothing is recorded while the phone itself has no network. **Failed Services**: failed systemd units. **Container Problems**: Docker or Podman containers that are unhealthy, restarting, or exited with an error (containers you stopped do not count). **Storage Health**: ZFS pools that are not ONLINE, degraded or inactive mdadm arrays, and drives whose SMART health is failing. **ZFS Scrub Age**: days since the last finished scrub of the least recently scrubbed pool (35 by default). **UPS On Battery**: a UPS that Network UPS Tools (`upsc`) can read is on battery or low battery. **Reboot Required**: installed updates need a reboot, on Debian, Ubuntu and Proxmox, the Red Hat family, Arch and FreeBSD. Yes-or-no checks ask for no threshold, and an old scrub or a pending reboot alerts at once. Notifications name what is wrong, up to five items. The rule list shows each host's last reading, or **Not available on this host** where the host cannot tell (no systemd, no ZFS, a Windows host). The checks run as one extra command over SSH, at most once a minute, and only for hosts that have such a rule.
- **Alert forwarding** — off unless you set it up. On the Alerts screen, tap **Set up** next to **Alert forwarding** to send each alert to a phone or desktop of your choice as well: an [ntfy](https://ntfy.sh) topic (on ntfy.sh or your own server, with an optional access token), a [Gotify](https://gotify.net) server (with its application token), or any webhook URL, which receives the alert as JSON (an optional bearer token is sent with it). **Send test** delivers a test alert before you save. Each alert's title and text go out, the same words as the notification, and optionally a second message when it resolves; a muted alert stays quiet everywhere. A delivery that gets no answer or a server error is tried twice more. The screen shows when the last alert went out, or why it did not. Like the notifications, alerts are forwarded only while OmniTerm is running. Anyone who knows a topic on a public ntfy server can read it, so pick a hard-to-guess name; without HTTPS, the alert and the token travel in clear text, and the form says so.
- **Tools → Network tools → Wake-on-LAN** — save wake targets and send magic packets; scan the LAN from the editor to pick discovered devices.

## Settings & customization
Open **Tools → Settings**:
- App lock and biometric unlock.
- App theme (System / Dark / AMOLED / Light), high-contrast mode, and text scale.
- Metrics refresh interval and retention window.
- Terminal font size, theme, and scrollback limit.
- Background session keepalive.
- Alert history entries per host (10–100) and SFTP transfer warnings.

**Tools → About OmniTerm → Device & diagnostics** shows app version, build, device info, and an on-device crash-history viewer for bug reports.

## Backup & restore
Open **Tools → App backup** to export or restore a selective backup of OmniTerm's app data (hosts, SSH keys, credential profiles, scripts, alert data, saved shares, tunnels, and settings).
- Backups containing sensitive sections are compressed and encrypted with AES-256-GCM using a passphrase-derived key.
- App backups never copy files from your remote hosts.
- OmniTerm does not store the backup passphrase — keep it safe.

## Security & privacy
- **No OmniTerm backend, no server agents** — administration traffic goes directly from your device to the hosts you configure. The Play Store flavor separately contacts Google for ads, consent, and billing; the source-available flavor omits those SDKs. If you turn on alert forwarding, alerts also go to the ntfy, Gotify or webhook address you enter, and nowhere else.
- **On-device encryption** — credentials, private keys, sudo passwords, and proxy passwords use AES-GCM with an Android Keystore-managed key (hardware-backed where the device supports it).
- **SSH host-key pinning** — the host key is pinned on first connect; a changed key later (possible MITM) is actively rejected until you review it. If you reject a host's key, OmniTerm stops asking about it from background checks; it asks again when you connect to that host, tap **Retry** on it, or test its connection.
- **SSH agent forwarding** — optional per host, so onward hops can authenticate with your key without copying it to the server. Off by default; enable only for hosts you trust. When a program on that host asks to use a security key through it, OmniTerm says so, and the user it is signing in as; cancel unless you started it. Such a request waits 20 seconds for the touch, including when the security key uses an SSH certificate.
- **Biometric app lock** — lock the whole app behind biometrics or a PIN. Cold starts always lock;
  warm returns can lock immediately, after 30 seconds, 1 minute, 5 minutes, or a custom duration
  up to 24 hours. Rotation does not start the background timer.
- **Authenticated sudo** — everything that runs with sudo asks first, every time: Read with sudo, installing a helper program or tmux, reboot, service control, and turning on sudo mode in Files. With App Lock on, OmniTerm asks for your App Lock fingerprint or PIN; otherwise your phone's own screen lock (on Android 11 and later, a fingerprint or a face unlock Android rates as secure also works); and on a phone without a screen lock, it asks you to confirm.
- **Encrypted backups** — sensitive backup sections are AES-256-GCM encrypted with a passphrase the app never stores.
- **Ads data (Play Store only)** — the free tier shows one AdMob banner, which may access your advertising ID. The source-available build has no ads SDK and accesses no advertising ID.

## Troubleshooting
- **Host offline** — check hostname/IP, SSH port, network route, and firewalls.
- **Auth fails** — verify username, password/key, and proxy/jump-host config.
- **"Connection dropped during handshake"** — the server closed the connection before sign-in. It may still be starting, or (OpenSSH 9.8 and later) it is turning your device away for a while after several failed sign-ins. Wait a minute and try again.
- **"This host signs in with a security key"** — open a terminal to it and touch your security key; its checks then use that sign-in.
- **"This host asks a sign-in question"** — the host uses two-step sign-in. Open a terminal to it and enter the current code from your authenticator app; its checks then work while that sign-in stays connected.
- **Empty monitoring** — confirm the host has the expected platform tools (Linux gives the richest metrics). Windows hosts need OpenSSH Server and Windows PowerShell, which OmniTerm runs its Windows checks with.
- **Infra issues** — confirm Docker/Podman is installed and the SSH user may run it.
- **Kubernetes tab fails** — run `kubectl get pods` as the SSH user on the host. The tab sees what that command sees.
- **Tunnel won't start** — confirm the bind port is free and the destination is reachable *from the SSH host* (for `-L`) or *from this device* (for `-R`).

**Support:** open a GitHub issue with diagnostic logs from **Tools → About OmniTerm → Device & diagnostics**, or reach the community on GitHub.

## Acknowledgements
OmniTerm learns from other open-source projects. No code is copied from them; these are the ideas and
bug reports that shaped features here:
- [Semaphore UI](https://github.com/semaphoreui/semaphore) — values a script asks for when it runs (its survey variables).
- [Termix](https://github.com/Termix-SSH/Termix) and [ssh-mcp-server](https://github.com/classfang/ssh-mcp-server) — garbled non-English output from Windows hosts.
- [ssh-mcp](https://github.com/tufantunc/ssh-mcp) — how multi-line scripts are entered and sent to a host.
- [Komodo](https://github.com/moghtech/komodo) — rolling Fleet runs, a few hosts at a time (its batch deploys).
- [Beszel](https://github.com/henrygd/beszel) and [Uptime Kuma](https://github.com/louislam/uptime-kuma) — the host-down, failed-service and container alert kinds; Uptime Kuma also the ping, TCP port and DNS checks. Both also gave the idea of forwarding alerts to ntfy, Gotify and webhooks (their notification settings).
- [Haven](https://github.com/GlassHaven/Haven), [ConnectBot](https://github.com/connectbot/connectbot), [ServerBox](https://github.com/lollipopkit/flutter_server_box), [Nexterm](https://github.com/gnmyt/Nexterm), [Beszel](https://github.com/henrygd/beszel), [Uptime Kuma](https://github.com/louislam/uptime-kuma) and [Home Assistant for Android](https://github.com/home-assistant/android) — feature and bug reviews for the homelab and server-admin features OmniTerm covers.

## Support the project
- Buy **Unlock OmniTerm** in the Play Store build.
- Star the repository on GitHub.
- Tell other developers and homelab enthusiasts.

## Build from source
Build the source-available variant and run its unit tests:
```bash
./gradlew assembleOpenSourceDebug testOpenSourceDebugUnitTest --no-daemon
```

Before pushing a code change, run the repository preflight:

```bash
./scripts/local-pr-check.sh --full
```

It runs the release/CI contract tests, both flavor unit suites and lint gates, and both release
SBOM dependency graphs. It checks those graphs and the pinned GitHub Actions against GitHub's
advisory database, and runs the same CodeQL analysis as CI (the script says how to install the
CodeQL CLI). If an Android device or emulator is connected, it also runs the Room
migration matrix. Robolectric's Android 15 native runtime is unavailable on Linux ARM64, so those
specific classes are deferred to the required x86_64 PR check there; platform-neutral logic remains
covered locally by ordinary JVM tests.

An emulator is sufficient for the migration matrix — no physical device is needed. Required CI runs
it on API 29 (an older SQLite platform, and cheap on runners without KVM). On a KVM-capable x86_64
machine it is worth also running it against an **API 35** AVD, which covers the modern end of the
supported range. API 35 is currently the newest level that boots: emulator 37.1.11 crash-loops on
any API 36+ image, so Android 16/17 can be compiled and targeted but not yet emulated.

Contributors should also read [CONTRIBUTING.md](CONTRIBUTING.md) and the
[AI-first development policy](AI_FIRST_DEVELOPMENT.md); maintainers should use
the [release runbook](docs/RELEASE_RUNBOOK.md) and
[repository security checklist](docs/REPOSITORY_SECURITY.md).
