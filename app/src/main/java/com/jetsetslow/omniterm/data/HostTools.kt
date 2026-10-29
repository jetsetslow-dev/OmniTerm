package com.jetsetslow.omniterm.data

/**
 * A helper program OmniTerm can install on a host from wherever it says the program is missing,
 * and what each package manager calls its package. A null package means that manager has none,
 * and the install says so instead of guessing.
 *
 * [command] is what answers once the install worked. The NVIDIA package names are shell
 * expressions, resolved on the host from the driver already installed (see [NVIDIA_PACKAGE]).
 */
enum class HostTool(
    val displayName: String,
    val command: String,
    private val apt: String?,
    private val dnf: String?,
    private val pacman: String?,
    private val apk: String?,
    private val zypper: String?,
    private val pkg: String?,
    private val brew: String?,
) {
    Tmux("tmux", "tmux", "tmux", "tmux", "tmux", "tmux", "tmux", "tmux", "tmux"),
    Dmidecode("dmidecode", "dmidecode", "dmidecode", "dmidecode", "dmidecode", "dmidecode", "dmidecode", "dmidecode", null),
    Smartmontools(
        "smartmontools", "smartctl",
        "smartmontools", "smartmontools", "smartmontools", "smartmontools", "smartmontools", "smartmontools", "smartmontools",
    ),
    NvidiaSmi("nvidia-smi", "nvidia-smi", "\$(nvpkg apt)", "\$(nvpkg rpm)", "nvidia-utils", null, "\$(nvpkg zypper)", null, null);

    /**
     * Installs this tool with whichever package manager the host has, bounding every step (see
     * [RemoteCommands.PM_UPDATE_SECONDS]), then checks that [command] answers. As root it runs
     * directly; otherwise through sudo, reading the password from stdin when [withSudoPassword]
     * (see [RemoteCommands.sudoStdin]) and refusing rather than waiting for one when not. sudo's
     * own "[sudo] password for" prompt is left out of the output.
     */
    fun installCommand(withSudoPassword: Boolean = true): String {
        val sudo = if (withSudoPassword) "-S" else "-n"
        val bound = RemoteCommands.PM_INSTALL_SECONDS
        fun branch(manager: String, package_: String?, install: (String) -> String): String =
            "command -v $manager >/dev/null 2>&1; then " + (
                package_?.let(install)
                    ?: "echo 'OmniTerm cannot install $displayName with $manager: it has no $displayName package.' >&2; exit 1"
                ) + "; "
        val branches = listOf(
            branch("apt-get", apt) { "pm ${RemoteCommands.PM_UPDATE_SECONDS} apt-get update && pm $bound apt-get install -y $it" },
            branch("dnf", dnf) { "pm $bound dnf install -y $it" },
            branch("yum", dnf) { "pm $bound yum install -y $it" },
            branch("pacman", pacman) { "pm $bound pacman -Sy --noconfirm $it" },
            branch("apk", apk) { "pm $bound apk add $it" },
            branch("zypper", zypper) { "pm $bound zypper install -y $it" },
            branch("pkg", pkg) { "pm $bound pkg install -y $it" },
            // [RemoteCommands.TMUX_PATH] puts Homebrew on PATH on a Mac.
            branch("brew", brew) { "pm $bound brew install $it" },
        )
        return (if (this == Tmux) RemoteCommands.TMUX_PATH else "") + INSTALL_PATH +
            "set -e; if command -v $command >/dev/null 2>&1; then echo '$displayName is already installed'; exit 0; fi; " +
            "if [ \"\$(id -u)\" = 0 ]; then SUDO=; else SUDO=$sudo; fi; " +
            // `pm <seconds> <command>` elevates the command unless already root, or it is Homebrew,
            // which refuses to run as root and needs no sudo. Doing it here rather than through a
            // `$SUDO` prefix lets the empty prompt survive as one argument.
            //
            // A dpkg/apt or dnf lock held by unattended-upgrades blocks forever; the transport would
            // eventually cut the stream and the user would see a bare "command timed out" half an
            // hour later, with nothing saying a lock was the reason or that nothing was installed.
            "pm(){ n=\$1; shift; s=0; [ -z \"\$SUDO\" ] || [ \"\$1\" = brew ] || set -- sudo \"\$SUDO\" -p '' \"\$@\"; " +
            "if command -v timeout >/dev/null 2>&1; then timeout \"\$n\" \"\$@\" || s=\$?; else \"\$@\" || s=\$?; fi; " +
            "if [ \"\$s\" = 124 ]; then " +
            "echo \"OmniTerm: \$* did not finish within \${n}s. Another package manager is most likely " +
            "holding the lock (unattended-upgrades, an interrupted install, or a stale lock file). " +
            "Nothing was installed - retry once that finishes.\" >&2; fi; return \"\$s\"; }; " +
            (if (this == NvidiaSmi) NVIDIA_PACKAGE else "") +
            branches.joinToString("elif ", prefix = "if ") +
            "else echo 'No supported package manager found; install $displayName manually.' >&2; exit 1; fi; " +
            "command -v $command >/dev/null 2>&1 && echo '$displayName installed' || { echo '$displayName install failed' >&2; exit 1; }"
    }

    /** Prints "yes" when [command] answers on the host, else "no". */
    fun checkCommand(): String =
        (if (this == Tmux) RemoteCommands.TMUX_PATH else "") + INSTALL_PATH +
            "command -v $command >/dev/null 2>&1 && echo yes || echo no"

    private companion object {
        /** dmidecode and smartctl live in sbin, which a non-root login's PATH often leaves out. */
        const val INSTALL_PATH = "PATH=\"\$PATH:/usr/local/sbin:/usr/sbin:/sbin\"; "

        /**
         * nvidia-smi must come from the same driver branch and version as the kernel module, or it
         * answers only "Driver/library version mismatch". Ubuntu names the branch in the driver's
         * own nvidia-kernel-common package (nvidia-utils-595-server goes with
         * nvidia-kernel-common-595-server), Debian ships it as nvidia-smi, RPM Fusion and NVIDIA's
         * own repository name it differently, and openSUSE by driver generation.
         */
        const val NVIDIA_PACKAGE = "nvpkg(){ case \$1 in " +
            "apt) p=\$(dpkg-query -W -f='\${db:Status-Abbrev}\${Package} \${Version}\\n' 'nvidia-kernel-common-*' 2>/dev/null | " +
            "awk '\$1==\"ii\"{print \$2\"=\"\$3; exit}'); " +
            "if [ -n \"\$p\" ]; then echo \"nvidia-utils-\${p#nvidia-kernel-common-}\"; else echo nvidia-smi; fi;; " +
            "rpm) if rpm -q xorg-x11-drv-nvidia >/dev/null 2>&1; then echo xorg-x11-drv-nvidia-cuda; else echo nvidia-driver-cuda; fi;; " +
            "zypper) g=\$(rpm -qa --qf '%{NAME}\\n' 2>/dev/null | sed -n 's/^nvidia-.*-\\(G0[0-9]\\)\$/\\1/p' | head -n 1); " +
            "echo \"nvidia-compute-utils-\${g:-G06}\";; esac; }; "
    }
}
