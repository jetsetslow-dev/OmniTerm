# OmniTerm

OmniTerm is a native Android app for managing SSH hosts, homelab servers, Docker/Podman containers and stacks, files, metrics, alerts, and Wake-on-LAN targets from one phone or tablet — no cloud account, no agent to install on your servers.

## Features At A Glance

- **SSH terminal** with multiple background-capable sessions, session switching, a special-key bar, themes, and copy tools.
- **SFTP file manager** with an in-app text editor, an editable path bar, copy-path and quick-bookmark actions, authenticated sudo writes, per-host bookmarks, and large-transfer warnings.
- **Live monitoring**: CPU, memory, disk, load, uptime, temperature, per-core usage, network/disk I/O rates, SMART health, and process/service/log views.
- **Docker & Podman**: containers, stacks, images, and volumes, plus a visual **Compose Builder** with safe validate-before-deploy.
- **Fleet Broadcast**: run a command across many hosts or groups at once with live per-host output.
- **Scripts, alerts, cron, and Wake-on-LAN** management.
- **Encrypted, selective backups** (AES-256-GCM) of your app data.
- **On-device security**: Keystore-backed credential encryption, SSH host-key pinning, optional app lock and biometrics.

## Install

OmniTerm comes in two builds with the same features:

- **Open-source build** — install the APK from the OmniTerm GitHub release page.
  No host limits, no ads, no in-app purchases.
- **Play Store build** — install from Google Play when available. Free with a
  1-host limit and a single bottom banner; optional one-time purchases remove the
  banner or remove it and lift the host limit. Prices are shown in your local
  currency by Google Play.

To install the open-source APK:

1. Download the latest APK from the OmniTerm GitHub release page.
2. On Android, allow installing apps from the source you used to download the APK.
3. Open the APK and install OmniTerm.
4. Launch OmniTerm and add your first host.

OmniTerm stores host records, credentials, SSH keys, app settings, alert rules, and backups on your device.

## Licensing And Distribution

OmniTerm source is available under the PolyForm Noncommercial License 1.0.0.
Personal, educational, evaluation, and other noncommercial source builds are
allowed. Commercial redistribution, paid forks, app-store publication by third
parties, hosted/managed paid builds, and monetized derivatives require separate
written permission.

The GitHub open-source build and the Play Store build have the same core app
features. They differ only in distribution and monetization:

| | Open-source build | Play Store build (free) | Remove Ads | Unlock |
|---|---|---|---|---|
| Saved hosts | Unlimited | 1 | 1 | Unlimited |
| Saved credentials | Unlimited | 1 | 1 | Unlimited |
| Ads | None | Single bottom banner | None | None |
| All other features | Yes | Yes | Yes | Yes |

- Both Play Store purchases are **one-time** (not subscriptions). **Remove Ads**
  hides the banner. **Unlock OmniTerm** removes the banner *and* lifts the
  host/credential limits. Buying Unlock also removes ads, so you never need both.
  Each price is set per region in Google Play and always displayed in the user's
  local currency.
- The single ad is a non-intrusive bottom banner shown only in the free Play
  Store tier; there are no interstitial, pop-up, or full-screen ads. In the
  EEA/UK a consent prompt (Google's User Messaging Platform) is shown before any
  ad loads, and ad content is limited to a general (family-friendly) rating.
- The open-source build contains **no** Play Billing code and **no** ad SDK, has
  no host/credential limits, and uses application id
  `com.jetsetslow.omniterm.oss` so it cannot replace the Play Store package.
- Purchases are tied to your Google account. Reinstalling or switching devices?
  Use **Restore purchase** on the unlock screen to re-apply your entitlement.

## First Run

The first run flow helps you create a server entry. You can use password authentication, an imported SSH key, or a reusable credential profile. After a host is added, OmniTerm checks TCP reachability and then uses SSH to collect live status when credentials are available.

Use the host picker on operational screens to switch the active server. You can
also **swipe left/right** to move between tabs: a horizontal swipe pages through a
screen's subtabs first (for example Monitor or Infra), then carries over to the
adjacent top-level tab at the edges.

## Adding Hosts

Open **Servers** and choose add. Enter:

- Display name
- Hostname or IP address
- SSH port
- Username
- Authentication method
- Optional group, color, notes, keepalive, compression, proxy, and sudo password

Groups make Fleet Broadcast targeting easier. Host colors help identify servers across terminal sessions, dashboards, and action output.

## Terminal

Open **Term** to start an interactive SSH shell on the selected host. OmniTerm supports multiple active sessions, background sessions, session switching, and disconnect prompts when leaving an active terminal.

The terminal includes:

- Adjustable persistent font size
- Theme presets: Omni Dark, Solarized Dark, Matrix, and Light
- Hardware keyboard and soft keyboard input
- A compact special-key bar with navigation keys, modifiers, function keys, and Enter
- Long-press copy tools for visible screen or full scrollback text
- Background session parking without losing output

Terminal settings are available in **Tools > Settings**.

## SFTP

Open **SFTP** to browse files on the selected host. You can upload, download, rename, delete, create folders, and edit text files. The text editor uses a large editing surface and supports sudo-assisted writes when configured for the host.

The path bar is **editable** — tap it to type a destination and jump straight
there. Each file/folder menu can **copy the absolute path** to the clipboard, and a
toolbar button **quick-bookmarks the current directory** (tap again to remove it).

**Sudo mode is authenticated.** Turning on sudo mode (which runs file operations as
root) shows a warning and then requires device authentication — biometric or device
credential, with an app-PIN fallback — before it is enabled. Turning it off needs no
authentication.

**Bookmarks** let you jump to frequently used directories on a host. Each host
keeps its own bookmark list (seeded with common paths like `/etc`, `/var/log`,
and `/opt`), and bookmarks are included in encrypted backups and remapped to the
right host on restore.

Large transfer warning thresholds are configurable in **Tools > Settings**.

## Monitoring

Open **Monitor** for live host metrics:

- CPU, memory, disk, load, uptime, process count, and temperature
- Per-core CPU usage when Linux `/proc/stat` is available
- Disk mounts and SMART health when available
- Network and disk I/O rates after the second refresh sample
- Process, service, log, scripts, and cron views
- Host-scoped script execution filtered by detected OS and system type
- Visual cron schedule management for the selected host. Cron entries are user-defined commands; OmniTerm writes them to that host user's crontab.

The refresh interval and metric retention window are configurable in **Tools > Settings**.

## Fleet Broadcast

Open **Fleet > Broadcast** to run a command across selected online hosts or host groups. Target controls and command presets stay compact, and once output exists the output list becomes the main workspace.

Fleet Broadcast supports:

- Online host and group targeting
- Built-in and saved fleet scripts
- Ad hoc command entry with save-to-script workflow
- Live per-host streaming output
- Clearable output history for the current broadcast run

Fleet scripts are not filtered by host OS or system type because they are intended for broadcast use across the selected fleet. Manage script availability and metadata from **Tools > Scripts**.

## Scripts

Open **Tools > Scripts** to create, edit, delete, and organize saved scripts. A script can be made available for quick per-host execution, fleet broadcast execution, or both.

Quick scripts are shown in **Monitor > Scripts** and are filtered by the selected host's detected OS and system type. Fleet scripts are shown in **Fleet > Broadcast** and are available for broadcast without host filtering.

## Alerts And History

Open **Tools > Alerts & Rules** to manage alert rules. Rules are evaluated during OmniTerm's in-app metrics refresh while the app is open.

The Alerts Center includes:

- A global alerts on/off switch
- **Active** for current firing incidents
- **Rules** for editable CPU, memory, disk, and latency thresholds
- **History** for acknowledged, muted, and resolved incidents

Alert history keeps the newest records according to the limit configured in **Tools > Settings**.

## Docker, Podman, And Stacks

Open **Infra** to manage containers, compose stacks, images, and volumes on the
selected host. OmniTerm works with both **Docker and Podman** — it detects which
runtime is installed and uses the matching commands automatically, including
`docker compose` / `podman compose` (falling back to the standalone
`docker-compose` / `podman-compose` binaries where needed). No configuration is
required; if a host has either runtime and your user can access it, it works.

> **Podman and Kubernetes support note.** OmniTerm is primarily developed and
> tested against Docker. Podman support is included and works for common
> workflows, but has not been as extensively tested or tuned — edge cases around
> rootless Podman, socket paths, and compose label behaviour may differ. Kubernetes
> is not directly supported; the Infra screen targets hosts that run Docker or
> Podman and issues `kubectl` commands only via the terminal or scripts.

The Infra screen has four tabs:

**Containers & Stacks.** OmniTerm groups compose services into stacks when
runtime labels are available. Stack cards show summary health first.
Service/container rows are collapsed by default and expand to reveal ports,
logs, follow logs, stop, restart, scale, an exec shell, and a **Remove** action
that stops and removes the service's container(s) (the compose definition is not
deleted). Tapping the stack-level port count opens the published port details.
Supported stack actions include ps, logs, follow logs, config, pull, update, up,
restart, down, and **Remove Orphans** (removes containers for services no longer
defined in the compose file without bringing the whole stack down). Each
container can also be started, stopped, paused, unpaused, restarted, or removed,
with multi-select for bulk removal.

**Compose Builder.** A visual editor for `docker-compose.yml` files. Use it two
ways:

- **Create a new stack** from scratch — add services with image, container name,
  restart policy, command, ports, environment variables, volumes, networks, and
  dependencies, then deploy to `~/<project-name>` on the host.
- **Edit an existing stack** with **Edit in Builder** from a stack card. This
  reads the live file and lets you change it visually. Edits are **surgical**:
  only the fields you actually change are rewritten, and everything the builder
  doesn't model (healthchecks, deploy/resource limits, anchors, comments, custom
  keys, top-level volumes/networks) is preserved exactly as it was.

Every deploy is **fail-safe**. The new file is validated with `compose config`
*before* anything is swapped in; your current file is backed up; and if the
deploy fails the previous file is restored automatically and the stack is left
running as it was. A clear banner tells you whether the deploy succeeded or
failed — a broken file is never silently reported as deployed. A **Raw YAML**
toggle is available for hand-editing anything the visual form can't represent.

**Images.** List images with size, in-use status, and creation time. Remove
unused images individually or with multi-select.

**Volumes.** List volumes with driver, mountpoint, size, and in-use status
(where the runtime reports it). Remove volumes individually or with multi-select.

## Wake-On-LAN

Open **Tools > Wake on LAN** to save wake targets and send magic packets. Each target stores a name, MAC address, broadcast IP, UDP port, notes, and last wake time.

You can scan the LAN from the target editor, select discovered devices, and wake saved machines from the compact target list.

## Settings

Open **Tools > Settings** to configure:

- App lock and biometric unlock
- Keep-screen-on behavior
- Metrics refresh interval
- App theme (System / Dark / Light), a high-contrast mode (stronger accents and surfaces), and text scale
- Background session keepalive
- Metric retention
- Terminal font size and theme
- Terminal scrollback limit
- Alert history limit
- SFTP large transfer warnings

Settings use a save/cancel bar when changes are staged.

**About > Device & diagnostics** shows your app version and build, distribution
(open-source / Play Store), device model, Android version and API level, ABI, and —
on the Play Store build only — the advertising ID. A **Copy diagnostics** button puts
this block on the clipboard to paste into a support request. The open-source build
reports "N/A" for the advertising ID because it ships no ads SDK.

## Backup And Restore

Open **Tools > Backups Hub** to export or restore a selective backup of OmniTerm's app data. Choose which sections to include, such as hosts, SSH keys, credential profiles, scripts, alert data, Wake-on-LAN targets, or settings and customizations.

Backups that include sensitive sections, such as hosts, SSH keys, or credential profiles, are compressed and encrypted with AES-256-GCM using a passphrase-derived key. Non-sensitive selections can be exported as plain JSON. During restore, OmniTerm inspects the backup and lets you choose from the sections available in that file.

OmniTerm app backups do not copy files from your remote hosts. If you want a remote host to run its own backup command, create a user-defined cron entry from **Monitor > Cron**; the command decides what is backed up and where the remote files are written.

Device-local security settings such as app PIN and biometrics are not restored onto another device. Keep encrypted backup files and passphrases safe. OmniTerm does not store the backup passphrase.

## Troubleshooting

If a host is offline, confirm the hostname/IP, SSH port, network route, and firewall rules.

If authentication fails, verify the username, password, SSH key, credential profile, and any proxy or jump-host configuration.

If monitoring is empty, confirm SSH authentication works and that the remote host has the expected platform tools. Linux hosts provide the richest metrics through `/proc`, `df`, `free`, `top`, `ps`, `systemctl`, and Docker/Podman commands when installed.

If the Infra screen reports it cannot query containers, confirm Docker or Podman is installed on the host and that the SSH user can run it (for Docker, the user is usually in the `docker` group; for rootless Podman, that the user has a running Podman). If a compose deploy fails, the on-screen banner shows the exact validation or runtime error and your previous compose file is left in place — fix the reported issue and deploy again.

If sudo actions do not run, save the host's sudo password or use an account with passwordless sudo for the command being executed.

If Wake-on-LAN does not wake a target, confirm the MAC address, broadcast address, UDP port, BIOS/UEFI WoL support, and router/switch forwarding behavior.

## Privacy And Security

OmniTerm connects directly from your Android device to your hosts. It does not require a cloud account and does not collect or send your hosts, credentials, files, or usage to OmniTerm or any analytics service.

Credentials, imported private keys, sudo passwords, proxy passwords, and the app PIN are encrypted on-device with Android Keystore-backed AES-GCM. SSH host keys are pinned on first use; if a host presents a different key later, OmniTerm rejects the connection instead of silently accepting it.

Credentials and imported keys remain on-device unless you export an encrypted backup. Anyone with device access, app access, or a backup passphrase may be able to use saved credentials, so protect your device and backup files carefully.

**Ads (free Play Store tier only).** The free Play Store build shows a single banner via Google AdMob. To serve it, the Google Mobile Ads SDK may access your device's advertising ID and related data, as described in Google's policies — this is reflected in the app's Play Data safety disclosure. In the EEA/UK a consent prompt is shown before ads load. Removing ads (or unlocking the app) stops ad requests entirely. The **open-source build has no ads SDK and accesses no advertising ID.**
