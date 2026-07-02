# OmniTerm

OmniTerm is a native Android app for managing SSH hosts, homelab servers, Docker/Podman containers and stacks, files, metrics, alerts, and Wake-on-LAN targets from one phone or tablet — no cloud account, no agent to install on your servers.

## Features At A Glance

- **SSH terminal** with multiple background-capable sessions, session switching, a special-key bar, themes, and copy tools.
- **SFTP file manager** with an in-app text editor, an editable path bar, copy-path and quick-bookmark actions, authenticated sudo writes, cross-endpoint bookmarks (hosts and shares), cancellable transfers, and large-transfer warnings.
- **Network shares**: browse, transfer, and manage files on **SMB, FTP, SFTP, and WebDAV** shares, with LAN discovery, saved profiles, and credential reuse — plus **cross-protocol copy/paste** to move files between shares, or between a share and an SSH host, in either direction. Transfers stream directly and handle multi-GB files.
- **Live monitoring**: CPU, memory, disk, load, uptime, temperature, per-core usage, network/disk I/O rates, SMART health, and process/service/log views.
- **Docker & Podman**: containers, stacks, images, and volumes, plus a visual **Compose Builder** with safe validate-before-deploy.
- **Fleet Broadcast**: run a command across many hosts or groups at once with live per-host output.
- **Scripts, alerts, cron, and Wake-on-LAN** management.
- **Encrypted, selective backups** (AES-256-GCM) of your app data.
- **On-device security**: Keystore-backed credential encryption, SSH host-key pinning, optional app lock and biometrics.

## App Flavors & Installation

OmniTerm comes in two builds with the exact same core features. They differ only in distribution and monetization:

| | Open-source build | Play Store build (free) | Remove Ads | Unlock |
|---|---|---|---|---|
| Saved hosts | Unlimited | 1 | 1 | Unlimited |
| Saved credentials | Unlimited | 1 | 1 | Unlimited |
| Ads | None | Single bottom banner | None | None |
| All other features | Yes | Yes | Yes | Yes |

### Open-source build
Install the APK from the OmniTerm GitHub release page. It has **no host limits, no ads, and no in-app purchases**. It contains no Play Billing code and no ad SDK, and uses the application ID `com.jetsetslow.omniterm.oss` so it cannot replace the Play Store package.

To install:
1. Download the latest APK from the OmniTerm GitHub release page.
2. On Android, allow installing apps from the source you used to download the APK.
3. Open the APK and install OmniTerm.

### Play Store build
Install from Google Play when available. Free with a 1-host limit and a single bottom banner.
- Both Play Store purchases are **one-time** (not subscriptions). 
- **Remove Ads** hides the banner. 
- **Unlock OmniTerm** removes the banner *and* lifts the host/credential limits. Buying Unlock also removes ads, so you never need both.
- The single ad is a non-intrusive bottom banner shown only in the free Play Store tier.
- Purchases are tied to your Google account. Reinstalling or switching devices? Use **Restore purchase** on the unlock screen to re-apply your entitlement.

*OmniTerm source is available under the PolyForm Noncommercial License 1.0.0. Personal, educational, evaluation, and other noncommercial source builds are allowed. Commercial redistribution, paid forks, app-store publication by third parties, hosted/managed paid builds, and monetized derivatives require separate written permission.*

## Architecture

OmniTerm is built natively for Android using Kotlin and Jetpack Compose.
- **Connection Layer:** SSH and SFTP connections are managed using JSch (Java Secure Channel) directly from the device. Network shares use a common `RemoteFsClient` abstraction over smbj (SMB2/3), Apache Commons Net (FTP), OkHttp (WebDAV), and JSch (SFTP), so the file browser and cross-protocol transfer engine behave identically across protocols.
- **Data Storage:** SQLite (via Room) is used for storing hosts, snippets, rules, and telemetry locally.
- **Security:** Android Keystore provides hardware-backed AES-256-GCM encryption for credentials, private keys, and passwords.
- **Execution Model:** Background services and WakeLocks allow resilient, persistent SSH terminal sessions (`tmux`-backed when available) to survive network drops and app backgrounding. Monitoring tasks are executed dynamically by parsing standard Linux `/proc` and utility outputs, requiring zero agents to be installed on remote servers.

## How to Use OmniTerm

### First Run & Adding Hosts
The first run flow helps you create a server entry. You can use password authentication, an imported SSH key, or a reusable credential profile.
Open **Servers** and choose add. Enter:
- Display name, Hostname or IP address, SSH port, Username, Authentication method
- Optional group, color, notes, keepalive, compression, proxy, and sudo password.

Groups make Fleet Broadcast targeting easier. Host colors help identify servers across terminal sessions, dashboards, and action output. Use the host picker on operational screens to switch the active server. You can also **swipe left/right** to move between tabs.

### Terminal
Open **Term** to start an interactive SSH shell on the selected host. OmniTerm supports multiple active sessions, background sessions, session switching, and explicit disconnect prompts to pause or terminate sessions.
- Persistent `tmux`-backed sessions that survive network drops and app restarts.
- Adjustable persistent font size with reflowing scrollback on resize.
- Theme presets: Omni Dark, Solarized Dark, Matrix, and Light.
- Hardware keyboard and soft keyboard input, plus a compact special-key bar.
- Long-press copy tools for visible screen or full scrollback text.
- Smooth row-snapped scrolling for local terminal history; a **Bottom** button jumps back to the live tail (and exits tmux copy-mode on persistent sessions).

### Files (SFTP, Transfers, Bookmarks, Shares)
Open **Files** to work with remote filesystems. The **SFTP** subtab browses files on the selected SSH host (the host picker lives on this subtab): upload, download, rename, delete, create folders, sort file lists, and edit text files.
- **CodeEditor:** The built-in text editor features line numbers, syntax highlighting, and find/replace, and supports sudo-assisted writes when configured for the host.
- The path bar is **editable** — tap it to type a destination and jump straight there.
- **Sudo mode** is authenticated via device biometrics/PIN before enabling.
- **Bookmarks** span every SSH host and network share: star a folder in the SFTP or Shares browser and it appears in the Bookmarks subtab labelled with its endpoint. Offline endpoints are greyed out until they come back.
- **Transfers** shows per-file rows for every transfer with a running rollup; individual transfers (or all of them) can be **cancelled** mid-flight, and transfers keep running if you navigate elsewhere in the app.

### Network Shares
Open the **Shares** subtab to work with network file shares that are separate from your SSH hosts.
- **Discovery & saved profiles:** Scan a subnet (e.g. `192.168.1.0/24`, or leave it blank on Wi-Fi/LAN) to find SMB, FTP, SFTP, NFS, and WebDAV services, then save them as reusable profiles. Protocol filter chips cut scan noise (e.g. untick WebDAV on printer-heavy networks); SMB hosts are expanded into their actual share names when the server allows anonymous enumeration. Credentials can be entered inline or linked to a shared credential profile.
- **File browsing:** Tap **Browse** on a SMB, FTP, SFTP, or WebDAV share to navigate folders, create/rename/delete, and upload or download files to your device. (NFS and custom profiles are save-only for now.) WebDAV shares carry an explicit **Use HTTPS** toggle.
- **Cross-protocol copy/paste:** Copy or cut files in a share and paste them into another folder, another share, or the SFTP host — and vice versa, in either direction. Same-host SFTP pastes run server-side (`cp`/`mv`); everything else streams through the device without buffering the whole file, so multi-GB transfers work. Whole **folders** copy recursively when you tick **Include folders** in the paste bar (off by default, since a deep tree can move a lot of data). A fully successful paste clears the clipboard.
- **Progress:** Every transfer surface shows a Windows-style rollup — number of files, bytes done of the total, combined speed, and ETA — plus per-file rows in the **Transfers** tab with per-row cancel.

### Monitoring
Open **Monitor** for live host metrics (CPU, memory, disk, load, uptime, process count, temperature).
- Disk mounts and SMART health when available.
- Process, service, log, scripts, and cron views.
- Visual cron schedule management for the selected host.

### Fleet Broadcast
Open **Fleet > Broadcast** to run a command across selected online hosts or host groups. Target controls and command presets stay compact. Supports live per-host streaming output and built-in/saved fleet scripts.

### Scripts & Automation
Open **Tools > Scripts** to create, edit, delete, and organize saved scripts. A script can be made available for quick per-host execution, fleet broadcast execution, or both.

### Alerts & History
Open **Tools > Alerts & Rules** to manage alert rules (CPU, memory, disk, latency thresholds). Rules are evaluated during OmniTerm's in-app metrics refresh while the app is open. The Alerts Center tracks active and historical incidents.

### Docker, Podman & Stacks
Open **Infra** to manage containers, compose stacks, images, and volumes. OmniTerm works with both Docker and Podman automatically.
- **Containers & Stacks:** View summary health, expand to reveal ports, logs, stop/start actions, and exec shell. Support for full stack lifecycle actions.
- **Compose Builder:** A visual editor for `docker-compose.yml` files. Deploy new stacks or surgically edit existing ones. Every deploy is fail-safe and validated with `compose config` before applying.

### Wake-On-LAN
Open **Tools > Wake on LAN** to save wake targets and send magic packets. You can scan the LAN from the target editor, select discovered devices, and wake saved machines.

## Settings & Customization
Open **Tools > Settings** to configure the app to your liking:
- App lock and biometric unlock.
- App theme (System / Dark / AMOLED / Light), a high-contrast mode, and text scale.
- Metrics refresh interval and retention window.
- Terminal font size, theme, and scrollback limit.
- Background session keepalive.
- Alert history limit and SFTP transfer warnings.

**About > Device & diagnostics** shows your app version, build, device info, and an on-device crash history viewer to help you report issues.

## Backup & Restore
Open **Tools > Backups Hub** to export or restore a selective backup of OmniTerm's app data (hosts, SSH keys, reusable credential profiles, scripts, alert data, saved network shares, and settings).
- Backups including sensitive sections are compressed and encrypted with AES-256-GCM using a passphrase-derived key.
- OmniTerm app backups do not copy files from your remote hosts.
- OmniTerm does not store the backup passphrase. Keep it safe.

## Security & Privacy Features

Security is a first-class citizen in OmniTerm. The app is designed to protect your sensitive data and infrastructure:

- **No Cloud, No Agents**: OmniTerm connects directly from your Android device to your hosts. It does not require a cloud account, nor does it phone home or collect your hosts, credentials, files, or usage data.
- **Hardware-Backed Encryption**: All credentials, private keys, sudo passwords, and proxy passwords are encrypted on-device using Android Keystore-backed AES-256-GCM.
- **SSH Host Key Pinning**: OmniTerm pins the SSH host key on the first connection. If a host presents a different key later (e.g., due to a Man-in-the-Middle attack), the connection is actively rejected.
- **Biometric App Lock**: You can lock the entire app behind Android biometrics or a PIN to prevent unauthorized access to your servers if your unlocked phone is left unattended.
- **Authenticated Sudo Operations**: Sudo-assisted writes in the SFTP file manager require explicit device authentication (biometric or PIN) before they can be enabled, ensuring accidental or malicious root operations are prevented.
- **Encrypted Backups**: Selective app backups that include sensitive sections (like hosts, keys, and profiles) are compressed and encrypted with AES-256-GCM using a user-provided passphrase. The app does not store this passphrase.
- **Ads Data (Play Store only)**: The free Play Store build shows a single banner via Google AdMob, which may access your advertising ID. The open-source build has no ads SDK and accesses no advertising ID.

## Troubleshooting & Support Options

**Common Issues:**
- **Host offline:** Confirm hostname/IP, SSH port, network route, and firewalls.
- **Auth fails:** Verify username, password, SSH key, and proxy config.
- **Empty monitoring:** Confirm the remote host has expected platform tools (Linux hosts provide richest metrics).
- **Infra issues:** Confirm Docker/Podman is installed and the SSH user has permission to run it.

**Support:**
If you encounter bugs, crashes, or have feature requests:
- **GitHub Issues:** Please open an issue on our GitHub Repository with diagnostic logs from **About > Device & diagnostics**.
- **Community:** Join our discussion boards on GitHub or reach out via email.

## Donations & Support the Project
OmniTerm is proudly maintained and open source. If you find OmniTerm useful and want to support its ongoing development, consider:
- Purchasing the **Unlock OmniTerm** option in the Google Play Store build.
- Starring our repository on GitHub.
- Spreading the word to other developers and homelab enthusiasts!

## Build From Source
For developers looking to contribute or build locally, the project defaults to conservative Gradle settings (usable on Raspberry Pi 5):
```bash
./gradlew rpiCheck --no-daemon
```
On a larger workstation, full verification is available:
```bash
./gradlew assembleDebug test -Dorg.gradle.jvmargs=-Xmx4g --max-workers=4
```
