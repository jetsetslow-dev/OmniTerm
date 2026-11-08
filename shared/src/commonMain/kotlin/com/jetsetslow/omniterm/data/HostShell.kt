package com.jetsetslow.omniterm.data

/**
 * Shell pieces that the host commands ([RemoteCommands], in the app) and the tool installs
 * ([HostTool]) both use. They live here, with no platform code, so both apps run the same text.
 */
object HostShell {
    /**
     * Directories package managers install into that a shell started for one command leaves off
     * PATH. Such a shell reads no login profile, so on macOS its PATH is /usr/bin:/bin:/usr/sbin:/sbin
     * and Homebrew's tmux, Docker Desktop's docker and Podman's own installer all read as missing.
     * Appended, so the host's own tools still come first.
     */
    const val EXTRA_PATH =
        "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/home/linuxbrew/.linuxbrew/bin:" +
            "/opt/podman/bin:/snap/bin:\$HOME/.docker/bin:\$HOME/.rd/bin"

    /**
     * Starts every tmux command: finds a tmux that a package manager put outside the system PATH.
     *
     * A command sent without a terminal starts a non-login shell, and on macOS that shell's PATH
     * is only /usr/bin:/bin:/usr/sbin:/sbin; Homebrew's directory is added by ~/.zprofile, which
     * only login shells read. So on a Mac with Homebrew's tmux the check said tmux was missing, and
     * session checks, screen captures and End session failed quietly. Covers Homebrew on Apple
     * silicon and Intel, MacPorts, and Homebrew on Linux, and leaves PATH alone wherever tmux is
     * already found.
     */
    const val TMUX_PATH = "command -v tmux >/dev/null 2>&1 || PATH=\"\$PATH:$EXTRA_PATH\"; "

    /** Bound for a package-index refresh. Long enough for a slow mirror, short enough to report. */
    const val PM_UPDATE_SECONDS = 180

    /** Bound for the install itself; well under the transport's 30-minute stream cap. */
    const val PM_INSTALL_SECONDS = 600
}
