#!/usr/bin/env bash
# Throwaway QEMU VMs for what the Docker fleet (scripts/test-hosts.sh) cannot be: a BSD host, a
# Windows host, and a Kubernetes node with a real API server. See scripts/os-lab/README.md.
#
# LOCAL DEVELOPER TOOL ONLY, like the fleet: nothing in CI or scripts/local-pr-check.sh runs it.
# It needs KVM and QEMU, downloads several GB, and installs nothing on this machine.
#
#   ./scripts/os-lab/os-lab.sh up <freebsd|windows|k3s>   # first use downloads, verifies and sets it up
#   ./scripts/os-lab/os-lab.sh down <freebsd|windows|k3s|all>
#   ./scripts/os-lab/os-lab.sh status
#   ./scripts/os-lab/os-lab.sh ssh <vm> [command]          # as the VM's admin user
#   ./scripts/os-lab/os-lab.sh forward                     # k3s API on 127.0.0.1:16443
#   ./scripts/os-lab/os-lab.sh kubeconfig                  # a kubeconfig the emulator can import
#   ./scripts/os-lab/os-lab.sh hosts                       # what to enter in OmniTerm
#   ./scripts/os-lab/os-lab.sh destroy --yes               # delete every VM, key and password
set -euo pipefail

# Everything the lab makes (disks, the lab key, generated passwords, a TOTP secret, a kubeconfig)
# lives here, outside the repository, so none of it can be committed by accident.
LAB="${OMNITERM_OS_LAB:-$HOME/omniterm-os-lab}"
MARKER=".omniterm-os-lab"
QEMU="${QEMU:-qemu-system-x86_64}"
KEY="$LAB/lab_ed25519"
KNOWN_HOSTS="$LAB/known_hosts"

# Pinned to what the lab was validated with. A changed download fails the checksum rather than
# quietly testing something else; check the new image, then update the pin.
FREEBSD_URL="https://download.freebsd.org/releases/VM-IMAGES/15.1-RELEASE/amd64/Latest/FreeBSD-15.1-RELEASE-amd64-BASIC-CLOUDINIT-ufs.qcow2.xz"
FREEBSD_SHA256="e4ca4db889f8559c9b9dfcacc70405c038476f4b6d41649b152d3809a2ed9e1f"
# Microsoft's evaluation download (180 days). The link can move to a newer build.
WINDOWS_URL="https://go.microsoft.com/fwlink/?linkid=2345730&clcid=0x409&culture=en-us&country=us"
WINDOWS_SHA256="7b052573ba7894c9924e3e87ba732ccd354d18cb75a883efa9b900ea125bfd51"
DEBIAN_BUILD="20261026-2643"
DEBIAN_URL="https://cloud.debian.org/images/cloud/trixie/$DEBIAN_BUILD/debian-13-genericcloud-amd64-$DEBIAN_BUILD.qcow2"
DEBIAN_SHA512="3ace18e33bdd036edb49d1f79342bd01d2ab980e35194edb0b410435cd543538d286a0bd13bbb0835f7862306e3d385ce2f6a70d8ecf0bd961111166adbc1b8e"
K3S_VERSION="v1.36.5+k3s1"
K3S_API_PORT=16443

die() { echo "os-lab: $*" >&2; exit 1; }

port_of() { case "$1" in windows) echo 2223 ;; freebsd) echo 2224 ;; k3s) echo 2225 ;; *) die "unknown VM '$1' (freebsd, windows, k3s)" ;; esac; }
admin_of() { case "$1" in windows) echo Administrator ;; freebsd) echo omni ;; k3s) echo omnik8s ;; esac; }
memory_of() { case "$1" in windows) echo 6144 ;; *) echo 3072 ;; esac; }
cpus_of() { case "$1" in windows) echo 4 ;; *) echo 2 ;; esac; }

require_tools() {
  local missing=() tool
  for tool in "$QEMU" curl ssh ssh-keygen python3 xz sha256sum sha512sum; do
    command -v "$tool" >/dev/null || missing+=("$tool")
  done
  QEMU_IMG="${QEMU_IMG:-$(dirname "$(command -v "$QEMU" || echo /usr/bin/x)")/qemu-img}"
  [ -x "$QEMU_IMG" ] || missing+=("qemu-img")
  [ "${#missing[@]}" -eq 0 ] ||
    die "missing: ${missing[*]}. This script installs nothing; on Debian/Ubuntu they come from qemu-system-x86, qemu-utils, xz-utils, curl, openssh-client and python3."
  [ -r /dev/kvm ] && [ -w /dev/kvm ] || die "no access to /dev/kvm (is your user in the kvm group?)"
}

ensure_lab() {
  umask 077
  mkdir -p "$LAB"
  [ -f "$LAB/$MARKER" ] || echo "OmniTerm OS lab (scripts/os-lab/os-lab.sh). Throwaway; 'destroy --yes' deletes it." >"$LAB/$MARKER"
  [ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -C omniterm-os-lab -f "$KEY"
}

# A random value kept in $LAB/<name>.txt, made on first use and never printed.
secret_file() {
  local file="$LAB/$1.txt" kind="${2:-password}"
  if [ ! -s "$file" ]; then
    case "$kind" in
      totp) python3 -I -c 'import base64,secrets; print(base64.b32encode(secrets.token_bytes(10)).decode())' ;;
      windows) python3 -I -c 'import secrets,string; a=string.ascii_letters+string.digits; print("Lab-"+"".join(secrets.choice(a) for _ in range(18))+"!9")' ;;
      *) python3 -I -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(20)))' ;;
    esac >"$file"
  fi
  echo "$file"
}

# Downloads <url> to $LAB/<file> unless it is already there with the pinned checksum.
fetch() {
  local url="$1" file="$LAB/$2" algo="$3" want="$4"
  if [ -f "$file" ] && [ "$("${algo}sum" "$file" | cut -d' ' -f1)" = "$want" ]; then return 0; fi
  echo "downloading $2"
  curl -fL --retry 3 -o "$file.part" "$url"
  [ "$("${algo}sum" "$file.part" | cut -d' ' -f1)" = "$want" ] ||
    die "$2 does not match its pinned $algo checksum. The download changed upstream; check it, then update the pin in $0."
  mv "$file.part" "$file"
}

running() { [ -f "$LAB/$1.pid" ] && kill -0 "$(cat "$LAB/$1.pid")" 2>/dev/null; }

monitor() {
  python3 -I -c 'import socket,sys,time
c=socket.socket(socket.AF_UNIX); c.connect(sys.argv[1]); time.sleep(0.3); c.recv(65536)
c.sendall(sys.argv[2].encode()+b"\n"); time.sleep(0.5); c.close()' "$LAB/$1-monitor.sock" "$2"
}

lab_ssh() {
  local vm="$1"; shift
  ssh -i "$KEY" -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
    -o ConnectTimeout=10 -o LogLevel=ERROR -p "$(port_of "$vm")" "$(admin_of "$vm")@127.0.0.1" "$@"
}

# A new disk has a new host key: forget the old one, or strict checking refuses the rebuilt VM.
forget_host() {
  [ -f "$KNOWN_HOSTS" ] || return 0
  ssh-keygen -q -f "$KNOWN_HOSTS" -R "[127.0.0.1]:$(port_of "$1")" >/dev/null 2>&1 || true
}

wait_for_ssh() {
  local vm="$1" limit="$2" start=$SECONDS
  echo "waiting for $vm to accept SSH (up to $((limit / 60)) min)"
  until lab_ssh "$vm" exit 2>/dev/null; do
    running "$vm" || die "$vm stopped while booting; see $LAB/$vm-serial.log"
    [ $((SECONDS - start)) -lt "$limit" ] || die "$vm did not accept SSH in time; see $LAB/$vm-serial.log"
    sleep 10
  done
}

# A folder shown to the VM as a FAT disk (QEMU's vvfat), so seeds need neither root nor mtools.
# snapshot=on, not readonly=on: FreeBSD's nuageinit mounts the seed read-write. The VM's writes go
# to a throwaway overlay and never reach the folder.
seed_drive() { echo "if=$2,format=raw,snapshot=on,file.driver=vvfat,file.dir=$1,file.label=$3"; }

boot() {
  local vm="$1"; shift
  running "$vm" && return 0
  local port; port=$(port_of "$vm")
  (echo >"/dev/tcp/127.0.0.1/$port") 2>/dev/null && die "port $port is already in use"
  "$QEMU" -name "omniterm-$vm" -enable-kvm -machine q35 -cpu host -smp "$(cpus_of "$vm")" -m "$(memory_of "$vm")" \
    "$@" -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$port-:22" \
    -display none -monitor "unix:$LAB/$vm-monitor.sock,server,nowait" -serial "file:$LAB/$vm-serial.log" \
    -daemonize -pidfile "$LAB/$vm.pid"
}

# Runs <script> as root in the VM, with <input> (secrets) on a file only root can read.
provision_unix() {
  local vm="$1" script="$2" input="$3"
  printf '%s' "$input" | lab_ssh "$vm" 'umask 077; cat > /tmp/omniterm-lab.in'
  printf '%s' "$script" | lab_ssh "$vm" 'cat > /tmp/omniterm-lab.sh'
  lab_ssh "$vm" 'sudo sh /tmp/omniterm-lab.sh; rc=$?; rm -f /tmp/omniterm-lab.sh /tmp/omniterm-lab.in; exit $rc'
}

# ---------------------------------------------------------------------------------------------
# FreeBSD: sh, tcsh, zsh and fish login shells, password logins, and a two-step (TOTP) account.

up_freebsd() {
  fetch "$FREEBSD_URL" freebsd.qcow2.xz sha256 "$FREEBSD_SHA256"
  if [ ! -f "$LAB/freebsd.qcow2" ]; then
    forget_host freebsd
    xz -dc "$LAB/freebsd.qcow2.xz" >"$LAB/freebsd.qcow2.part" && mv "$LAB/freebsd.qcow2.part" "$LAB/freebsd.qcow2"
    "$QEMU_IMG" resize -q "$LAB/freebsd.qcow2" 20G
  fi
  mkdir -p "$LAB/freebsd-seed"
  printf 'instance-id: omniterm-freebsd-lab\nlocal-hostname: omniterm-freebsd\n' >"$LAB/freebsd-seed/meta-data"
  cat >"$LAB/freebsd-seed/user-data" <<EOF
#cloud-config
users:
  - name: omni
    gecos: OmniTerm lab sh user
    groups: wheel
    shell: /bin/sh
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys: ["$(cat "$KEY.pub")"]
  - name: omnicsh
    gecos: OmniTerm lab csh user
    groups: wheel
    shell: /bin/tcsh
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys: ["$(cat "$KEY.pub")"]
ssh_pwauth: false
package_update: true
packages: [sudo, tmux]
EOF
  boot freebsd -drive "file=$LAB/freebsd.qcow2,if=virtio,format=qcow2" \
    -drive "$(seed_drive "$LAB/freebsd-seed" virtio CIDATA)" -device virtio-net-pci,netdev=n0
  wait_for_ssh freebsd 900
  [ -f "$LAB/freebsd.provisioned" ] && return 0
  echo "setting up FreeBSD users, password logins and two-step sign-in"
  local input
  input="$(cat "$(secret_file omnicsh-password)")
$(cat "$(secret_file omnifish-password)")
$(cat "$(secret_file omni2fa-password)")
$(cat "$(secret_file omni2fa-totp-secret totp)")
"
  provision_unix freebsd "$(cat <<'EOF'
set -e
IN=/tmp/omniterm-lab.in
CSH_PW=$(sed -n 1p $IN); FISH_PW=$(sed -n 2p $IN); TFA_PW=$(sed -n 3p $IN); TFA_SECRET=$(sed -n 4p $IN)
pkg install -y zsh fish bash 7-zip zip unzip pam_google_authenticator >/dev/null
echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /usr/local/etc/sudoers.d/wheel
for s in zsh fish; do
  id omni$s >/dev/null 2>&1 || pw useradd -n omni$s -m -s /usr/local/bin/$s -G wheel
  install -d -m 700 -o omni$s -g omni$s /home/omni$s/.ssh
  install -m 600 -o omni$s -g omni$s /home/omni/.ssh/authorized_keys /home/omni$s/.ssh/authorized_keys
done
printf '%s\n' "$CSH_PW" | pw usermod omnicsh -h 0
printf '%s\n' "$FISH_PW" | pw usermod omnifish -h 0
id omni2fa >/dev/null 2>&1 || pw useradd -n omni2fa -m -s /bin/sh
printf '%s\n' "$TFA_PW" | pw usermod omni2fa -h 0
(umask 077; printf '%s\n" RATE_LIMIT 30 30\n" WINDOW_SIZE 3\n" TOTP_AUTH\n' "$TFA_SECRET" > /home/omni2fa/.google_authenticator)
chown omni2fa:omni2fa /home/omni2fa/.google_authenticator
# The code is asked after the password, for every account that has a .google_authenticator file.
if ! grep -q pam_google_authenticator /etc/pam.d/sshd; then
  awk '{print} /^auth.*pam_unix.so/ && !done {print "auth\t\trequired\t/usr/local/lib/pam_google_authenticator.so\tnullok"; done=1}' \
    /etc/pam.d/sshd > /etc/pam.d/sshd.new && mv /etc/pam.d/sshd.new /etc/pam.d/sshd
fi
# sshd takes the first value it reads, so settings are rewritten in place, not appended.
c=/etc/ssh/sshd_config
set_option() {
  if grep -qE "^#?$1[[:space:]]" $c; then sed -i '' -E "s/^#?$1[[:space:]].*/$1 $2/" $c; else printf '%s %s\n' "$1" "$2" >> $c; fi
}
set_option PasswordAuthentication yes
set_option UsePAM yes
set_option KbdInteractiveAuthentication yes
grep -q '^Match User omni2fa' $c || printf '\nMatch User omni2fa\n\tAuthenticationMethods keyboard-interactive\n\tPasswordAuthentication no\n' >> $c
sshd -t
service sshd restart >/dev/null
EOF
)" "$input"
  touch "$LAB/freebsd.provisioned"
}

# ---------------------------------------------------------------------------------------------
# Windows Server 2025: OpenSSH with PowerShell (or cmd, OMNITERM_WINDOWS_SHELL=cmd) as its shell.

up_windows() {
  fetch "$WINDOWS_URL" windows-server-2025-eval.iso sha256 "$WINDOWS_SHA256"
  if [ ! -f "$LAB/windows.qcow2" ]; then
    forget_host windows
    "$QEMU_IMG" create -q -f qcow2 "$LAB/windows.qcow2" 40G
  fi
  local install=()
  if [ ! -f "$LAB/windows.installed" ]; then
    mkdir -p "$LAB/windows-seed"
    python3 -I - "$(secret_file windows-admin-password windows)" "$KEY.pub" "$LAB/windows-seed/autounattend.xml" <<'EOF'
import sys
from xml.sax.saxutils import escape
password = escape(open(sys.argv[1]).read().strip())
key = escape(open(sys.argv[2]).read().strip())
open(sys.argv[3], "w").write(f"""<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
      <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter><Active>true</Active></ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallTo><DiskID>0</DiskID><PartitionID>1</PartitionID></InstallTo>
          <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>1</Value></MetaData></InstallFrom>
        </OSImage>
      </ImageInstall>
      <UserData><AcceptEula>true</AcceptEula><FullName>OmniTerm Lab</FullName><Organization>OmniTerm Lab</Organization></UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>OMNITERM-WIN</ComputerName>
      <TimeZone>UTC</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UserAccounts>
        <AdministratorPassword><Value>{password}</Value><PlainText>true</PlainText></AdministratorPassword>
      </UserAccounts>
      <AutoLogon><Enabled>true</Enabled><Username>Administrator</Username><Password><Value>{password}</Value><PlainText>true</PlainText></Password><LogonCount>1</LogonCount></AutoLogon>
      <OOBE><HideEULAPage>true</HideEULAPage><SkipMachineOOBE>true</SkipMachineOOBE></OOBE>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add"><Order>1</Order><CommandLine>powershell -NoProfile -Command "Start-Service sshd; Set-Service -Name sshd -StartupType Automatic"</CommandLine></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>2</Order><CommandLine>powershell -NoProfile -Command "Set-Content -Encoding ascii -Path C:\\ProgramData\\ssh\\administrators_authorized_keys -Value '{key}'; icacls C:\\ProgramData\\ssh\\administrators_authorized_keys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F'"</CommandLine></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>3</Order><CommandLine>powershell -NoProfile -Command "New-NetFirewallRule -Name omniterm-lab-ssh -DisplayName 'OmniTerm lab SSH' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22"</CommandLine></SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
""")
EOF
    install=(-drive "file=$LAB/windows-server-2025-eval.iso,media=cdrom,if=none,id=cd0,readonly=on" -device ide-cd,drive=cd0,bus=ahci.1
      -drive "$(seed_drive "$LAB/windows-seed" none UNATTEND),id=seed0" -device usb-storage,bus=xhci.0,drive=seed0,removable=on
      -boot order=c,once=d)
    echo "installing Windows unattended; this takes 20-40 minutes"
  fi
  boot windows -drive "file=$LAB/windows.qcow2,if=none,id=hd0,format=qcow2" -device ahci,id=ahci -device ide-hd,drive=hd0,bus=ahci.0 \
    -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 -device e1000e,netdev=n0 "${install[@]}"
  wait_for_ssh windows 3600
  touch "$LAB/windows.installed"
  local shell="C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
  [ "${OMNITERM_WINDOWS_SHELL:-powershell}" = cmd ] && shell="C:\\Windows\\System32\\cmd.exe"
  # -EncodedCommand sidesteps quoting under whichever shell is current. Without the progress
  # preference, PowerShell's first run writes its module-loading progress to stderr as CLIXML.
  lab_ssh windows "powershell -NoProfile -EncodedCommand $(python3 -I -c 'import base64,sys; print(base64.b64encode(sys.argv[1].encode("utf-16-le")).decode())' \
    "\$ProgressPreference = 'SilentlyContinue'; New-ItemProperty -Path HKLM:\\SOFTWARE\\OpenSSH -Name DefaultShell -Value '$shell' -PropertyType String -Force | Out-Null")" >/dev/null
}

# ---------------------------------------------------------------------------------------------
# k3s on Debian 13: kubectl for the SSH user, an API the emulator can reach, and sample workloads.

up_k3s() {
  fetch "$DEBIAN_URL" "debian-13-genericcloud-amd64-$DEBIAN_BUILD.qcow2" sha512 "$DEBIAN_SHA512"
  if [ ! -f "$LAB/k3s.qcow2" ]; then
    forget_host k3s
    "$QEMU_IMG" create -q -f qcow2 -b "$LAB/debian-13-genericcloud-amd64-$DEBIAN_BUILD.qcow2" -F qcow2 "$LAB/k3s.qcow2" 20G
  fi
  mkdir -p "$LAB/k3s-seed"
  printf 'instance-id: omniterm-k3s-lab\nlocal-hostname: omniterm-k3s\n' >"$LAB/k3s-seed/meta-data"
  cat >"$LAB/k3s-seed/user-data" <<EOF
#cloud-config
users:
  - name: omnik8s
    gecos: OmniTerm lab k3s user
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys: ["$(cat "$KEY.pub")"]
ssh_pwauth: false
package_update: true
packages: [curl]
write_files:
  # The emulator reaches the API through the host machine, 10.0.2.2; the certificate must name it.
  - path: /etc/rancher/k3s/config.yaml
    content: |
      tls-san:
        - 10.0.2.2
runcmd:
  - [sh, -c, "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='$K3S_VERSION' sh - > /var/log/k3s-install.log 2>&1; echo K3S_RC=\$? >> /var/log/k3s-install.log"]
EOF
  boot k3s -drive "file=$LAB/k3s.qcow2,if=virtio,format=qcow2" \
    -drive "$(seed_drive "$LAB/k3s-seed" virtio CIDATA)" -device virtio-net-pci,netdev=n0
  wait_for_ssh k3s 900
  [ -f "$LAB/k3s.provisioned" ] && return 0
  echo "waiting for k3s $K3S_VERSION to install"
  local start=$SECONDS
  until lab_ssh k3s 'grep -q "^K3S_RC=" /var/log/k3s-install.log 2>/dev/null'; do
    [ $((SECONDS - start)) -lt 900 ] || die "k3s did not finish installing; see /var/log/k3s-install.log in the VM"
    sleep 10
  done
  lab_ssh k3s 'grep -q "^K3S_RC=0" /var/log/k3s-install.log' || die "k3s failed to install; see /var/log/k3s-install.log in the VM"
  echo "giving omnik8s kubectl access and starting sample workloads"
  provision_unix k3s "$(cat <<'EOF'
set -e
install -d -m 700 -o omnik8s -g omnik8s /home/omnik8s/.kube
k3s kubectl config view --raw > /home/omnik8s/.kube/config
chown omnik8s:omnik8s /home/omnik8s/.kube/config && chmod 600 /home/omnik8s/.kube/config
k=/usr/local/bin/kubectl
until $k get namespace default >/dev/null 2>&1; do sleep 2; done
$k create namespace shop
# Pods cannot be created until the namespace's default service account exists.
until $k -n shop get serviceaccount default >/dev/null 2>&1; do sleep 1; done
$k -n shop create deployment web --image=nginx:alpine --replicas=2
$k -n shop expose deployment web --port=80 --type=NodePort
# One that keeps crashing, a finished job, and a pod with two containers: the states the
# Kubernetes tab has to show.
$k -n shop run crasher --image=busybox:1.36 --restart=Always -- sh -c 'echo starting; sleep 3; exit 1'
$k -n shop create job once --image=busybox:1.36 -- sh -c 'echo job done'
$k apply -f - <<'POD'
apiVersion: v1
kind: Pod
metadata:
  name: duo
  namespace: shop
spec:
  containers:
  - name: app
    image: nginx:alpine
  - name: sidecar
    image: busybox:1.36
    command: ["sh", "-c", "while true; do echo tick; sleep 30; done"]
POD
EOF
)" ""
  touch "$LAB/k3s.provisioned"
}

forward_k3s() {
  [ -S "$LAB/k3s-forward.sock" ] && return 0
  ssh -i "$KEY" -o UserKnownHostsFile="$KNOWN_HOSTS" -o BatchMode=yes -o ExitOnForwardFailure=yes \
    -f -N -M -S "$LAB/k3s-forward.sock" -L "127.0.0.1:$K3S_API_PORT:127.0.0.1:6443" -p "$(port_of k3s)" omnik8s@127.0.0.1
  echo "k3s API on 127.0.0.1:$K3S_API_PORT (https://10.0.2.2:$K3S_API_PORT from the emulator)"
}

down_vm() {
  local vm="$1"
  if [ "$vm" = k3s ] && [ -S "$LAB/k3s-forward.sock" ]; then
    ssh -S "$LAB/k3s-forward.sock" -O exit omnik8s@127.0.0.1 2>/dev/null || true
    rm -f "$LAB/k3s-forward.sock"
  fi
  running "$vm" || return 0
  monitor "$vm" system_powerdown
  local start=$SECONDS
  while running "$vm" && [ $((SECONDS - start)) -lt 180 ]; do sleep 3; done
  if running "$vm"; then monitor "$vm" quit; echo "$vm forced off"; else echo "$vm shut down"; fi
}

case "${1:-}" in
  up)
    vm="${2:-}"; port_of "$vm" >/dev/null
    require_tools; ensure_lab
    "up_$vm"
    [ "$vm" = k3s ] && forward_k3s
    echo "$vm is up: ssh -p $(port_of "$vm") $(admin_of "$vm")@127.0.0.1 (10.0.2.2 from the emulator). '$0 hosts' lists the accounts."
    ;;
  down)
    vm="${2:-}"
    if [ "$vm" = all ]; then for v in freebsd windows k3s; do down_vm "$v"; done; else port_of "$vm" >/dev/null; down_vm "$vm"; fi
    ;;
  status)
    for vm in freebsd windows k3s; do
      if running "$vm"; then state="running, ssh 127.0.0.1:$(port_of "$vm")"; else state="stopped"; fi
      printf '%-8s %s\n' "$vm" "$state"
    done
    if [ -S "$LAB/k3s-forward.sock" ]; then echo "k3s API forwarded to 127.0.0.1:$K3S_API_PORT"; fi
    ;;
  ssh)
    vm="${2:-}"; port_of "$vm" >/dev/null; shift 2
    lab_ssh "$vm" "$@"
    ;;
  forward)
    running k3s || die "k3s is not running"
    forward_k3s
    ;;
  kubeconfig)
    running k3s || die "k3s is not running"
    out="$LAB/k3s-kubeconfig.yaml"
    (umask 077; lab_ssh k3s 'cat ~/.kube/config' | sed "s#https://127.0.0.1:6443#https://10.0.2.2:$K3S_API_PORT#" >"$out")
    echo "$out: import it in OmniTerm (Containers → Kubernetes → Cluster → Import kubeconfig…), with '$0 forward' running"
    ;;
  hosts)
    cat <<EOF
From an Android emulator the host machine is 10.0.2.2. Passwords are files in $LAB and are never
printed; the lab key is $KEY.

  FreeBSD sh      10.0.2.2:2224  user=omni      key
  FreeBSD tcsh    10.0.2.2:2224  user=omnicsh   key, or password in omnicsh-password.txt
  FreeBSD zsh     10.0.2.2:2224  user=omnizsh   key
  FreeBSD fish    10.0.2.2:2224  user=omnifish  key, or password in omnifish-password.txt
  FreeBSD 2FA     10.0.2.2:2224  user=omni2fa   password in omni2fa-password.txt, then a code
                                                (python3 scripts/os-lab/totp.py $LAB/omni2fa-totp-secret.txt)
  Windows         10.0.2.2:2223  user=Administrator  key, or password in windows-admin-password.txt
  k3s over SSH    10.0.2.2:2225  user=omnik8s   key; the app finds ~/.kube/config
  k3s cluster     https://10.0.2.2:$K3S_API_PORT  '$0 kubeconfig', with '$0 forward' running
EOF
    ;;
  destroy)
    [ "${2:-}" = --yes ] || die "destroy deletes $LAB entirely; run it with --yes"
    [ -f "$LAB/$MARKER" ] || die "$LAB is not an OS lab folder; not deleting it"
    for vm in freebsd windows k3s; do down_vm "$vm"; done
    rm -rf -- "$LAB"
    echo "deleted $LAB"
    ;;
  *)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
