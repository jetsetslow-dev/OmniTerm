# OS lab

Throwaway QEMU virtual machines for what the Docker fleet (`scripts/test-hosts.sh`) cannot be. The
fleet is Linux containers; OmniTerm also has to work against a BSD host, a Windows host and a real
Kubernetes API server. These VMs are how that was validated, and how it can be again.

Like the fleet, this is a local developer tool. Nothing in CI or `scripts/local-pr-check.sh` runs it.

| VM | SSH (host / emulator) | What it is for |
|---|---|---|
| `freebsd` | `127.0.0.1:2224` / `10.0.2.2:2224` | FreeBSD 15.1: monitoring, services, files and tmux on BSD; `sh`, `tcsh`, `zsh` and `fish` login shells; password logins; a two-step (TOTP) account |
| `windows` | `127.0.0.1:2223` / `10.0.2.2:2223` | Windows Server 2025 evaluation: OpenSSH with PowerShell (default) or `cmd` (`OMNITERM_WINDOWS_SHELL=cmd`) as its shell |
| `k3s` | `127.0.0.1:2225` / `10.0.2.2:2225` | Debian 13 with k3s: Kubernetes over SSH (`omnik8s` has `~/.kube/config`, which the app uses; plain `kubectl` there reads k3s's root-only file, so remove `~/.kube/config` to see how the app handles that), and the API at `https://10.0.2.2:16443` for saved clusters, with sample workloads in namespace `shop` |

## Requirements

KVM access (`/dev/kvm`), QEMU (`qemu-system-x86_64` and `qemu-img`), `xz`, `curl`, OpenSSH and
Python 3. The script checks for them and installs nothing. Memory: 3 GB each for `freebsd` and
`k3s`, 6 GB for `windows`. Disk: about 25 GB with all three.

## Use

```sh
./scripts/os-lab/os-lab.sh up k3s        # first run downloads, verifies and sets it up
./scripts/os-lab/os-lab.sh hosts         # accounts to enter in OmniTerm
./scripts/os-lab/os-lab.sh kubeconfig    # a kubeconfig the emulator can import
./scripts/os-lab/os-lab.sh ssh freebsd uname -a
./scripts/os-lab/os-lab.sh status
./scripts/os-lab/os-lab.sh down all      # clean shutdown; disks stay for next time
./scripts/os-lab/os-lab.sh destroy --yes # delete everything below
```

The first `up` takes a few minutes for `freebsd` and `k3s`, and 20 to 40 minutes for `windows`,
which installs unattended. Later runs boot the existing disk.

## Where things live

Everything the lab makes is in `$OMNITERM_OS_LAB` (default `~/omniterm-os-lab`), outside the
repository: disks, the SSH key every VM trusts (`lab_ed25519`), generated passwords
(`*-password.txt`), the two-step account's TOTP secret and the k3s kubeconfig. Passwords are
generated per machine and never printed; `python3 scripts/os-lab/totp.py <secret file>` prints the
current code for the two-step account.

Images are pinned by checksum: FreeBSD 15.1-RELEASE, Windows Server 2025 build 26100 from
Microsoft's evaluation center, Debian 13 cloud build `20261026-2643`, and k3s `v1.36.5+k3s1`. A
changed download fails its checksum instead of quietly testing something else. Microsoft's link in
particular can move to a newer build; check the new image, then update the pin in `os-lab.sh`.

Seeds (cloud-init for FreeBSD and Debian, `autounattend.xml` for Windows) are plain folders that
QEMU presents to the VM as a FAT disk, so no root access or image tools are needed.
