import 'remote_commands.dart' show pmInstallSeconds, pmUpdateSeconds;
import 'term/tmux_bootstrap.dart' show tmuxPath;

/// A helper program OmniTerm can install on a host from wherever it says the program is missing,
/// and what each package manager calls its package. A null package means that manager has none,
/// and the install says so instead of guessing.
///
/// [command] is what answers once the install worked. The NVIDIA package names are shell
/// expressions, resolved on the host from the driver already installed (see [_nvidiaPackage]).
///
/// Ported from `HostTool` in `data/HostTools.kt`; both build the same scripts, byte for byte.
enum HostTool {
  tmux(
    'tmux',
    'tmux',
    apt: 'tmux',
    dnf: 'tmux',
    pacman: 'tmux',
    apk: 'tmux',
    zypper: 'tmux',
    pkg: 'tmux',
    brew: 'tmux',
  ),
  dmidecode(
    'dmidecode',
    'dmidecode',
    apt: 'dmidecode',
    dnf: 'dmidecode',
    pacman: 'dmidecode',
    apk: 'dmidecode',
    zypper: 'dmidecode',
    pkg: 'dmidecode',
  ),
  smartmontools(
    'smartmontools',
    'smartctl',
    apt: 'smartmontools',
    dnf: 'smartmontools',
    pacman: 'smartmontools',
    apk: 'smartmontools',
    zypper: 'smartmontools',
    pkg: 'smartmontools',
    brew: 'smartmontools',
  ),
  nvidiaSmi(
    'nvidia-smi',
    'nvidia-smi',
    apt: r'$(nvpkg apt)',
    dnf: r'$(nvpkg rpm)',
    pacman: 'nvidia-utils',
    zypper: r'$(nvpkg zypper)',
  );

  const HostTool(
    this.displayName,
    this.command, {
    this.apt,
    this.dnf,
    this.pacman,
    this.apk,
    this.zypper,
    this.pkg,
    this.brew,
  });

  final String displayName;
  final String command;
  final String? apt;
  final String? dnf;
  final String? pacman;
  final String? apk;
  final String? zypper;
  final String? pkg;
  final String? brew;

  /// Installs this tool with whichever package manager the host has, bounding every step (see
  /// [pmUpdateSeconds]), then checks that [command] answers. As root it runs directly; otherwise
  /// through sudo, reading the password from stdin when [withSudoPassword] (see `sudoStdin`) and
  /// refusing rather than waiting for one when not. sudo's own "[sudo] password for" prompt is
  /// left out of the output.
  String installCommand({bool withSudoPassword = true}) {
    final sudo = withSudoPassword ? '-S' : '-n';
    const bound = pmInstallSeconds;
    String branch(String manager, String? package, String Function(String) install) =>
        'command -v $manager >/dev/null 2>&1; then '
        '${package == null ? "echo 'OmniTerm cannot install $displayName with $manager: it has no $displayName package.' >&2; exit 1" : install(package)}; ';
    final branches = [
      branch(
        'apt-get',
        apt,
        (p) => 'pm $pmUpdateSeconds apt-get update && pm $bound apt-get install -y $p',
      ),
      branch('dnf', dnf, (p) => 'pm $bound dnf install -y $p'),
      branch('yum', dnf, (p) => 'pm $bound yum install -y $p'),
      branch('pacman', pacman, (p) => 'pm $bound pacman -Sy --noconfirm $p'),
      branch('apk', apk, (p) => 'pm $bound apk add $p'),
      branch('zypper', zypper, (p) => 'pm $bound zypper install -y $p'),
      branch('pkg', pkg, (p) => 'pm $bound pkg install -y $p'),
      // [tmuxPath] puts Homebrew on PATH on a Mac.
      branch('brew', brew, (p) => 'pm $bound brew install $p'),
    ];
    return '${this == tmux ? tmuxPath : ''}$_installPath'
        "set -e; if command -v $command >/dev/null 2>&1; then echo '$displayName is already installed'; exit 0; fi; "
        'if [ "\$(id -u)" = 0 ]; then SUDO=; else SUDO=$sudo; fi; '
        // `pm <seconds> <command>` elevates the command unless already root, or it is Homebrew,
        // which refuses to run as root and needs no sudo. Doing it here rather than through a
        // `$SUDO` prefix lets the empty prompt survive as one argument.
        //
        // A dpkg/apt or dnf lock held by unattended-upgrades blocks forever; the transport would
        // eventually cut the stream and the user would see a bare "command timed out" half an hour
        // later, with nothing saying a lock was the reason or that nothing was installed.
        'pm(){ n=\$1; shift; s=0; [ -z "\$SUDO" ] || [ "\$1" = brew ] || set -- sudo "\$SUDO" -p \'\' "\$@"; '
        'if command -v timeout >/dev/null 2>&1; then timeout "\$n" "\$@" || s=\$?; else "\$@" || s=\$?; fi; '
        'if [ "\$s" = 124 ]; then '
        'echo "OmniTerm: \$* did not finish within \${n}s. Another package manager is most likely '
        'holding the lock (unattended-upgrades, an interrupted install, or a stale lock file). '
        'Nothing was installed - retry once that finishes." >&2; fi; return "\$s"; }; '
        '${this == nvidiaSmi ? _nvidiaPackage : ''}'
        'if ${branches.join('elif ')}'
        "else echo 'No supported package manager found; install $displayName manually.' >&2; exit 1; fi; "
        "command -v $command >/dev/null 2>&1 && echo '$displayName installed' || { echo '$displayName install failed' >&2; exit 1; }";
  }

  /// Prints "yes" when [command] answers on the host, else "no".
  String checkCommand() =>
      '${this == tmux ? tmuxPath : ''}${_installPath}command -v $command >/dev/null 2>&1 && echo yes || echo no';
}

/// dmidecode and smartctl live in sbin, which a non-root login's PATH often leaves out.
const _installPath = 'PATH="\$PATH:/usr/local/sbin:/usr/sbin:/sbin"; ';

/// nvidia-smi must come from the same driver branch and version as the kernel module, or it answers
/// only "Driver/library version mismatch". Ubuntu names the branch in the driver's own
/// nvidia-kernel-common package (nvidia-utils-595-server goes with nvidia-kernel-common-595-server),
/// Debian ships it as nvidia-smi, RPM Fusion and NVIDIA's own repository name it differently, and
/// openSUSE by driver generation.
const _nvidiaPackage =
    r'''nvpkg(){ case $1 in '''
    r'''apt) p=$(dpkg-query -W -f='${db:Status-Abbrev}${Package} ${Version}\n' 'nvidia-kernel-common-*' 2>/dev/null | '''
    r'''awk '$1=="ii"{print $2"="$3; exit}'); '''
    r'''if [ -n "$p" ]; then echo "nvidia-utils-${p#nvidia-kernel-common-}"; else echo nvidia-smi; fi;; '''
    r'''rpm) if rpm -q xorg-x11-drv-nvidia >/dev/null 2>&1; then echo xorg-x11-drv-nvidia-cuda; else echo nvidia-driver-cuda; fi;; '''
    r'''zypper) g=$(rpm -qa --qf '%{NAME}\n' 2>/dev/null | sed -n 's/^nvidia-.*-\(G0[0-9]\)$/\1/p' | head -n 1); '''
    r'''echo "nvidia-compute-utils-${g:-G06}";; esac; }; ''';
