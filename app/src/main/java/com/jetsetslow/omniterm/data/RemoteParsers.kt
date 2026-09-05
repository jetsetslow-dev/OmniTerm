package com.jetsetslow.omniterm.data

/** The exact remote commands we run, kept next to the parsers that consume their output. */
object RemoteCommands {
    /** Emitted only after a conflict scan script reaches its end successfully. */
    const val CONFLICT_SCAN_OK = "@OMNITERM_CONFLICT_SCAN_OK"

    // Container runtime resolved at run time: prefer a usable Docker, then a usable Podman. If
    // neither can run `ps` (for example Docker exists but the user lacks socket access), fall back
    // to a present binary so the command still returns the runtime's real permission/install error.
    private const val CR =
        "\"\$(if command -v docker >/dev/null 2>&1 && ot 10 docker ps >/dev/null 2>&1; then command -v docker; " +
        "elif command -v podman >/dev/null 2>&1 && ot 10 podman ps >/dev/null 2>&1; then command -v podman; " +
        "elif command -v docker >/dev/null 2>&1; then command -v docker; else command -v podman; fi)\""

    // Compose entrypoint resolved at run time. Docker prefers its plugin. Podman's `compose`
    // subcommand is only a dispatcher to an external provider and may select Docker Compose even
    // when native podman-compose is installed; prefer the explicit Podman provider to avoid a
    // Docker-socket or missing-rootless-socket cross-runtime failure.
    // Direct `docker-compose` is intentionally never used for a pinned Podman action: on hosts with
    // both engines it can talk to Docker's socket and deploy the stack into the wrong runtime.
    // The chosen invocation is exported as $OT_COMPOSE so a single resolution is reused across a
    // chained command. Emits an error to stderr and exits 1 if no compose tooling is present,
    // instead of failing later with a confusing message.
    private const val COMPOSE_RESOLVE =
        "OT_CR=$CR; " +
        "if [ -n \"\$OT_CR\" ] && \"\$OT_CR\" --version 2>/dev/null | grep -qi podman; then " +
            "if command -v podman-compose >/dev/null 2>&1; then OT_COMPOSE=\"podman-compose\"; " +
            "elif \"\$OT_CR\" compose version >/dev/null 2>&1; then OT_COMPOSE=\"\$OT_CR compose\"; " +
            "else echo 'No Podman Compose provider found on host' >&2; exit 1; fi; " +
        "elif [ -n \"\$OT_CR\" ]; then " +
            "if \"\$OT_CR\" compose version >/dev/null 2>&1; then OT_COMPOSE=\"\$OT_CR compose\"; " +
            "elif command -v docker-compose >/dev/null 2>&1; then OT_COMPOSE=\"docker-compose\"; " +
            "else echo 'No Docker Compose found on host' >&2; exit 1; fi; " +
        "elif command -v docker-compose >/dev/null 2>&1; then OT_COMPOSE=\"docker-compose\"; " +
        "elif command -v podman-compose >/dev/null 2>&1; then OT_COMPOSE=\"podman-compose\"; " +
        "else echo 'No docker/podman compose found on host' >&2; exit 1; fi"

    private fun runtimeCommand(runtime: String): String = when (runtime.lowercase()) {
        "docker" -> "docker"
        "podman" -> "podman"
        else -> CR
    }

    private fun composeResolve(runtime: String): String = when (runtime.lowercase()) {
        "docker" ->
            "OT_CR=docker; " +
                "if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then OT_COMPOSE=\"docker compose\"; " +
                "elif command -v docker-compose >/dev/null 2>&1; then OT_COMPOSE=\"docker-compose\"; " +
                "else echo 'No Docker Compose found on host' >&2; exit 1; fi"
        "podman" ->
            "OT_CR=podman; " +
                "if command -v podman-compose >/dev/null 2>&1; then OT_COMPOSE=\"podman-compose\"; " +
                "elif command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then OT_COMPOSE=\"podman compose\"; " +
                "else echo 'No Podman Compose provider found on host' >&2; exit 1; fi"
        else -> COMPOSE_RESOLVE
    }

    // Tab-separated, no-trunc so parsing is unambiguous. Docker and Podman expose compose labels
    // through incompatible template syntaxes, so we branch on the runtime:
    //   • Docker's psReporter has a `.Label "key"` METHOD; its `.Labels` is a comma-joined string,
    //     so `index .Labels "key"` errors there ("cannot index slice/array with type string").
    //   • Podman's containers.psReporter has NO `.Label` method (the user-reported error
    //     `can't evaluate field Label in type containers.psReporter`); its `.Labels` IS a
    //     map[string]string, reachable via `index .Labels "key"`.
    private const val PS_FIELDS_DOCKER =
        "{{.ID}}\\t{{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.Ports}}\\t{{.Label \"com.docker.compose.project\"}}\\t{{.Label \"com.docker.compose.service\"}}\\t{{.Label \"com.docker.compose.project.working_dir\"}}\\t{{.Label \"com.docker.compose.project.config_files\"}}\\t{{.CreatedAt}}"
    private const val PS_FIELDS_PODMAN =
        "{{.ID}}\\t{{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.Ports}}\\t{{index .Labels \"com.docker.compose.project\"}}\\t{{index .Labels \"com.docker.compose.service\"}}\\t{{index .Labels \"com.docker.compose.project.working_dir\"}}\\t{{index .Labels \"com.docker.compose.project.config_files\"}}\\t{{.CreatedAt}}"
    /**
     * POSIX `sh` snippet defining `ot <seconds> <cmd...>`: run a command with a hard deadline.
     *
     * Remote hosts are not vanilla. A stale NFS/CIFS mount makes `df`/`du` block forever rather than
     * error, because the mount is unreachable rather than absent. A Docker or Podman socket that
     * accepts connections but never answers hangs `docker ps` the same way, as does a degraded
     * systemd for `systemctl`. None of these return, so a probe that runs them unbounded never
     * finishes and the app sits on a spinner with nothing to report.
     *
     * `timeout` is in coreutils and BusyBox, so it is present almost everywhere; a host without it
     * simply runs the command unbounded, which is the old behaviour rather than a new failure.
     * POSIX only: no arrays, no `${@:2}`, so dash/ash/BusyBox all accept it.
     */
    const val OT_HELPER =
        "ot(){ n=\$1; shift; if command -v timeout >/dev/null 2>&1; then timeout \"\$n\" \"\$@\"; else \"\$@\"; fi; }; "

    const val DOCKER_PS =
        OT_HELPER +
        "found=0; " +
        "if command -v docker >/dev/null 2>&1 && ot 10 docker ps >/dev/null 2>&1; then found=1; ot 15 docker ps -a --no-trunc --format 'docker\\t$PS_FIELDS_DOCKER'; fi; " +
        "if command -v podman >/dev/null 2>&1 && ot 10 podman ps >/dev/null 2>&1; then found=1; ot 15 podman ps -a --no-trunc --format 'podman\\t$PS_FIELDS_PODMAN'; fi; " +
        "if [ \"\$found\" = 0 ]; then if $CR --version | grep -qi podman; then $CR ps -a --no-trunc --format 'podman\\t$PS_FIELDS_PODMAN'; else $CR ps -a --no-trunc --format 'docker\\t$PS_FIELDS_DOCKER'; fi; fi"

    // One line per usable container runtime on the host ("docker" / "podman"). Gated on `ps`
    // actually answering — a binary whose daemon/socket the user can't reach doesn't count —
    // matching how DOCKER_PS decides which runtimes to query. Drives the compose-builder runtime
    // picker when a host has both.
    const val DOCKER_RUNTIMES =
        OT_HELPER +
        "if command -v docker >/dev/null 2>&1 && ot 10 docker ps >/dev/null 2>&1; then echo docker; fi; " +
        "if command -v podman >/dev/null 2>&1 && ot 10 podman ps >/dev/null 2>&1; then echo podman; fi"

    // Per-container restart counts, keyed by container ID. Docker and Podman name the inspect ID
    // placeholder differently: Docker's template field is `.Id`, Podman's is `.ID` (its inspect
    // JSON prints "Id" but the Go-template struct field is `ID`, so `.Id` errors with
    // `can't evaluate field Id`). `.RestartCount` is identical on both. Branch like DOCKER_PS.
    const val DOCKER_RESTARTS =
        OT_HELPER +
        "if command -v docker >/dev/null 2>&1 && ot 10 docker ps >/dev/null 2>&1; then ids=\$(docker ps -aq); [ -n \"\$ids\" ] && docker inspect --format 'docker\\t{{.Id}}\\t{{.RestartCount}}' \$ids 2>/dev/null || true; fi; " +
        "if command -v podman >/dev/null 2>&1 && ot 10 podman ps >/dev/null 2>&1; then ids=\$(podman ps -aq); [ -n \"\$ids\" ] && podman inspect --format 'podman\\t{{.ID}}\\t{{.RestartCount}}' \$ids 2>/dev/null || true; fi"

    const val DOCKER_IMAGES =
        OT_HELPER +
        "found=0; " +
        "if command -v docker >/dev/null 2>&1 && ot 10 docker ps >/dev/null 2>&1; then found=1; ot 15 docker images --no-trunc --format 'docker\\t{{.ID}}\\t{{.Repository}}\\t{{.Tag}}\\t{{.Size}}\\t{{.CreatedSince}}'; fi; " +
        "if command -v podman >/dev/null 2>&1 && ot 10 podman ps >/dev/null 2>&1; then found=1; ot 15 podman images --no-trunc --format 'podman\\t{{.ID}}\\t{{.Repository}}\\t{{.Tag}}\\t{{.Size}}\\t{{.CreatedSince}}'; fi; " +
        "if [ \"\$found\" = 0 ]; then if $CR --version | grep -qi podman; then $CR images --no-trunc --format 'podman\\t{{.ID}}\\t{{.Repository}}\\t{{.Tag}}\\t{{.Size}}\\t{{.CreatedSince}}'; else $CR images --no-trunc --format 'docker\\t{{.ID}}\\t{{.Repository}}\\t{{.Tag}}\\t{{.Size}}\\t{{.CreatedSince}}'; fi; fi"

    // Tab-separated: name \t driver \t mountpoint \t size \t links. Three layered fallbacks so we
    // get sizes where the runtime supports them and still list volumes where it doesn't:
    //   1. `system df -v --format` Go template — works on Docker and recent Podman (size + links).
    //   2. Podman text `system df -v` — column-parse the "Local Volumes" section, whose rows are
    //      "VOLUME NAME / LINKS / SIZE". A tiny state machine pins the section: enter on the
    //      "Local Volumes ..." heading, arm on the "VOLUME NAME ..." column header, then read data
    //      rows until a blank line or the next "<Header>:" line. Arming on the column header is what
    //      stops the blank line that sits *between* the heading and the header from ending us early.
    //      Podman prints sizes as a single token (e.g. "1.234GB", "0B"), so $1=name, $2=links,
    //      $3=size maps cleanly. Volume names with spaces are out of scope (extremely rare).
    //   3. `volume ls` template — always available; no size/links, but the list is still correct.
    const val DOCKER_VOLUMES =
        OT_HELPER +
        "ot_vols() { rt=\"\$1\"; \"\$rt\" system df -v --format '{{range .Volumes}}{{.Name}}\\t{{.Driver}}\\t{{.Mountpoint}}\\t{{.Size}}\\t{{.Links}}\\n{{end}}' 2>/dev/null " +
        "|| \"\$rt\" system df -v 2>/dev/null | awk '" +
            "/^Local Volumes/ { f=1; seen=0; next } " +                       // enter the section
            "f && \\$1==\"VOLUME\" && \\$2==\"NAME\" { seen=1; next } " +      // arm on column header
            "f && seen && /^[[:space:]]*$/ { f=0; next } " +                  // blank line ends it
            "f && seen && /^[A-Za-z].*:/ { f=0 } " +                          // next \"Header:\" ends it
            "f && seen && NF>=3 { print \\$1 \"\\tlocal\\t\\t\" \\$3 \"\\t\" \\$2 }' " +
        "|| \"\$rt\" volume ls --format '{{.Name}}\\t{{.Driver}}\\t{{.Mountpoint}}\\t\\t'; }; " +
        "found=0; if command -v docker >/dev/null 2>&1 && ot 10 docker ps >/dev/null 2>&1; then found=1; ot_vols docker | sed 's/^/docker\\t/'; fi; " +
        "if command -v podman >/dev/null 2>&1 && ot 10 podman ps >/dev/null 2>&1; then found=1; ot_vols podman | sed 's/^/podman\\t/'; fi; " +
        "if [ \"\$found\" = 0 ]; then if $CR --version | grep -qi podman; then ot_vols $CR | sed 's/^/podman\\t/'; else ot_vols $CR | sed 's/^/docker\\t/'; fi; fi"

    const val DOCKER_NETWORKS =
        OT_HELPER +
        "found=0; " +
        "if command -v docker >/dev/null 2>&1 && ot 10 docker ps >/dev/null 2>&1; then found=1; ot 15 docker network ls --format 'docker\\t{{.ID}}\\t{{.Name}}\\t{{.Driver}}' 2>/dev/null; fi; " +
        "if command -v podman >/dev/null 2>&1 && ot 10 podman ps >/dev/null 2>&1; then found=1; ot 15 podman network ls --format 'podman\\t{{.ID}}\\t{{.Name}}\\t{{.Driver}}' 2>/dev/null; fi; " +
        "if [ \"\$found\" = 0 ]; then if $CR --version | grep -qi podman; then $CR network ls --format 'podman\\t{{.ID}}\\t{{.Name}}\\t{{.Driver}}'; else $CR network ls --format 'docker\\t{{.ID}}\\t{{.Name}}\\t{{.Driver}}'; fi; fi"

    // ── Remote OS detection ──
    // Cheap one-shot probe run once per host (result cached in AppViewModel). POSIX hosts answer
    // with `uname -s` (Linux/FreeBSD/Darwin); PowerShell/cmd hosts have no `uname`, so the
    // `|| echo Windows` fallback fires.
    const val OS_PROBE = "uname -s 2>/dev/null || echo Windows"

    /** Marks the end of `crontab -l` output so its exit status can be read alongside it. */
    const val CRON_EXIT_MARKER = "---OMNITERM-CRON-EXIT---"

    /**
     * Reads the login user's crontab, keeping stderr *and* the exit status.
     *
     * `crontab -l 2>/dev/null || true` collapses three different answers into one empty string:
     * this user has no crontab, this user is not allowed one, and this host has no cron at all.
     * The CRON tab then offers Add, and a save rewrites the whole file -- so a crontab the user was
     * never allowed to read would be replaced by a single line.
     */
    const val CRON_READ_COMMAND = "crontab -l 2>&1; printf '%s%s\n' '$CRON_EXIT_MARKER' \"\$?\""

    /** Marks where a sudo-elevated read's real content begins, after sudo's own chatter. */
    const val SUDO_OUTPUT_MARKER = "---OMNITERM-BEGIN---"

    // ── tmux persistent-session support ───────────────────────────────────────────────────────
    // A shell launched inside tmux survives an SSH drop: the remote process group stays attached to
    // the tmux server, so reconnecting re-attaches the *same* session (and any long-running command
    // keeps running). These helpers detect tmux and (with user confirmation) install it.

    /** Prints "yes" if tmux is on PATH, else "no". */
    const val TMUX_CHECK = "command -v tmux >/dev/null 2>&1 && echo yes || echo no"

    /**
     * The command run inside the interactive shell to enter a persistent session: attach to the
     * existing session [name] or create it if absent (`new-session -A`). `exec` replaces the login
     * shell so exiting tmux ends the shell cleanly. Guarded so a missing tmux doesn't strand the
     * user in a half-broken prompt — it just stays a normal shell. Each app shell uses a distinct
     * [name] so multiple persistent sessions to one host re-attach their own session on reconnect.
     */
    private fun tmuxSafeName(name: String) =
        name.filter { it.isLetterOrDigit() || it == '-' }.ifBlank { "omniterm" }

    /** Configure an existing session before the regular/control client attaches to it. */
    private fun tmuxExistingBootstrap(safe: String, historyLimit: Int): String {
        val limit = historyLimit.coerceIn(1_000, 50_000)
        return "command -v tmux >/dev/null 2>&1 && " +
            "tmux has-session -t $safe 2>/dev/null && " +
            "(tmux set-option -t $safe history-limit $limit >/dev/null 2>&1 || true) && " +
            // Touch scrolling is handled locally by the app. Keep tmux mouse mode off so normal
            // drags don't get captured by tmux copy-mode or terminal apps in surprising ways.
            "(tmux set-option -t $safe mouse off >/dev/null 2>&1 || true) && "
    }

    /** Atomically create a brand-new app-owned session; an existing same-name session is an error. */
    private fun tmuxCreateBootstrap(safe: String, historyLimit: Int): String {
        val limit = historyLimit.coerceIn(1_000, 50_000)
        return "command -v tmux >/dev/null 2>&1 && " +
            // history-limit applies only to newly created panes. One tmux invocation starts the
            // server, sets the global default, and creates the unique session. new-session fails
            // rather than attaching if another client somehow already owns this high-entropy name.
            "tmux start-server \\; set-option -g history-limit $limit \\; new-session -d -s $safe && " +
            "(tmux set-option -t $safe mouse off >/dev/null 2>&1 || true) && "
    }

    fun tmuxCreateAttachCommand(name: String, historyLimit: Int = 10_000): String {
        val safe = tmuxSafeName(name)
        return tmuxCreateBootstrap(safe, historyLimit) + "exec tmux attach-session -t $safe\n"
    }

    fun tmuxControlCreateAttachCommand(name: String, historyLimit: Int = 10_000): String {
        val safe = tmuxSafeName(name)
        return tmuxCreateBootstrap(safe, historyLimit) + "exec tmux -C attach-session -t $safe\n"
    }

    fun tmuxAttachCommand(name: String, historyLimit: Int = 10_000): String {
        // Defensive: only allow our own [a-z0-9-] names through into the shell command.
        val safe = tmuxSafeName(name)
        return tmuxExistingBootstrap(safe, historyLimit) + "exec tmux attach-session -t $safe\n"
    }

    /**
     * Attach in CONTROL MODE (`tmux -C`): tmux emits structured `%output` events carrying every
     * pane byte instead of rendering a client UI, so unseen output can never be collapsed into a
     * repaint (see [com.jetsetslow.omniterm.data.term.TmuxControlParser]). Single `-C`, not `-CC`
     * — the double form wraps the conversation in a DCS envelope for terminal-embedded clients.
     */
    fun tmuxControlAttachCommand(name: String, historyLimit: Int = 10_000): String {
        val safe = tmuxSafeName(name)
        return tmuxExistingBootstrap(safe, historyLimit) + "exec tmux -C attach-session -t $safe\n"
    }

    /** Active pane id of [name]'s current window, e.g. `%0` (side channel; control mode needs it to route %output). */
    fun tmuxActivePaneQuery(name: String): String =
        "tmux display-message -p -t ${tmuxSafeName(name)} '#{pane_id}' 2>/dev/null || true"

    /** Cursor position as `x y` (0-based) for the control-mode repaint seed. */
    fun tmuxCursorQuery(name: String): String =
        "tmux display-message -p -t ${tmuxSafeName(name)} '#{cursor_x} #{cursor_y}' 2>/dev/null || true"

    /**
     * Prints `1` when a full-screen TUI owns the pane's alternate screen, else `0`. Drives
     * touch-scroll routing: TUIs get PageUp/PageDown (they own their scrolling; the terminal
     * side has no history for them), plain shells keep the local-buffer scroll.
     */
    fun tmuxAlternateOnQuery(name: String): String =
        "tmux display-message -p -t ${tmuxSafeName(name)} '#{alternate_on}' 2>/dev/null || true"

    /** Cursor position for an exact pane id, avoiding an active-pane change between side queries. */
    fun tmuxPaneCursorQuery(paneId: String): String {
        val safe = paneId.takeIf { it.matches(Regex("%\\d+")) } ?: "%0"
        return "tmux display-message -p -t $safe '#{cursor_x} #{cursor_y}' 2>/dev/null || true"
    }

    /**
     * The VISIBLE screen with colours (no history, no -J join — literal rows). Control mode never
     * repaints on attach, so the client must paint the current pane content itself.
     */
    fun tmuxCaptureScreenCommand(name: String): String =
        "tmux capture-pane -p -e -t ${tmuxSafeName(name)} 2>/dev/null || true"

    /**
     * [tmuxCaptureScreenCommand] guarded on `#{alternate_on}`, for the REGULAR-attach pre-paint.
     *
     * While a full-screen TUI (Claude Code, vim, htop) owns the pane's alternate screen,
     * capture-pane returns that TUI's frame. Painting it into our NORMAL screen leaves the frame
     * sitting underneath once the TUI exits: tmux restores the shell screen with per-row `ESC[K`,
     * which erases only from the cursor column rightward, so every row longer than the new content
     * keeps a tail of TUI text. That is the "screen doesn't clear after exiting Claude" artifact.
     *
     * Empty output means "don't paint" — a regular attach makes tmux repaint the pane anyway, so
     * skipping costs nothing while the TUI is up. Same guard as [tmuxCaptureHistoryCommand].
     */
    fun tmuxCaptureScreenIfNoTuiCommand(name: String): String {
        val safe = tmuxSafeName(name)
        return "if [ \"\$(tmux display-message -p -t $safe '#{alternate_on}' 2>/dev/null)\" = 1 ]; " +
            "then :; else tmux capture-pane -p -e -t $safe 2>/dev/null; fi || true"
    }

    /** Visible screen for an exact pane id (control-mode atomic repaint). */
    fun tmuxCapturePaneScreenCommand(paneId: String): String {
        val safe = paneId.takeIf { it.matches(Regex("%\\d+")) } ?: "%0"
        return "tmux capture-pane -p -e -t $safe 2>/dev/null || true"
    }

    fun tmuxHasSessionCommand(name: String): String {
        val safe = name.filter { it.isLetterOrDigit() || it == '-' }.ifBlank { "omniterm" }
        return "tmux has-session -t $safe >/dev/null 2>&1 && echo yes || echo no"
    }

    fun tmuxKillCommand(name: String): String {
        val safe = name.filter { it.isLetterOrDigit() || it == '-' }.ifBlank { "omniterm" }
        return "tmux kill-session -t $safe 2>/dev/null"
    }

    /** Clear only the active pane's server-side history; the visible screen remains intact. */
    fun tmuxClearHistoryCommand(name: String): String =
        "tmux clear-history -t ${tmuxSafeName(name)} 2>/dev/null || true"

    /**
     * Dump the pane's scrollback history (colours preserved via -e, wrapped lines re-joined via
     * -J) so a re-attaching client can seed its local buffer with the real tmux history. `-E -1`
     * stops at the last history line ABOVE the visible screen — the attach repaint provides the
     * screen itself, so including it here would duplicate a screenful at the boundary. Fails
     * silently (empty output) when the session or history doesn't exist.
     *
     * Guarded on `#{alternate_on}`: while a full-screen TUI owns the pane's alternate screen,
     * capture-pane returns TUI frames instead of the primary screen's history (verified on tmux
     * 3.3a), which would seed/replace local scrollback with stale TUI junk. Empty output makes
     * callers keep their dirty flag armed and retry after the TUI exits.
     */
    fun tmuxCaptureHistoryCommand(name: String, maxLines: Int): String {
        val safe = name.filter { it.isLetterOrDigit() || it == '-' }.ifBlank { "omniterm" }
        val lines = maxLines.coerceIn(1_000, 50_000)
        return "if [ \"\$(tmux display-message -p -t $safe '#{alternate_on}' 2>/dev/null)\" = 1 ]; " +
            "then :; else tmux capture-pane -p -e -J -S -$lines -E -1 -t $safe 2>/dev/null; fi || true"
    }

    /**
     * Exit copy-mode in [name]'s active pane (snaps it back to the live tail). Sent over a side
     * exec channel rather than typing the copy-mode cancel key into the PTY: if the pane already
     * left copy-mode (tmux exits it itself when wheel-scrolled back to the bottom), a typed `q`
     * would land at the shell prompt as a literal letter. Harmless no-op outside copy-mode.
     */
    fun tmuxExitCopyModeCommand(name: String): String {
        val safe = name.filter { it.isLetterOrDigit() || it == '-' }.ifBlank { "omniterm" }
        return "tmux send-keys -X -t $safe cancel 2>/dev/null || true"
    }

    /** Bound for a package-index refresh. Long enough for a slow mirror, short enough to report. */
    const val PM_UPDATE_SECONDS = 180

    /** Bound for the install itself; well under the transport's 30-minute stream cap. */
    const val PM_INSTALL_SECONDS = 600

    /**
     * Best-effort, distro-agnostic tmux install. Tries each common package manager in turn; uses
     * sudo when not already root. Combined stdout/stderr is surfaced to the user. [sudoPassword] is
     * fed via stdin to `sudo -S` by the caller (never interpolated into the command string).
     */
    fun tmuxInstallCommand(): String =
        "set -e; if command -v tmux >/dev/null 2>&1; then echo 'tmux already installed'; exit 0; fi; " +
        "if [ \"\$(id -u)\" = 0 ]; then SUDO=; else SUDO='sudo -S'; fi; " +
        // Every package step is bounded and explains a timeout in its own words. A dpkg/apt or dnf
        // lock held by unattended-upgrades blocks forever; the transport would eventually cut the
        // stream at STREAM_TIMEOUT_MS and the user would see a bare "command timed out" half an hour
        // later, with nothing saying a lock was the reason or that nothing had been installed.
        "pm(){ n=\$1; shift; s=0; " +
        "if command -v timeout >/dev/null 2>&1; then timeout \"\$n\" \"\$@\" || s=\$?; else \"\$@\" || s=\$?; fi; " +
        "if [ \"\$s\" = 124 ]; then " +
        "echo \"OmniTerm: \$* did not finish within \${n}s. Another package manager is most likely " +
        "holding the lock (unattended-upgrades, an interrupted install, or a stale lock file). " +
        "Nothing was installed - retry once that finishes.\" >&2; fi; return \"\$s\"; }; " +
        "if command -v apt-get >/dev/null 2>&1; then pm $PM_UPDATE_SECONDS \$SUDO apt-get update && pm $PM_INSTALL_SECONDS \$SUDO apt-get install -y tmux; " +
        "elif command -v dnf >/dev/null 2>&1; then pm $PM_INSTALL_SECONDS \$SUDO dnf install -y tmux; " +
        "elif command -v yum >/dev/null 2>&1; then pm $PM_INSTALL_SECONDS \$SUDO yum install -y tmux; " +
        "elif command -v pacman >/dev/null 2>&1; then pm $PM_INSTALL_SECONDS \$SUDO pacman -Sy --noconfirm tmux; " +
        "elif command -v apk >/dev/null 2>&1; then pm $PM_INSTALL_SECONDS \$SUDO apk add tmux; " +
        "elif command -v zypper >/dev/null 2>&1; then pm $PM_INSTALL_SECONDS \$SUDO zypper install -y tmux; " +
        "elif command -v pkg >/dev/null 2>&1; then pm $PM_INSTALL_SECONDS \$SUDO pkg install -y tmux; " +
        "else echo 'No supported package manager found; install tmux manually.' >&2; exit 1; fi; " +
        "command -v tmux >/dev/null 2>&1 && echo 'tmux installed' || { echo 'tmux install failed' >&2; exit 1; }"

    /** Normalise raw [OS_PROBE] output to a family token used to pick command/parse variants. */
    fun normaliseOs(raw: String): String {
        val s = raw.trim().lineSequence().firstOrNull { it.isNotBlank() }?.trim().orEmpty()
        return when {
            s.startsWith("Linux", true) -> "Linux"
            s.startsWith("FreeBSD", true) || s.startsWith("OpenBSD", true) ||
                s.startsWith("NetBSD", true) || s.startsWith("DragonFly", true) -> "FreeBSD"
            s.startsWith("Darwin", true) -> "Darwin"
            s.contains("Windows", true) || s.contains("not recognized", true) ||
                s.contains("CommandNotFound", true) -> "Windows"
            // Empty (missing @OS section) or unknown Unix-like → Linux, the safest superset.
            else -> "Linux"
        }
    }

    /** Per-OS host-metrics probe. */
    fun metricsFor(os: String): String = when (normaliseOs(os)) {
        "FreeBSD" -> METRICS_BSD
        "Darwin" -> METRICS_DARWIN
        "Windows" -> METRICS_WINDOWS
        else -> METRICS
    }

    /** Per-OS process list (top by CPU). */
    fun processesFor(os: String): String = when (normaliseOs(os)) {
        "Windows" -> PROCESSES_WINDOWS
        "FreeBSD", "Darwin" -> PROCESSES_BSD
        else -> PROCESSES
    }

    // Linux: pid,user,%cpu,%mem,vsz,etime,stat,comm (etime adds per-process uptime). The `ps`
    // header line is dropped by the parser (non-numeric pid). BusyBox ps has no -eo, so fall back
    // to its plain 4-column output (PID USER TIME COMMAND), which the parser also understands.
    const val PROCESSES =
        "ps -eo pid,user,%cpu,%mem,vsz,etime,stat,comm 2>/dev/null | sort -k3 -rn | head -n 80" +
        " || ps w 2>/dev/null | head -n 80"

    // FreeBSD/macOS BSD ps: same 8 columns via -axo (keywords differ slightly).
    const val PROCESSES_BSD =
        "ps -axo pid,user,pcpu,pmem,vsz,etime,state,comm 2>/dev/null | sort -k3 -rn | head -n 80"

    // Windows: emulate the same 8 space-separated columns (pid user %cpu %mem vsz etime stat comm),
    // sorted by CPU. ProcessName has no spaces so the simple split holds.
    val PROCESSES_WINDOWS =
        "powershell -NoProfile -Command \"Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | " +
            "Where-Object { \$_.IDProcess -ne 0 } | Sort-Object PercentProcessorTime -Descending | " +
            "Select-Object -First 80 | ForEach-Object { \$_.IDProcess.ToString() + ' NA ' + " +
            "\$_.PercentProcessorTime + ' 0 ' + [int](\$_.WorkingSetPrivate/1024) + ' 00:00:00 R ' + \$_.Name }\""

    // Detect the init system instead of assuming systemd: OpenRC hosts (Alpine, Gentoo) get
    // rc-status output (marked so the parser switches format); other inits return a marker the
    // UI can turn into an explanation instead of a silently blank tab.
    const val SERVICES =
        OT_HELPER +
        "if command -v systemctl >/dev/null 2>&1; then " +
        "{ ot 15 systemctl list-units --type=service --all --no-pager --no-legend --plain; " +
        "echo '---ENABLED---'; ot 15 systemctl list-unit-files --type=service --no-pager --no-legend --plain 2>/dev/null; }; " +
        "elif command -v rc-status >/dev/null 2>&1; then echo '---OPENRC---'; rc-status -a 2>/dev/null; " +
        "else echo '---NOSYSTEMD---'; fi"

    /**
     * Host logs. `journalctl` only exists on systemd hosts, so fall through the same way [SERVICES]
     * does rather than returning silently-empty output on Alpine/OpenWrt/BSD/macOS: syslog-style
     * files, then OpenWrt's `logread`, then a marker the UI turns into an explanation.
     */
    fun journal(lines: Int = 300, os: String = "") = when (normaliseOs(os)) {
        "Windows" -> journalWindows(lines)
        "Darwin" ->
            "log show --last 1h --style syslog 2>/dev/null | tail -n $lines || " +
                "echo '---NOLOGS---'"
        else ->
            // Each source is tried until one actually PRODUCES output, rather than stopping at the
            // first one that merely exists. A BusyBox host ships `logread` whether or not syslogd is
            // running, and when it is not, `logread` fails to stderr -- swallowed by 2>/dev/null --
            // and exits. The old `elif` chain stopped there, printed nothing, and never reached the
            // ---NOLOGS--- marker, so the Logs tab showed an empty pane with no explanation on most
            // containers. Found by running the Flutter port against a real Alpine host.
            OT_HELPER +
                "L=\"\"; " +
                "if command -v journalctl >/dev/null 2>&1; then " +
                "L=\$(ot 20 journalctl -n $lines --no-pager -o short-iso 2>/dev/null); fi; " +
                "if [ -z \"\$L\" ] && command -v logread >/dev/null 2>&1; then " +
                "L=\$(logread 2>/dev/null | tail -n $lines); fi; " +
                "if [ -z \"\$L\" ] && [ -r /var/log/messages ]; then " +
                "L=\$(tail -n $lines /var/log/messages 2>/dev/null); fi; " +
                "if [ -z \"\$L\" ] && [ -r /var/log/syslog ]; then " +
                "L=\$(tail -n $lines /var/log/syslog 2>/dev/null); fi; " +
                "if [ -z \"\$L\" ]; then echo '---NOLOGS---'; else printf '%s\\n' \"\$L\"; fi"
    }

    private fun journalWindows(lines: Int) =
        "powershell -NoProfile -Command \"Get-WinEvent -LogName System -MaxEvents $lines | " +
            "ForEach-Object { \$_.TimeCreated.ToString('yyyy-MM-ddTHH:mm:ssK') + ' ' + " +
            "\$_.ProviderName + ': ' + \$_.Message }\""

    /**
     * Wrap a command so it runs under sudo. When [sudoPassword] is non-blank we use `sudo -S`,
     * which reads the password from the exec channel's stdin — the caller must pass
     * [sudoStdin] of the same password to the transport so the password NEVER appears in the
     * command string (and therefore never in `ps`, auditd execve records, or sshd debug logs).
     * Otherwise we fall back to the non-interactive `sudo -n` behaviour. The password is never
     * echoed back: `-p ''` suppresses the prompt. Caller passes the command WITHOUT a leading
     * `sudo`.
     */
    fun sudoWrap(cmd: String, sudoPassword: String): String =
        if (sudoPassword.isNotBlank()) {
            "sudo -S -p '' $cmd 2>&1"
        } else {
            "sudo -n $cmd 2>&1"
        }

    /**
     * Run a whole shell [script] under sudo. Unlike [sudoWrap] (which only elevates the first
     * command — `sudo a && b` runs `b` as the normal user), this elevates the entire script via
     * `sudo sh -c '<script>'`, so chained operations (`cp … && rm …`) all run as root. Used by the
     * SFTP "sudo mode" for copy/move/delete/mkdir/rename and for reading/writing protected files.
     * As with [sudoWrap], the password travels via [sudoStdin], not the command string.
     */
    fun sudoShWrap(script: String, sudoPassword: String): String =
        if (sudoPassword.isNotBlank()) {
            "sudo -S -p '' sh -c ${shellQuote(script)} 2>&1"
        } else {
            "sudo -n sh -c ${shellQuote(script)} 2>&1"
        }

    /**
     * The stdin payload that pairs with [sudoWrap]/[sudoShWrap]: the sudo password plus the
     * newline `sudo -S` waits for, or null when no password is configured (NOPASSWD hosts).
     * None of the wrapped scripts read stdin themselves, so the line is consumed only by sudo.
     */
    /**
     * Reads a file as root, with a marker separating sudo's own output from the file's.
     *
     * On sudo's first use in a session it prints its lecture, and `sudoShWrap` merges stderr into
     * stdout -- so without this the lecture is prepended to the file, lands in the editor, and is
     * written back on save. The marker also distinguishes an empty file from a refusal: no marker
     * means sudo said no, and the raw output is the explanation.
     */
    fun sudoReadCommand(path: String, sudoPassword: String): String =
        sudoShWrap("printf '%s\\n' '$SUDO_OUTPUT_MARKER'; cat -- ${shellQuote(path)}", sudoPassword)

    fun sudoStdin(sudoPassword: String): String? =
        if (sudoPassword.isNotBlank()) sudoPassword + "\n" else null

    fun serviceAction(name: String, action: String, sudoPassword: String = ""): String {
        val quotedName = shellQuote(name)
        val openRc = when (action) {
            "start", "stop", "restart", "status" -> "rc-service $quotedName $action"
            "enable" -> "rc-update add $quotedName default"
            "disable" -> "rc-update delete $quotedName -a"
            else -> "rc-service $quotedName $action"
        }
        val script =
            "if command -v systemctl >/dev/null 2>&1; then systemctl $action $quotedName; " +
            "elif command -v rc-service >/dev/null 2>&1; then $openRc; " +
            "else echo 'No supported service manager found' >&2; exit 1; fi"
        return sudoShWrap(script, sudoPassword)
    }

    /** Reboot the host: try sudo first, then a bare `reboot` (already root / NOPASSWD wrappers). */
    fun reboot(sudoPassword: String = "") =
        "${sudoWrap("reboot", sudoPassword)} || reboot 2>&1"

    fun dockerAction(id: String, action: String, runtime: String = ""): String {
        val cr = runtimeCommand(runtime)
        val verb = when (action) {
            "remove" -> "rm -f"
            else -> action // start | stop | restart | pause | unpause
        }
        return "$cr $verb ${shellQuote(id)} 2>&1"
    }

    fun dockerImageAction(id: String, action: String, runtime: String = ""): String {
        val cr = runtimeCommand(runtime)
        val verb = when (action) {
            "remove" -> "rmi -f"
            else -> action
        }
        return "$cr $verb ${shellQuote(id)} 2>&1"
    }

    fun dockerVolumeAction(name: String, action: String, runtime: String = ""): String {
        val cr = runtimeCommand(runtime)
        val verb = when (action) {
            "remove" -> "volume rm -f"
            else -> action
        }
        return "$cr $verb ${shellQuote(name)} 2>&1"
    }

    fun dockerNetworkAction(id: String, action: String, runtime: String = ""): String {
        val cr = runtimeCommand(runtime)
        val verb = when (action) {
            "remove" -> "network rm"
            else -> action
        }
        return "$cr $verb ${shellQuote(id)} 2>&1"
    }

    fun dockerPruneImages() = OT_HELPER + "{ command -v docker >/dev/null 2>&1 && ot 10 docker ps >/dev/null 2>&1 && docker image prune -a -f; true; } 2>&1; { command -v podman >/dev/null 2>&1 && ot 10 podman ps >/dev/null 2>&1 && podman image prune -a -f; true; } 2>&1"

    // `volume prune -f` removes only anonymous unused volumes on current Docker and Podman.
    // `-a/--all` prunes unused named volumes too, matching the UI's "unused volumes" wording.
    fun dockerPruneVolumes() = OT_HELPER + "{ command -v docker >/dev/null 2>&1 && ot 10 docker ps >/dev/null 2>&1 && docker volume prune -a -f; true; } 2>&1; { command -v podman >/dev/null 2>&1 && ot 10 podman ps >/dev/null 2>&1 && podman volume prune -a -f; true; } 2>&1"

    fun dockerPruneNetworks() = OT_HELPER + "{ command -v docker >/dev/null 2>&1 && ot 10 docker ps >/dev/null 2>&1 && docker network prune -f; true; } 2>&1; { command -v podman >/dev/null 2>&1 && ot 10 podman ps >/dev/null 2>&1 && podman network prune -f; true; } 2>&1"

    fun dockerLogs(id: String, runtime: String = "") = "${runtimeCommand(runtime)} logs --tail 200 ${shellQuote(id)} 2>&1"

    /**
     * One-shot resource stats for a single container. `--no-stream` prints one sample and exits;
     * the tab-separated format keeps parsing trivial (CPU%, mem usage/limit, mem%, net I/O, block I/O, PIDs).
     */
    fun dockerStats(id: String, runtime: String = ""): String =
        "${runtimeCommand(runtime)} stats --no-stream --format " +
            "'{{.CPUPerc}}\\t{{.MemUsage}}\\t{{.MemPerc}}\\t{{.NetIO}}\\t{{.BlockIO}}\\t{{.PIDs}}' ${shellQuote(id)} 2>&1"

    /**
     * The command to run inside the terminal to exec an interactive shell in a container. Tries
     * bash, falls back to sh — the common pattern for minimal images. Runs as the container's
     * default user; the terminal PTY drives it interactively.
     */
    fun dockerExecShell(id: String, runtime: String = ""): String =
        "${runtimeCommand(runtime)} exec -it ${shellQuote(id)} sh -c 'exec bash 2>/dev/null || exec sh'"

    // ── Archive create / extract over the SFTP host's shell ──

    /**
     * Create [archiveName] inside [dir] from [entries] (names relative to [dir]). [format] is one of
     * "zip", "tar.gz", "tar", "7z". `cd` into the dir first so stored paths stay relative. For zip we
     * recurse (-r); tar handles dirs natively. 7z needs a 7-Zip binary on the host (7z/7zz/7za are
     * tried in turn); its stdout chatter is suppressed so success stays quiet like zip/tar. RAR
     * creation is deliberately absent — the `rar` compressor is proprietary and almost never
     * installed. Combined stderr is returned.
     */
    fun archiveCreate(dir: String, archiveName: String, entries: List<String>, format: String): String {
        val names = entries.joinToString(" ") { shellQuote(it) }
        val out = shellQuote(archiveName)
        val body = when (format) {
            "zip" -> "zip -r -q $out $names"
            "tar" -> "tar -cf $out $names"
            "7z" -> sevenZipInvocation("a -y $out $names")
            else -> "tar -czf $out $names"   // tar.gz default
        }
        return "cd ${shellQuote(dir)} && $body 2>&1"
    }

    /** Run the first available 7-Zip binary with [args], or fail with a clear stderr message. */
    private fun sevenZipInvocation(args: String): String =
        "if command -v 7z >/dev/null 2>&1; then 7z $args >/dev/null; " +
            "elif command -v 7zz >/dev/null 2>&1; then 7zz $args >/dev/null; " +
            "elif command -v 7za >/dev/null 2>&1; then 7za $args >/dev/null; " +
            "else echo '7-Zip is not installed on the host' >&2; false; fi"

    /**
     * Extract [archiveName] (in [dir]) into a subfolder of the same name (minus extension) so a
     * messy archive can't scatter files across the current folder. Auto-detects by extension.
     * zip/tar variants use tools present on virtually every host; .7z and .rar depend on optional
     * tools (7z/7zz/7za, unrar with a bsdtar fallback) and fail with a clear message when absent.
     */
    fun archiveExtract(dir: String, archiveName: String): String {
        val base = archiveName
            .removeSuffix(".zip").removeSuffix(".tar.gz").removeSuffix(".tgz")
            .removeSuffix(".tar.bz2").removeSuffix(".tbz2")
            .removeSuffix(".tar.xz").removeSuffix(".txz")
            .removeSuffix(".7z").removeSuffix(".rar").removeSuffix(".tar")
        val a = shellQuote(archiveName)
        val destQuoted = shellQuote(base)
        val lower = archiveName.lowercase()
        val extract = when {
            lower.endsWith(".zip") -> "unzip -o -q $a -d $destQuoted"
            lower.endsWith(".tar.gz") || lower.endsWith(".tgz") -> "tar -xzf $a -C $destQuoted"
            lower.endsWith(".tar.bz2") || lower.endsWith(".tbz2") -> "tar -xjf $a -C $destQuoted"
            lower.endsWith(".tar.xz") || lower.endsWith(".txz") -> "tar -xJf $a -C $destQuoted"
            lower.endsWith(".tar") -> "tar -xf $a -C $destQuoted"
            lower.endsWith(".7z") -> sevenZipInvocation("x -y -o$destQuoted $a")
            lower.endsWith(".rar") ->
                "if command -v unrar >/dev/null 2>&1; then unrar x -o+ $a $destQuoted/ >/dev/null; " +
                    "elif command -v bsdtar >/dev/null 2>&1; then bsdtar -xf $a -C $destQuoted; " +
                    "else echo 'unrar (or bsdtar) is not installed on the host' >&2; false; fi"
            else -> "echo 'Unsupported archive type' >&2; false"
        }
        return "cd ${shellQuote(dir)} && mkdir -p $destQuoted && $extract 2>&1"
    }

    fun dockerComposeAction(project: String, workingDir: String, configFiles: String, action: String, service: String? = null, replicas: Int? = null, removeOrphans: Boolean = false, runtime: String = ""): String {
        val flags = composeFlags(project, configFiles)
        val orphansFlag = if (removeOrphans) " --remove-orphans" else ""
        val resolver = composeResolve(runtime)

        // "update" is multi-step and must stay guarded by the `cd`, so it builds its own tail rather
        // than plugging a single verb into the shared `$OT_COMPOSE $flags <verb>` template below.
        // Steps: pull registry images (skipping buildable services; non-fatal so a login hiccup can't
        // block the build), then `build --pull` to (re)build Dockerfile images + refresh their bases,
        // then `up -d` to recreate, then `ps`. build/up/ps are `&&`-chained so a real failure exits
        // non-zero; the whole tail runs only after `cd` succeeds.
        if (action == "update") {
            val c = "\$OT_COMPOSE $flags"
            val tail = "{ $c pull --ignore-buildable 2>/dev/null || $c pull 2>/dev/null || true; } && " +
                "$c build --pull && $c up -d$orphansFlag && $c ps"
            return "$resolver && cd ${shellQuote(workingDir)} && $tail 2>&1"
        }

        val verb = when (action) {
            // Build (and refresh base images) without pulling registry images or recreating.
            "build" -> "build --pull"
            "pull" -> "pull"
            "down" -> "down$orphansFlag"
            "up" -> "up -d$orphansFlag"
            "forceRecreate" -> "up -d --force-recreate$orphansFlag"
            "restart" -> "restart"
            "logs" -> "logs --tail 200"
            "followLogs" -> "logs -f --tail 100"
            "config" -> "config"
            "ps" -> "ps"
            "serviceLogs" -> "logs --tail 200 ${shellQuote(service.orEmpty())}"
            "serviceRestart" -> "restart ${shellQuote(service.orEmpty())}"
            "serviceStop" -> "stop ${shellQuote(service.orEmpty())}"
            "serviceRemove" -> "rm -sf ${shellQuote(service.orEmpty())}"
            "scale" -> "up -d --scale ${shellQuote(service.orEmpty())}=${replicas?.coerceAtLeast(0) ?: 1}"
            "removeOrphans" -> "up -d --remove-orphans"
            else -> "ps"
        }
        // Resolve the compose entrypoint (docker/podman, builtin or standalone) before running.
        return "$resolver && cd ${shellQuote(workingDir)} && \$OT_COMPOSE $flags $verb 2>&1"
    }

    /**
     * Atomically deploy a compose file the visual builder produced. The flow is deliberately
     * fail-safe so a broken YAML can never replace a working stack:
     *   1. Resolve the compose entrypoint (docker/podman).
     *   2. Write the new YAML to a temp file (never the live file yet).
     *   3. Validate it with `compose config`. If it doesn't parse, abort — the live file and the
     *      running stack are untouched.
     *   4. Back up the current live file (if any) to `<name>.omniterm.bak`, move the temp file into
     *      place, and `up -d`.
     *   5. If `up -d` fails, restore the backup over the live file so the on-disk config matches the
     *      still-running (old) stack, and exit non-zero so the UI reports failure.
     *
     * [yamlBase64] is the new file contents, base64-encoded so arbitrary YAML survives the shell.
     */
    /**
     * [composeFilePath] is the ABSOLUTE path to the compose file to edit (e.g.
     * `/srv/example/docker-compose.yml`) — exactly the file Docker reported as the running
     * stack's config (`com.docker.compose.project.config_files`). We always operate on this exact
     * path and pass it with `-f`; we never `cd` into a directory and guess a relative file name,
     * because that can silently write to the wrong copy of a stack that exists in two places. The
     * temp/backup files are kept alongside it in the same directory.
     */
    fun composeDeploy(
        composeFilePath: String,
        project: String,
        yamlBase64: String,
        workingDir: String = "",
        configFiles: String = "",
        runtime: String = "",
    ): String {
        // Expand a leading ~ at runtime on the remote host; shell won't expand it inside single quotes.
        fun expandPath(p: String) = if (p.startsWith("~/")) "\$HOME/${shellQuote(p.removePrefix("~/"))}" else shellQuote(p)
        fun resolveConfigPath(p: String): String = when {
            p.startsWith("/") || p.startsWith("~/") -> p
            workingDir.isNotBlank() -> "${workingDir.trimEnd('/')}/$p"
            else -> p
        }
        fun flagsWithReplacement(replacement: String): String {
            val rawFiles = configFiles.split(',').map { it.trim() }.filter { it.isNotEmpty() }
            if (rawFiles.isEmpty()) return "-f $replacement -p ${shellQuote(project)}"
            var matched = false
            val flags = rawFiles.joinToString(" ") { raw ->
                val resolved = resolveConfigPath(raw)
                val flagPath = if (resolved == composeFilePath) {
                    matched = true
                    replacement
                } else {
                    expandPath(resolved)
                }
                "-f $flagPath"
            }
            val finalFlags = if (matched) flags else "-f $replacement $flags"
            return "$finalFlags -p ${shellQuote(project)}"
        }
        fun decodeBase64To(target: String): String =
            "{ printf '%s' ${shellQuote(yamlBase64)} | base64 -d > $target 2>/dev/null || " +
                "printf '%s' ${shellQuote(yamlBase64)} | base64 --decode > $target 2>/dev/null || " +
                "printf '%s' ${shellQuote(yamlBase64)} | base64 -D > $target; }"
        val file = expandPath(composeFilePath)
        val bak = expandPath("$composeFilePath.omniterm.bak")
        // Directory of the compose file, so `compose` runs with the right relative-path context
        // (build contexts, ./ volume mounts, env_file) exactly as the file intends.
        val rawDir = composeFilePath.substringBeforeLast('/').ifEmpty { "." }
        val dir = if (rawDir.startsWith("~/")) "\$HOME/${shellQuote(rawDir.removePrefix("~/"))}" else shellQuote(rawDir)
        val stagedFlags = flagsWithReplacement("\"\$tmp\"")
        val liveFlags = flagsWithReplacement(file)
        val resolver = composeResolve(runtime)
        return buildString {
            append(resolver)
            append(" && umask 077")
            append(" && mkdir -p $dir")
            append(" && tmp=\$(mktemp ${dir}/.omniterm-compose.XXXXXX)")
            append(" && err=\$(mktemp ${dir}/.omniterm-compose-err.XXXXXX)")
            append(" && trap 'rm -f \"\$tmp\" \"\$err\"' EXIT")
            append(" && { existed=0; [ -f $file ] && existed=1; true; }")
            // 2. stage the new contents next to the real file
            append(" && ${decodeBase64To("\"\$tmp\"")}")
            // 3. validate the staged file with -f (abs path); abort untouched on parse error.
            //    On failure: emit the compose error and bail. On success: still emit any warnings
            //    (missing env vars, duplicate networks, etc.) so they're visible in the deploy banner.
            append(" && { if ! \$OT_COMPOSE $stagedFlags config > /dev/null 2>\"\$err\"; then ")
            append("echo 'VALIDATION FAILED — stack unchanged:' >&2; cat \"\$err\" >&2; exit 1; fi; }")
            append(" && cat \"\$err\" 2>/dev/null || true")
            // 4. back up the live file, swap the validated one into its exact path
            append(" && { if [ -f $file ]; then cp $file $bak; fi; }")
            append(" && mv \"\$tmp\" $file")
            // 5. bring it up via the exact file path; on failure restore the backup and report non-zero
            append(" && { if ! \$OT_COMPOSE $liveFlags up -d 2>&1; then ")
            append("if [ \"\$existed\" = 1 ] && [ -f $bak ]; then echo 'DEPLOY FAILED — restoring previous compose file' >&2; mv $bak $file; ")
            append("else echo 'DEPLOY FAILED — removing new compose file' >&2; rm -f $file; fi; exit 1; fi; }")
            append(" && echo 'OMNITERM_DEPLOY_OK'")
        }
    }

    /**
     * Read a compose file for the builder by its ABSOLUTE path; prints a sentinel when absent so
     * the UI can tell. Always reads the exact file Docker reported, never a guessed relative path.
     */
    fun composeRead(composeFilePath: String): String {
        val path = if (composeFilePath.startsWith("~/")) "\$HOME/${shellQuote(composeFilePath.removePrefix("~/"))}" else shellQuote(composeFilePath)
        return "cat $path 2>/dev/null || echo OMNITERM_NO_FILE"
    }

    fun dockerComposeExecShellCommand(containerId: String, runtime: String = "") = "${runtimeCommand(runtime)} exec -it ${shellQuote(containerId)} sh"

    /**
     * Probe whether a registered (currently-down) stack's compose config still exists before
     * running `up` — the file can be deleted or moved behind the app's back, and compose's own
     * error for that is confusing. Prints OMNITERM_COMPOSE_OK when the recorded config chain is
     * intact. ALL recorded config files must exist (the `-f` chain fails if any is missing);
     * with no recorded files, ANY conventional compose file name in [workingDir] suffices,
     * matching what compose itself would pick up there.
     */
    fun composeConfigPresent(workingDir: String, configFiles: String): String {
        fun expand(p: String) = if (p.startsWith("~/")) "\"\$HOME\"/${shellQuote(p.removePrefix("~/"))}" else shellQuote(p)
        val dir = workingDir.trimEnd('/')
        val recorded = configFiles.split(',').map { it.trim() }.filter { it.isNotEmpty() }
            .map { if (it.startsWith("/") || it.startsWith("~/")) it else "$dir/$it" }
        val test = if (recorded.isNotEmpty()) {
            recorded.joinToString(" && ") { "[ -f ${expand(it)} ]" }
        } else {
            listOf("compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml")
                .joinToString(" || ") { "[ -f ${expand("$dir/$it")} ]" }
        }
        return "if { $test; } 2>/dev/null; then echo OMNITERM_COMPOSE_OK; else echo OMNITERM_COMPOSE_MISSING; fi"
    }

    private fun composeFlags(project: String, configFiles: String): String {
        val configFlags = configFiles
            .split(',')
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .joinToString(" ") { "-f ${shellQuote(it)}" }
        return listOf(configFlags, "-p ${shellQuote(project)}")
            .filter { it.isNotBlank() }
            .joinToString(" ")
    }

    /** Single round-trip host metrics probe (Linux). Sections delimited by @MARKER lines. */
    val METRICS = buildString {
        // Bound the commands that can block forever on a wedged filesystem.
        //
        // `df` walks every mount, and a stale NFS/CIFS mount makes it hang indefinitely rather than
        // error -- the mount is unreachable, not absent, so the kernel keeps waiting. `smartctl` can
        // stall the same way on a device that will not answer. Because this probe is one round trip,
        // a single wedged mount used to hang the *whole* metrics read, so the host sat on
        // "Checking host..." forever with no error until the remote machine was rebooted. Observed
        // on a host with two unreachable NFS4 mounts, where plain `df` never returned.
        //
        // `ot` is POSIX sh: no arrays, no `${@:2}`, works under dash/BusyBox. Hosts without
        // `timeout` (rare; it is in coreutils and BusyBox) simply run the command unbounded, which
        // is the old behaviour rather than a regression.
        append(OT_HELPER)
        append("echo '@OS'; uname -s 2>/dev/null || echo Linux; ")
        // Distro pretty-name so homelab OSes (Raspberry Pi OS, Ubuntu, Debian, Proxmox, OpenWrt,
        // Alpine, …) show by name instead of a bare "Linux".
        append("echo '@DISTRO'; (. /etc/os-release 2>/dev/null && printf '%s\\n' \"\$PRETTY_NAME\") || true; ")
        // Platform capabilities so platform-specific quick scripts only show on relevant hosts.
        append("echo '@PLATFORM'; ")
        append("command -v pveversion >/dev/null 2>&1 && echo proxmox; ")
        append("{ [ -d /etc/casaos ] || command -v casaos >/dev/null 2>&1; } && echo casaos; ")
        append("command -v ha >/dev/null 2>&1 && echo homeassistant; ")
        append("{ command -v vcgencmd >/dev/null 2>&1 || grep -qi raspberry /proc/cpuinfo 2>/dev/null; } && echo raspberry; ")
        append("command -v docker >/dev/null 2>&1 && echo docker; ")
        append("true; ")
        // CPU: grep the first line mentioning "cpu" so we catch GNU top ("%Cpu(s): ... 95.6 id")
        // and BusyBox top ("CPU: ... 98% idle") alike.
        append("echo '@CPU'; LANG=C top -bn1 2>/dev/null | grep -i 'cpu' | head -1 || true; ")
        append("echo '@MEM'; LANG=C free -b 2>/dev/null | grep -i '^Mem' || true; ")
        // /proc/meminfo fallback (kB) for BusyBox/Alpine where `free -b`/columns differ or are absent.
        append("echo '@MEMINFO'; grep -iE '^(MemTotal|MemFree|MemAvailable):' /proc/meminfo 2>/dev/null || true; ")
        // BusyBox df has no -B; fall back to -Pk with a KB1024 marker so the parser scales ×1024.
        // A section that cannot be collected emits `!UNAVAILABLE <reason>` instead of nothing, so
        // the UI can say *why* a metric is missing rather than implying the host has no disks. The
        // reason is written for a person reading a host card, not for a log.
        append("echo '@DISK'; d=\$(ot 5 df -PB1 / 2>/dev/null | tail -1); ")
        append("[ -z \"\$d\" ] && d=\$(ot 5 df -Pk / 2>/dev/null | tail -1 | sed 's/^/KB1024 /'); ")
        append("if [ -n \"\$d\" ]; then printf '%s\\n' \"\$d\"; ")
        append("else echo '!UNAVAILABLE df / did not answer within 5s'; fi; ")
        // All real filesystem mounts (capacity per partition); pseudo-fs are filtered when parsed.
        append("echo '@DISKS'; d=\$(ot 5 df -PB1 2>/dev/null | tail -n +2); ")
        append("[ -z \"\$d\" ] && d=\$(ot 5 df -Pk 2>/dev/null | tail -n +2 | sed 's/^/KB1024 /'); ")
        append("if [ -n \"\$d\" ]; then printf '%s\\n' \"\$d\"; ")
        append("else echo '!UNAVAILABLE df did not answer within 5s - an unreachable network mount (NFS/SMB) blocks it'; fi; ")
        append("echo '@LOAD'; cat /proc/loadavg 2>/dev/null || true; ")
        append("echo '@UP'; cat /proc/uptime 2>/dev/null || true; ")
        // Per-core CPU jiffies (rates computed from the delta between polls).
        append("echo '@STAT'; grep -E '^cpu[0-9]* ' /proc/stat 2>/dev/null || true; ")
        // CPU temperature (millidegrees); take the hottest thermal zone.
        append("echo '@TEMP'; t=\$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null); ")
        append("if [ -n \"\$t\" ]; then printf '%s\\n' \"\$t\"; ")
        append("else echo '!UNAVAILABLE this host exposes no thermal sensors'; fi; ")
        // Per-interface cumulative RX/TX bytes (rates computed from the delta between polls).
        append("echo '@NETDEV'; cat /proc/net/dev 2>/dev/null || true; ")
        // Per-device cumulative read/write sectors (rates computed from the delta between polls).
        append("echo '@DISKIO'; cat /proc/diskstats 2>/dev/null || true; ")
        // Best-effort SMART health per whole disk (needs smartctl + root; silently empty otherwise).
        append("echo '@SMART'; if command -v smartctl >/dev/null 2>&1; then ")
        append("for d in /sys/block/sd? /sys/block/nvme?n? /sys/block/vd?; do ")
        append("[ -e \"\$d\" ] || continue; n=\$(basename \"\$d\"); ")
        append("h=\$(ot 5 smartctl -H /dev/\$n 2>/dev/null | grep -iE 'overall-health|test result' | sed 's/.*: *//'); ")
        append("[ -n \"\$h\" ] && printf '%s\\t%s\\n' \"\$n\" \"\$h\"; done; ")
        append("else echo '!UNAVAILABLE smartctl is not installed, so drive health cannot be read'; fi; ")
        // Active TCP connection count (ss preferred, /proc fallback).
        append("echo '@TCP'; (ss -taH 2>/dev/null | wc -l) || (cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -c ':') || true; ")
        append("echo '@PROC'; ps -e --no-headers 2>/dev/null | wc -l || true")
    }

    /** FreeBSD/OpenBSD host metrics via sysctl/df/netstat (no /proc). Per-core/disk-I/O/SMART skipped. */
    val METRICS_BSD = buildString {
        append("echo '@OS'; uname -s; ")
        append("echo '@CPU'; top -b -d1 2>/dev/null | grep -i 'CPU:' | head -1 || true; ")
        append("echo '@SYSMEM'; echo phys \$(sysctl -n hw.physmem 2>/dev/null); ")
        append("echo pagesize \$(sysctl -n hw.pagesize 2>/dev/null); ")
        append("echo free \$(sysctl -n vm.stats.vm.v_free_count 2>/dev/null); ")
        append("echo inactive \$(sysctl -n vm.stats.vm.v_inactive_count 2>/dev/null); ")
        append("echo cache \$(sysctl -n vm.stats.vm.v_cache_count 2>/dev/null); ")
        append("echo '@DISK'; df -k / 2>/dev/null | tail -1 || true; ")
        append("echo '@DISKS'; df -k 2>/dev/null | tail -n +2 || true; ")
        append("echo '@LOADAVG'; sysctl -n vm.loadavg 2>/dev/null || true; ")
        append("echo '@BOOT'; sysctl -n kern.boottime 2>/dev/null || true; ")
        append("echo '@NOW'; date +%s 2>/dev/null || true; ")
        append("echo '@NETSTAT'; netstat -ibn 2>/dev/null || true; ")
        append("echo '@TCP'; netstat -an 2>/dev/null | grep -c ESTABLISHED || true; ")
        append("echo '@PROC'; ps -ax 2>/dev/null | wc -l || true")
    }

    /** macOS host metrics: like BSD but memory from `vm_stat` + `hw.memsize`. */
    val METRICS_DARWIN = buildString {
        append("echo '@OS'; uname -s; ")
        append("echo '@CPU'; top -l1 -n0 2>/dev/null | grep -i 'CPU usage' | head -1 || true; ")
        append("echo '@MEMSIZE'; sysctl -n hw.memsize 2>/dev/null || true; ")
        append("echo '@VMSTAT'; vm_stat 2>/dev/null || true; ")
        append("echo '@DISK'; df -k / 2>/dev/null | tail -1 || true; ")
        append("echo '@DISKS'; df -k 2>/dev/null | tail -n +2 || true; ")
        append("echo '@LOADAVG'; sysctl -n vm.loadavg 2>/dev/null || true; ")
        append("echo '@BOOT'; sysctl -n kern.boottime 2>/dev/null || true; ")
        append("echo '@NOW'; date +%s 2>/dev/null || true; ")
        append("echo '@NETSTAT'; netstat -ibn 2>/dev/null || true; ")
        append("echo '@TCP'; netstat -an 2>/dev/null | grep -c ESTABLISHED || true; ")
        append("echo '@PROC'; ps -ax 2>/dev/null | wc -l || true")
    }

    /** Windows (PowerShell) best-effort metrics: CPU load %, memory, logical disks, uptime, procs. */
    val METRICS_WINDOWS =
        "powershell -NoProfile -Command \"" +
            "Write-Output '@OS'; Write-Output 'Windows'; " +
            "Write-Output '@WINCPU'; (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average; " +
            "Write-Output '@WINMEM'; \$o=Get-CimInstance Win32_OperatingSystem; " +
            "Write-Output (([int64]\$o.TotalVisibleMemorySize*1024).ToString()+' '+([int64]\$o.FreePhysicalMemory*1024).ToString()); " +
            "Write-Output '@WINDISK'; Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { " +
            "\$_.DeviceID+' '+\$_.Size+' '+\$_.FreeSpace }; " +
            "Write-Output '@WINUP'; [int64]((Get-Date)-(Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalSeconds; " +
            "Write-Output '@WINPROC'; (Get-Process).Count" +
            "\""

    /**
     * Output that means a privileged command was refused rather than run.
     *
     * One list rather than a copy per call site: a marker added to one and not the other is a
     * failure that quietly stops being reported on exactly one screen.
     */
    val sudoFailureMarkers = listOf(
        "permission denied", "no such file", "sudo:", "a password is required",
        "incorrect password", "not in the sudoers", "operation not permitted",
        "command not found", "not installed", "unsupported archive",
        // Missing here but present in the Flutter port: an extract or compress into a read-only
        // mount failed silently, because nothing in this list matched what the host said.
        "read-only file system",
    )

    /**
     * The refusal a privileged SFTP search met, or null when it ran.
     *
     * Needed because the search sends `find`'s own errors to `/dev/null`: without it, a search of a
     * tree the login cannot read comes back empty and reads as "nothing matched" — a wrong answer
     * wearing the clothes of a right one.
     *
     * **A type-tagged line is a result, never a complaint.** Matching on the text alone lets a file
     * legitimately named `no such thing.txt` blank out the entire result set it appears in, and the
     * first hit is exactly where that bites. Anything sudo has to say arrives ahead of the
     * command's output, so the first line settles it either way.
     */
    fun searchSudoFailure(output: String): String? {
        for (line in output.lineSequence()) {
            if (line.isBlank()) continue
            if (line.startsWith("d\t") || line.startsWith("f\t")) return null
            val trimmed = line.trim()
            return if (sudoFailureMarkers.any { trimmed.contains(it, ignoreCase = true) }) trimmed else null
        }
        return null
    }

    /** Quote a string for safe single-quoted shell use. */
    fun shellQuote(s: String): String = "'" + s.replace("'", "'\\''") + "'"

    /**
     * Where a path typed into the SFTP address box should navigate to, or null when there is
     * nothing to go to.
     *
     * Blank is null rather than the root: clearing the box and pressing Go is a change of mind, and
     * jumping to `/` from a folder deep in the tree is a surprising way to lose your place.
     *
     * A **relative** entry resolves against [current], because the box is prefilled with the
     * directory you are in — so typing `docs` means what it would in a shell. Sent unresolved it
     * would list whatever the SFTP session's working directory happens to be, which is not
     * something the user can see.
     */
    fun resolveTypedPath(current: String, typed: String): String? {
        val trimmed = typed.trim()
        if (trimmed.isEmpty()) return null
        if (trimmed.startsWith("/")) return normalizeSlashes(trimmed)
        val base = if (current.isBlank()) "/" else current
        return normalizeSlashes("$base/$trimmed")
    }

    /** Collapse duplicate separators and strip a trailing one, so one directory has one spelling. */
    private fun normalizeSlashes(path: String): String {
        val collapsed = path.replace(Regex("/+"), "/")
        return if (collapsed.length > 1 && collapsed.endsWith("/")) collapsed.dropLast(1) else collapsed
    }

    /**
     * Compare each clipboard source against the same-named entry in [destDir], one round trip.
     *
     * Emits `sourceIndex<TAB>verdict<TAB>srcSize<TAB>dstSize<TAB>srcMtime<TAB>dstMtime` per
     * conflict, where verdict is IDENTICAL / DIFFERENT / DIR / UNKNOWN. The index is deliberately
     * used instead of the basename: tabs and newlines are legal filename characters and must not
     * corrupt this line protocol.
     *
     * Name+size+mtime alone is only a heuristic — an rsync-style copy reproduces mtime exactly, and
     * two different files can share a size. So when sizes match we hash both sides and compare the
     * digests; only then can "identical" be asserted. Sizes that differ are decisive on their own,
     * so the (potentially expensive) hash is skipped. Directories are reported as DIR because they
     * merge rather than replace. UNKNOWN means no hash tool was available — the UI must then treat
     * the pair as possibly-different rather than claiming a match.
     */
    fun compareForConflicts(destDir: String, sources: List<String>): String {
        if (sources.isEmpty()) return ""
        val quotedDest = shellQuote(destDir)
        return buildString {
            // Pick a digest tool once; empty OT_H means "cannot hash" -> UNKNOWN, never a false match.
            append("OT_H=; for c in sha256sum shasum md5sum cksum; do ")
            append("command -v \"\$c\" >/dev/null 2>&1 && { OT_H=\"\$c\"; break; }; done; ")
            append("OT_STAT() { stat -c '%s %Y' \"\$1\" 2>/dev/null || stat -f '%z %m' \"\$1\" 2>/dev/null; }; ")
            sources.forEachIndexed { index, source ->
                append("OT_S=${shellQuote(source)}; ")
                append("OT_N=\$(basename \"\$OT_S\"); OT_D=$quotedDest/\"\$OT_N\"; ")
                append("if [ -e \"\$OT_D\" ]; then ")
                append("if [ -d \"\$OT_S\" ] || [ -d \"\$OT_D\" ]; then ")
                append("printf '$index\\tDIR\\t0\\t0\\t0\\t0\\n'; else ")
                append("set -- \$(OT_STAT \"\$OT_S\"); OT_SS=\${1:-0}; OT_SM=\${2:-0}; ")
                append("set -- \$(OT_STAT \"\$OT_D\"); OT_DS=\${1:-0}; OT_DM=\${2:-0}; ")
                append("if [ \"\$OT_SS\" != \"\$OT_DS\" ]; then OT_V=DIFFERENT; ")
                append("elif [ -z \"\$OT_H\" ]; then OT_V=UNKNOWN; ")
                append("else OT_A=\$(\"\$OT_H\" \"\$OT_S\" 2>/dev/null | awk '{print \$1}'); ")
                append("OT_B=\$(\"\$OT_H\" \"\$OT_D\" 2>/dev/null | awk '{print \$1}'); ")
                append("if [ -z \"\$OT_A\" ] || [ -z \"\$OT_B\" ]; then OT_V=UNKNOWN; ")
                append("elif [ \"\$OT_A\" = \"\$OT_B\" ]; then OT_V=IDENTICAL; else OT_V=DIFFERENT; fi; fi; ")
                append("printf '$index\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \"\$OT_V\" \"\$OT_SS\" \"\$OT_DS\" \"\$OT_SM\" \"\$OT_DM\"; ")
                append("fi; fi; ")
            }
            append("printf '%s\\n' '$CONFLICT_SCAN_OK'")
        }
    }

    /**
     * Copy/move [sources] into [destDir] honouring a per-name resolution.
     *
     * [skip] names are left untouched (`cp`/`mv` is simply not issued for them); [keepBoth] names are
     * written under a free `name (n).ext` variant found server-side, so nothing is destroyed; every
     * other source overwrites. Runs under `set -e` semantics per item but continues across items so
     * one failure doesn't abandon the rest.
     */
    fun pasteResolved(
        destDir: String,
        sources: List<String>,
        isMove: Boolean,
        skip: Set<String>,
        keepBoth: Set<String>,
    ): String {
        val op = if (isMove) "mv -f --" else "cp -a --"
        val dest = shellQuote(destDir)
        val body = sources.mapNotNull { src ->
            val name = src.substringAfterLast('/')
            when {
                name in skip -> null
                name in keepBoth -> {
                    // Find "name (n).ext" that does not exist yet, then copy/move onto that path.
                    "OT_B=${shellQuote(name.substringBeforeLast('.', name))}; " +
                        "OT_E=${shellQuote(name.substringAfterLast('.', ""))}; " +
                        "OT_I=1; while :; do " +
                        "if [ -n \"\$OT_E\" ]; then OT_T=\"\$OT_B (\$OT_I).\$OT_E\"; else OT_T=\"\$OT_B (\$OT_I)\"; fi; " +
                        "[ -e $dest/\"\$OT_T\" ] || break; OT_I=\$((OT_I+1)); done; " +
                        "$op ${shellQuote(src)} $dest/\"\$OT_T\""
                }
                else -> "$op ${shellQuote(src)} $dest/"
            }
        }
        if (body.isEmpty()) return "true"
        // Keep attempting independent items, but preserve an aggregate failure exit/output instead
        // of letting a later successful command hide an earlier cp/mv failure.
        return "OT_FAIL=0; " +
            body.joinToString("; ") { "$it || OT_FAIL=1" } +
            "; [ \"\$OT_FAIL\" -eq 0 ] || { echo 'OMNITERM_PASTE_FAILED'; exit 1; }"
    }
}

/** Pure parsers — deterministic, no I/O — so they can be unit-tested with captured output. */
object RemoteParsers {

    /** Output of [RemoteCommands.DOCKER_RUNTIMES]: one runtime name per line, anything else ignored. */
    fun parseRuntimeList(output: String): Set<String> =
        output.lineSequence().map { it.trim() }.filter { it == "docker" || it == "podman" }.toSet()

    /**
     * The directory compose actions `cd` into for a stack. Prefers the working_dir label; when a
     * runtime sets config_files but not working_dir (podman-compose, notably), falls back to the
     * parent directory of the first absolute config file — the directory compose would use anyway.
     * Blank when neither yields a usable absolute directory.
     */
    fun composeStackWorkingDir(workingDirLabel: String, configFiles: String): String {
        if (workingDirLabel.isNotBlank()) return workingDirLabel
        val firstConfig = configFiles.split(',').map { it.trim() }.firstOrNull { it.isNotEmpty() }.orEmpty()
        return if (firstConfig.startsWith("/")) firstConfig.substringBeforeLast('/').ifEmpty { "/" } else ""
    }

    // Columns: pid user %cpu %mem vsz etime stat comm (Linux/BSD/macOS and the Windows emulation),
    // or BusyBox's plain `ps w` 4-column form (PID USER TIME COMMAND) from the fallback path.
    // The `ps` header line is skipped because its first column ("PID") isn't an integer.
    fun parseProcesses(output: String): List<SimProcess> =
        output.lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .mapNotNull { line ->
                val t = line.split(Regex("\\s+"), limit = 8)
                val pid = t.getOrNull(0)?.toIntOrNull() ?: return@mapNotNull null
                when {
                    t.size >= 8 -> SimProcess(
                        pid = pid,
                        owner = t[1],
                        cpu = t[2].toFloatOrNull() ?: 0f,
                        mem = t[3].toFloatOrNull() ?: 0f,
                        vms = humanBytes((t[4].toLongOrNull() ?: 0L) * 1024L),
                        uptime = t[5],
                        state = t[6].take(1),
                        name = t[7],
                    )
                    // BusyBox: no per-process cpu/mem/vsz; TIME stands in for uptime and the
                    // command may itself contain spaces (re-join the split tail).
                    t.size >= 4 -> SimProcess(
                        pid = pid,
                        owner = t[1],
                        cpu = 0f,
                        mem = 0f,
                        vms = "—",
                        uptime = t[2],
                        state = "",
                        name = t.drop(3).joinToString(" "),
                    )
                    else -> null
                }
            }
            .toList()

    /** OpenRC `rc-status -a` line: "  sshd  [  started  ]" (runlevel headers don't match). */
    private val OPENRC_SERVICE_RE = Regex("""^(\S+)\s*\[\s*(\w+)\s*]""")

    fun parseServices(output: String): List<SimService> {
        if (output.contains("---OPENRC---")) {
            return output.substringAfter("---OPENRC---").lineSequence()
                .map { it.trim() }
                .mapNotNull { line ->
                    val m = OPENRC_SERVICE_RE.find(line) ?: return@mapNotNull null
                    val state = m.groupValues[2].lowercase()
                    SimService(
                        name = m.groupValues[1],
                        desc = "OpenRC service",
                        status = when (state) {
                            "started" -> "running"
                            "crashed" -> "failed"
                            else -> "dead"
                        },
                        subState = state,
                        // rc-status -a lists services attached to runlevels, which is OpenRC's
                        // closest notion of "enabled".
                        enabled = true,
                    )
                }
                .toList()
        }
        val sections = output.split("---ENABLED---")
        val unitsSection = sections[0]
        val enabledSection = sections.getOrNull(1) ?: ""

        // Build enabled-state map from unit-files section: unit.service -> state
        val enabledMap = enabledSection.lineSequence()
            .map { it.trim() }.filter { it.isNotEmpty() }
            .mapNotNull { line ->
                val t = line.split(Regex("\\s+"), limit = 2)
                if (t.size < 2) null else t[0] to t[1].trim()
            }
            .toMap()

        return unitsSection.lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .mapNotNull { line0 ->
                // Some systemd builds prefix a "●"/"*" status bullet even with --plain; strip it
                val line = line0.removePrefix("●").removePrefix("*").trim()
                val t = line.split(Regex("\\s+"), limit = 5)
                if (t.size < 4) return@mapNotNull null
                val unit = t[0]
                if (!unit.endsWith(".service")) return@mapNotNull null
                val active = t[2]
                val sub = t[3]
                val enableState = enabledMap[unit] ?: ""
                SimService(
                    name = unit.removeSuffix(".service"),
                    desc = t.getOrNull(4)?.trim().orEmpty(),
                    status = when (active) {
                        "active" -> "running"
                        "failed" -> "failed"
                        else -> "dead"
                    },
                    subState = when {
                        active == "failed" || sub == "failed" -> "failed"
                        active == "active" -> "active"
                        else -> sub
                    },
                    enabled = enableState.startsWith("enabled"),
                )
            }
            .toList()
    }

    private val JOURNAL_RE = Regex("""^(\S+)\s+(\S+)\s+([^:]+?):\s?(.*)$""")

    /** True when the host exposes no readable log source, so the UI can explain rather than show empty. */
    fun journalUnsupported(output: String): Boolean = output.contains("---NOLOGS---")

    /**
     * Parse [RemoteCommands.compareForConflicts] output.
     *
     * Anything unrecognised maps to [ConflictVerdict.UNKNOWN] rather than being dropped or assumed
     * benign: a clash we failed to classify must still be shown to the user as unverified, never
     * silently treated as identical.
     */
    fun parseTransferConflicts(output: String): List<TransferConflict> =
        output.lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() && it.contains('\t') }
            .mapNotNull { line ->
                val f = line.split('\t')
                if (f.size < 6) return@mapNotNull null
                val name = f[0].ifBlank { return@mapNotNull null }
                val verdict = when (f[1].uppercase()) {
                    "IDENTICAL" -> ConflictVerdict.IDENTICAL
                    "DIFFERENT" -> ConflictVerdict.DIFFERENT
                    "DIR" -> ConflictVerdict.DIRECTORY
                    else -> ConflictVerdict.UNKNOWN
                }
                TransferConflict(
                    name = name,
                    verdict = verdict,
                    sourceSize = f[2].toLongOrNull() ?: 0L,
                    destSize = f[3].toLongOrNull() ?: 0L,
                    sourceMtimeSeconds = f[4].toLongOrNull() ?: 0L,
                    destMtimeSeconds = f[5].toLongOrNull() ?: 0L,
                    // Default the safe way round: only a proven-identical pair is pre-set to
                    // overwrite (it destroys nothing). Everything else defaults to Keep both.
                    action = if (verdict == ConflictVerdict.IDENTICAL) ConflictAction.OVERWRITE
                    else ConflictAction.KEEP_BOTH,
                )
            }
            .toList()

    /** What a crontab read found: the body, whether it could be read at all, and why not. */
    data class CrontabRead(val text: String, val readable: Boolean, val error: String = "")

    /**
     * Splits [RemoteCommands.CRON_READ_COMMAND]'s output into the crontab and the command's fate.
     *
     * "no crontab for <user>" is cron's own way of saying the file is empty -- every implementation
     * prints it on stderr and exits non-zero -- so it has to be recognised, or a first-time user
     * could never add their first entry. Everything else non-zero is unreadable, and an unreadable
     * crontab must not be writable: a save rewrites the whole file.
     */
    fun parseCrontabRead(output: String): CrontabRead {
        val marker = output.lastIndexOf(RemoteCommands.CRON_EXIT_MARKER)
        if (marker < 0) {
            // The command never ran to completion -- a dropped connection, or a shell that died.
            val text = output.trim()
            return CrontabRead("", false, text.ifBlank { "No response" })
        }
        val body = output.substring(0, marker)
        val status = output.substring(marker + RemoteCommands.CRON_EXIT_MARKER.length).trim().toIntOrNull() ?: -1
        if (status == 0) return CrontabRead(body.trimEnd('\n'), true)
        if (body.contains("no crontab for", ignoreCase = true)) return CrontabRead("", true)
        return CrontabRead("", false, body.trim().ifBlank { "crontab exited $status" })
    }

    /**
     * The file content from a [RemoteCommands.sudoReadCommand] reply, or null when sudo refused.
     *
     * Null and "" are deliberately different: an unreadable file that looked empty would be saved
     * back as a truncation of the original.
     */
    fun parseSudoRead(output: String): String? {
        val marker = output.indexOf(RemoteCommands.SUDO_OUTPUT_MARKER)
        if (marker < 0) return null
        val after = marker + RemoteCommands.SUDO_OUTPUT_MARKER.length
        return output.substring(after).removePrefix("\n")
    }

    fun parseJournal(output: String): List<SimLog> =
        output.lineSequence()
            .map { it.trim() }
            // skip "-- Logs begin --" banners and the no-log-source marker
            .filter { it.isNotEmpty() && !it.startsWith("--") && it != "---NOLOGS---" }
            .mapNotNull { line ->
                val m = JOURNAL_RE.find(line)
                val (timeRaw, ident, msg) = if (m != null) {
                    Triple(m.groupValues[1], m.groupValues[3], m.groupValues[4])
                } else {
                    Triple("", "", line)
                }
                val source = ident.substringBefore('[').trim().ifEmpty { "system" }
                SimLog(
                    time = extractTime(timeRaw),
                    level = inferLevel("$ident $msg"),
                    source = source,
                    message = msg,
                )
            }
            .toList()

    fun parseFleetJournal(output: String, serverName: String, serverId: Int): List<FleetLogEntry> =
        parseJournal(output).map { log ->
            FleetLogEntry(
                serverName = serverName,
                serverId = serverId,
                timestamp = log.time,
                level = log.level,
                message = if (log.source.isNotBlank() && log.source != "system") "[${log.source}] ${log.message}" else log.message,
            )
        }

    fun parseDockerPs(output: String): List<SimContainer> =
        output.lineSequence()
            .map { it.trimEnd() }
            .filter { it.isNotBlank() && !it.startsWith("SSH Error") }
            .mapNotNull { line ->
                val raw = line.split('\t')
                if (raw.size < 4) return@mapNotNull null
                val hasRuntimePrefix = raw.first() == "docker" || raw.first() == "podman"
                val runtime = if (hasRuntimePrefix) raw.first() else "docker"
                val t = if (hasRuntimePrefix) raw.drop(1) else raw
                val statusRaw = t[3].trim()
                val healthRaw = Regex("""\((healthy|unhealthy|starting)\)""", RegexOption.IGNORE_CASE)
                    .find(statusRaw)
                    ?.groupValues
                    ?.getOrNull(1)
                    ?.lowercase()
                    ?: "none"
                SimContainer(
                    id = t[0].take(12),
                    name = t.getOrElse(1) { "" }.trim().removePrefix("/"),
                    image = t.getOrElse(2) { "" },
                    status = when {
                        // A paused container reports e.g. "Up 3 hours (Paused)".
                        statusRaw.contains("Paused", ignoreCase = true) -> "paused"
                        statusRaw == "running" || statusRaw.startsWith("Up", ignoreCase = true) -> "running"
                        statusRaw.startsWith("Restarting", ignoreCase = true) -> "restarting"
                        statusRaw.startsWith("Exited", ignoreCase = true) -> "exited"
                        else -> statusRaw.ifBlank { "exited" }
                    },
                    health = healthRaw,
                    ports = t.getOrElse(4) { "" }.ifBlank { "—" },
                    group = t.getOrElse(5) { "" }.trim().takeUnless { it == "<no value>" }.orEmpty().ifEmpty { "standalone" },
                    host = "",
                    composeService = t.getOrElse(6) { "" }.trim().takeUnless { it == "<no value>" }.orEmpty(),
                    composeWorkingDir = t.getOrElse(7) { "" }.trim().takeUnless { it == "<no value>" }.orEmpty(),
                    composeConfigFiles = t.getOrElse(8) { "" }.trim().takeUnless { it == "<no value>" }.orEmpty(),
                    restartCount = 0,
                    createdAt = t.getOrElse(9) { "" }.trim(),
                    runtime = runtime,
                )
            }
            .toList()

    fun parseDockerRestartCounts(output: String): Map<String, Int> =
        output.lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() && it.contains('\t') }
            .mapNotNull { line ->
                val t = line.split('\t')
                if (t.size >= 3 && (t[0] == "docker" || t[0] == "podman")) {
                    val id = t[1].take(12)
                    "${t[0]}:$id" to (t[2].toIntOrNull() ?: 0)
                } else {
                    val id = t.getOrNull(0)?.take(12) ?: return@mapNotNull null
                    id to (t.getOrNull(1)?.toIntOrNull() ?: 0)
                }
            }
            .toMap()

    fun parseDockerImages(output: String): List<SimDockerImage> =
        output.lineSequence()
            .map { it.trimEnd() }
            .filter { it.isNotBlank() && !it.startsWith("SSH Error") }
            .mapNotNull { line ->
                val raw = line.split('\t')
                if (raw.size < 5) return@mapNotNull null
                val hasRuntimePrefix = raw.first() == "docker" || raw.first() == "podman"
                val runtime = if (hasRuntimePrefix) raw.first() else "docker"
                val t = if (hasRuntimePrefix) raw.drop(1) else raw
                SimDockerImage(
                    id = t[0].removePrefix("sha256:").take(12),
                    repository = t[1],
                    tag = t[2],
                    size = t[3],
                    created = t[4],
                    runtime = runtime,
                )
            }
            .toList()

    fun parseDockerVolumes(output: String): List<SimDockerVolume> =
        output.lineSequence()
            .map { it.trimEnd() }
            .filter { it.isNotBlank() && !it.startsWith("SSH Error") }
            .mapNotNull { line ->
                val raw = line.split('\t')
                if (raw.size < 2) return@mapNotNull null
                val hasRuntimePrefix = raw.first() == "docker" || raw.first() == "podman"
                val runtime = if (hasRuntimePrefix) raw.first() else "docker"
                val t = if (hasRuntimePrefix) raw.drop(1) else raw
                val linksStr = t.getOrElse(4) { "0" }
                val links = linksStr.toIntOrNull() ?: 0

                SimDockerVolume(
                    name = t[0],
                    driver = t[1],
                    mountpoint = t.getOrElse(2) { "" },
                    size = t.getOrElse(3) { "" },
                    inUse = links > 0,
                    runtime = runtime,
                )
            }
            .toList()

    fun parseDockerNetworks(output: String): List<SimDockerNetwork> =
        output.lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() && !it.startsWith("NETWORK") }
            .mapNotNull { line ->
                val raw = line.split('\t')
                if (raw.size < 3) return@mapNotNull null
                val hasRuntimePrefix = raw.first() == "docker" || raw.first() == "podman"
                val runtime = if (hasRuntimePrefix) raw.first() else "docker"
                val t = if (hasRuntimePrefix) raw.drop(1) else raw
                SimDockerNetwork(id = t[0].take(12), name = t[1], driver = t[2], runtime = runtime)
            }
            .toList()

    /** Dispatch host-metrics parsing by the detected remote OS (from the @OS section). */
    fun parseMetrics(output: String, host: String = ""): HostMetrics {
        val sections = splitSections(output)
        return when (RemoteCommands.normaliseOs(sections["OS"].orEmpty())) {
            "FreeBSD" -> parseMetricsBsd(sections, "FreeBSD")
            "Darwin" -> parseMetricsDarwin(sections)
            "Windows" -> parseMetricsWindows(sections)
            else -> parseMetricsLinux(sections)
        }
    }

    private fun parseMetricsLinux(sections: Map<String, String>): HostMetrics {
        // CPU idle: GNU top "95.6 id" or BusyBox top "98% idle" → 100 - idle.
        val cpu = sections["CPU"]?.let { line ->
            Regex("""([\d.]+)\s*%?\s*id""").find(line)?.groupValues?.get(1)?.toFloatOrNull()
                ?.let { (100f - it).coerceIn(0f, 100f) }
        } ?: 0f
        // MEM (free -b): "Mem:  total used free shared buff/cache available"
        var memTotal = 0L; var memUsed = 0L
        sections["MEM"]?.trim()?.takeIf { it.isNotEmpty() }?.split(Regex("\\s+"))?.let { t ->
            memTotal = t.getOrNull(1)?.toLongOrNull() ?: 0L
            val available = t.getOrNull(6)?.toLongOrNull()
            memUsed = if (available != null) (memTotal - available).coerceAtLeast(0L)
                      else (t.getOrNull(2)?.toLongOrNull() ?: 0L)
        }
        // Fallback to /proc/meminfo (values in kB) when `free` was unavailable/oddly-shaped
        // (common on BusyBox/Alpine), so we don't silently report 0% memory.
        if (memTotal == 0L) {
            val info = sections["MEMINFO"].orEmpty()
            fun kb(field: String): Long? =
                Regex("""$field:\s+(\d+)\s*kB""", RegexOption.IGNORE_CASE)
                    .find(info)?.groupValues?.get(1)?.toLongOrNull()
            val totalKb = kb("MemTotal")
            if (totalKb != null) {
                memTotal = totalKb * 1024
                val availKb = kb("MemAvailable") ?: kb("MemFree")
                memUsed = if (availKb != null) ((totalKb - availKb) * 1024).coerceAtLeast(0L) else 0L
            }
        }
        // DISK (df -PB1 /): "fs total used avail use% /". A leading KB1024 token marks the
        // BusyBox df -Pk fallback, whose sizes are 1024-byte blocks.
        var diskTotal = 0L; var diskUsed = 0L
        sections["DISK"]?.trim()?.split(Regex("\\s+"))?.let { raw ->
            val kb = raw.firstOrNull() == "KB1024"
            val t = if (kb) raw.drop(1) else raw
            val scale = if (kb) 1024L else 1L
            diskTotal = (t.getOrNull(1)?.toLongOrNull() ?: 0L) * scale
            diskUsed = (t.getOrNull(2)?.toLongOrNull() ?: 0L) * scale
        }
        // LOAD: "0.08 0.11 0.09 1/297 1234"
        var l1 = 0f; var l5 = 0f; var l15 = 0f; var procs = 0
        sections["LOAD"]?.trim()?.split(Regex("\\s+"))?.let { t ->
            l1 = t.getOrNull(0)?.toFloatOrNull() ?: 0f
            l5 = t.getOrNull(1)?.toFloatOrNull() ?: 0f
            l15 = t.getOrNull(2)?.toFloatOrNull() ?: 0f
            procs = t.getOrNull(3)?.substringAfter('/')?.toIntOrNull() ?: 0
        }
        val uptime = sections["UP"]?.trim()?.split(Regex("\\s+"))?.getOrNull(0)
            ?.toDoubleOrNull()?.toLong() ?: 0L
        val procCount = sections["PROC"]?.trim()?.toIntOrNull()?.takeIf { it > 0 } ?: procs

        // CPU temperature: hottest thermal zone, reported in millidegrees Celsius.
        val cpuTempC = sections["TEMP"]?.lineSequence()
            ?.mapNotNull { it.trim().toLongOrNull() }
            ?.maxOrNull()
            ?.let { if (it > 1000) it / 1000f else it.toFloat() }
            ?.takeIf { it > 0f }

        val tcpConnections = sections["TCP"]?.trim()?.lines()?.lastOrNull()?.trim()?.toIntOrNull() ?: 0

        // Attach SMART health to each mount by matching its block device (strip /dev/ and partition).
        val smart = parseSmart(sections["SMART"].orEmpty())
        val disks = parseDisks(sections["DISKS"].orEmpty()).map { d ->
            val dev = d.filesystem.removePrefix("/dev/").replace(Regex("p?\\d+$"), "")
            d.copy(health = smart[dev].orEmpty())
        }

        // Prefer the distro pretty-name (Raspberry Pi OS, Ubuntu 22.04, Alpine, …) over bare "Linux".
        val osLabel = sections["DISTRO"]?.trim()?.lineSequence()?.firstOrNull { it.isNotBlank() }?.trim()
            ?.takeIf { it.isNotEmpty() } ?: "Linux"

        val platforms = sections["PLATFORM"].orEmpty().lineSequence()
            .map { it.trim() }.filter { it.isNotEmpty() }.toMutableSet().apply { add("linux") }

        return HostMetrics(
            cpu, memUsed, memTotal, diskUsed, diskTotal, l1, l5, l15, uptime, procCount,
            cpuTempC = cpuTempC, tcpConnections = tcpConnections, disks = disks, os = osLabel,
            platforms = platforms, unavailable = parseUnavailable(sections),
        )
    }

    /** FreeBSD/OpenBSD metrics (sysctl/df -k/netstat). Per-core/temp/disk-I/O/SMART are not collected. */
    private fun parseMetricsBsd(sections: Map<String, String>, os: String): HostMetrics {
        val cpu = sections["CPU"]?.let { line ->
            Regex("""([\d.]+)%\s*idle""", RegexOption.IGNORE_CASE).find(line)?.groupValues?.get(1)
                ?.toFloatOrNull()?.let { (100f - it).coerceIn(0f, 100f) }
        } ?: 0f
        val mem = sections["SYSMEM"].orEmpty()
        fun sm(key: String): Long = Regex("""^$key\s+(\d+)""", RegexOption.MULTILINE)
            .find(mem)?.groupValues?.get(1)?.toLongOrNull() ?: 0L
        val pageSize = sm("pagesize").takeIf { it > 0 } ?: 4096L
        val memTotal = sm("phys")
        val freeBytes = (sm("free") + sm("inactive") + sm("cache")) * pageSize
        val memUsed = (memTotal - freeBytes).coerceAtLeast(0L)
        val disks = parseDisks(sections["DISKS"].orEmpty(), blockBytes = 1024L)
        val root = disks.firstOrNull { it.mount == "/" }
        val load = sections["LOADAVG"].orEmpty().let { Regex("""[\d.]+""").findAll(it).map { m -> m.value.toFloat() }.toList() }
        val boot = Regex("""sec\s*=\s*(\d+)""").find(sections["BOOT"].orEmpty())?.groupValues?.get(1)?.toLongOrNull()
        val now = sections["NOW"]?.trim()?.toLongOrNull()
        val uptime = if (boot != null && now != null) (now - boot).coerceAtLeast(0L) else 0L
        val tcp = sections["TCP"]?.trim()?.toIntOrNull() ?: 0
        val procCount = sections["PROC"]?.trim()?.toIntOrNull() ?: 0
        return HostMetrics(
            cpu, memUsed, memTotal, root?.usedBytes ?: 0L, root?.totalBytes ?: 0L,
            load.getOrElse(0) { 0f }, load.getOrElse(1) { 0f }, load.getOrElse(2) { 0f }, uptime, procCount,
            tcpConnections = tcp, disks = disks, netInterfaces = parseBsdNetstat(sections["NETSTAT"].orEmpty()), os = os, platforms = setOf("freebsd"),
        )
    }

    /** macOS metrics: like BSD but memory from vm_stat + hw.memsize. */
    private fun parseMetricsDarwin(sections: Map<String, String>): HostMetrics {
        val cpu = sections["CPU"]?.let { line ->
            Regex("""([\d.]+)%\s*idle""", RegexOption.IGNORE_CASE).find(line)?.groupValues?.get(1)
                ?.toFloatOrNull()?.let { (100f - it).coerceIn(0f, 100f) }
        } ?: 0f
        val memTotal = sections["MEMSIZE"]?.trim()?.toLongOrNull() ?: 0L
        val vmstat = sections["VMSTAT"].orEmpty()
        val pageSize = Regex("""page size of (\d+) bytes""").find(vmstat)?.groupValues?.get(1)?.toLongOrNull() ?: 4096L
        fun pages(label: String): Long = Regex("""$label:\s+(\d+)""").find(vmstat)?.groupValues?.get(1)?.toLongOrNull() ?: 0L
        val freeBytes = (pages("Pages free") + pages("Pages inactive") + pages("Pages speculative")) * pageSize
        val memUsed = (memTotal - freeBytes).coerceAtLeast(0L)
        val disks = parseDisks(sections["DISKS"].orEmpty(), blockBytes = 1024L)
        val root = disks.firstOrNull { it.mount == "/" }
        val load = sections["LOADAVG"].orEmpty().let { Regex("""[\d.]+""").findAll(it).map { m -> m.value.toFloat() }.toList() }
        val boot = Regex("""sec\s*=\s*(\d+)""").find(sections["BOOT"].orEmpty())?.groupValues?.get(1)?.toLongOrNull()
        val now = sections["NOW"]?.trim()?.toLongOrNull()
        val uptime = if (boot != null && now != null) (now - boot).coerceAtLeast(0L) else 0L
        val tcp = sections["TCP"]?.trim()?.toIntOrNull() ?: 0
        val procCount = sections["PROC"]?.trim()?.toIntOrNull() ?: 0
        return HostMetrics(
            cpu, memUsed, memTotal, root?.usedBytes ?: 0L, root?.totalBytes ?: 0L,
            load.getOrElse(0) { 0f }, load.getOrElse(1) { 0f }, load.getOrElse(2) { 0f }, uptime, procCount,
            tcpConnections = tcp, disks = disks, netInterfaces = parseBsdNetstat(sections["NETSTAT"].orEmpty()), os = "Darwin", platforms = setOf("darwin"),
        )
    }

    /** Windows (PowerShell) best-effort: CPU load %, memory, logical disks, uptime, proc count. */
    private fun parseMetricsWindows(sections: Map<String, String>): HostMetrics {
        val cpu = sections["WINCPU"]?.trim()?.lines()?.firstOrNull()?.trim()?.toFloatOrNull()?.coerceIn(0f, 100f) ?: 0f
        var memTotal = 0L; var memUsed = 0L
        sections["WINMEM"]?.trim()?.split(Regex("\\s+"))?.let { t ->
            memTotal = t.getOrNull(0)?.toLongOrNull() ?: 0L
            val free = t.getOrNull(1)?.toLongOrNull() ?: 0L
            memUsed = (memTotal - free).coerceAtLeast(0L)
        }
        val disks = sections["WINDISK"].orEmpty().lineSequence().mapNotNull { line ->
            val t = line.trim().split(Regex("\\s+"))
            if (t.size < 3) return@mapNotNull null
            val total = t[1].toLongOrNull() ?: return@mapNotNull null
            val free = t[2].toLongOrNull() ?: 0L
            if (total <= 0) return@mapNotNull null
            DiskUsage(mount = t[0], filesystem = t[0], totalBytes = total, usedBytes = (total - free).coerceAtLeast(0L))
        }.toList()
        val root = disks.firstOrNull()
        val uptime = sections["WINUP"]?.trim()?.lines()?.firstOrNull()?.trim()?.toDoubleOrNull()?.toLong() ?: 0L
        val procCount = sections["WINPROC"]?.trim()?.lines()?.lastOrNull()?.trim()?.toIntOrNull() ?: 0
        return HostMetrics(
            cpu, memUsed, memTotal, root?.usedBytes ?: 0L, root?.totalBytes ?: 0L,
            0f, 0f, 0f, uptime, procCount, disks = disks, os = "Windows", platforms = setOf("windows"),
        )
    }

    /** Parse `netstat -ibn` (BSD/macOS) into per-interface RX/TX byte totals (first row per iface). */
    private fun parseBsdNetstat(output: String): List<NetInterface> {
        val map = LinkedHashMap<String, NetInterface>()
        for (line in output.lineSequence()) {
            val t = line.trim().split(Regex("\\s+"))
            if (t.size < 11) continue
            val name = t[0]
            if (name == "Name" || name == "lo0" || name in map) continue
            // netstat -ibn: Name Mtu Network Address Ipkts Ierrs Idrop Ibytes Opkts Oerrs Obytes ...
            val rx = t.getOrNull(7)?.toLongOrNull() ?: continue
            val tx = t.getOrNull(10)?.toLongOrNull() ?: continue
            map[name] = NetInterface(name, rx, tx)
        }
        return map.values.toList()
    }

    /** SMART health lines "<device>\t<health>" → device -> health. */
    fun parseSmart(output: String): Map<String, String> =
        output.lineSequence()
            .mapNotNull { line ->
                val t = line.split('\t')
                if (t.size < 2) return@mapNotNull null
                val dev = t[0].trim(); val health = t[1].trim()
                if (dev.isEmpty() || health.isEmpty()) null else dev to health
            }
            .toMap()

    /** Per-whole-disk cumulative read/write bytes from /proc/diskstats (sectors are 512 bytes). */
    fun parseDiskIo(output: String): Map<String, DiskIo> {
        val whole = Regex("^(sd[a-z]+|nvme\\d+n\\d+|vd[a-z]+|xvd[a-z]+|mmcblk\\d+|hd[a-z]+)$")
        val map = LinkedHashMap<String, DiskIo>()
        for (line in output.lineSequence()) {
            val t = line.trim().split(Regex("\\s+"))
            if (t.size < 10) continue
            val name = t[2]
            if (!whole.matches(name)) continue
            val read = (t[5].toLongOrNull() ?: 0L) * 512L
            val write = (t[9].toLongOrNull() ?: 0L) * 512L
            map[name] = DiskIo(name, read, write)
        }
        return map
    }


    /** Pseudo / virtual filesystems we don't want to show as "disks". */
    private val PSEUDO_FS = setOf(
        "tmpfs", "devtmpfs", "overlay", "squashfs", "proc", "sysfs", "cgroup", "cgroup2",
        "devfs", "fdescfs", "procfs", "none", "udev", "ramfs", "efivarfs", "shm", "mqueue",
    )

    /**
     * Parse `df` (all mounts) into per-partition usage, excluding pseudo filesystems. [blockBytes]
     * scales the size columns: 1 for `df -PB1` (Linux, already bytes), 1024 for `df -k` (BSD/macOS).
     */
    fun parseDisks(output: String, blockBytes: Long = 1L): List<DiskUsage> =
        output.lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .mapNotNull { line ->
                // A line-leading KB1024 token marks the BusyBox df -Pk fallback (1024-byte blocks).
                val raw = line.split(Regex("\\s+"))
                val kb = raw.firstOrNull() == "KB1024"
                val t = if (kb) raw.drop(1) else raw
                val scale = if (kb) 1024L else blockBytes
                if (t.size < 6) return@mapNotNull null
                val fs = t[0]
                if (PSEUDO_FS.any { fs.equals(it, ignoreCase = true) }) return@mapNotNull null
                val total = t[1].toLongOrNull() ?: return@mapNotNull null
                if (total <= 0L) return@mapNotNull null
                val used = t[2].toLongOrNull() ?: 0L
                val mount = t.subList(5, t.size).joinToString(" ")
                if (mount.startsWith("/proc") || mount.startsWith("/sys") || mount.startsWith("/dev") || mount.startsWith("/run")) return@mapNotNull null
                DiskUsage(mount = mount, filesystem = fs, totalBytes = total * blockBytes, usedBytes = used * blockBytes)
            }
            .distinctBy { it.mount }
            .toList()

    /** Per-CPU jiffies from /proc/stat: name -> (idleJiffies, totalJiffies). Used to derive rates. */
    fun parseProcStat(output: String): Map<String, Pair<Long, Long>> {
        val map = LinkedHashMap<String, Pair<Long, Long>>()
        for (line in output.lineSequence()) {
            val t = line.trim().split(Regex("\\s+"))
            if (t.size < 5 || !t[0].startsWith("cpu")) continue
            val nums = t.drop(1).mapNotNull { it.toLongOrNull() }
            if (nums.size < 4) continue
            val idle = nums[3] + (nums.getOrNull(4) ?: 0L) // idle + iowait
            val total = nums.sum()
            map[t[0]] = idle to total
        }
        return map
    }

    fun computeCpuUsageDelta(
        prev: Map<String, Pair<Long, Long>>?,
        cur: Map<String, Pair<Long, Long>>,
        cpuName: String,
    ): Float? {
        if (prev == null) return null
        val p = prev[cpuName] ?: return null
        val c = cur[cpuName] ?: return null
        val idleDelta = (c.first - p.first).toFloat()
        val totalDelta = (c.second - p.second).toFloat()
        return if (totalDelta <= 0f) 0f else ((1f - idleDelta / totalDelta) * 100f).coerceIn(0f, 100f)
    }

    fun computePerCoreCpuDeltas(
        prev: Map<String, Pair<Long, Long>>?,
        cur: Map<String, Pair<Long, Long>>,
    ): List<Float> {
        if (prev == null) return emptyList()
        return cur.keys
            .filter { it != "cpu" && it.startsWith("cpu") }
            .sortedBy { it.removePrefix("cpu").toIntOrNull() ?: 0 }
            .map { computeCpuUsageDelta(prev, cur, it) ?: 0f }
    }

    /** Per-interface cumulative RX/TX bytes from /proc/net/dev. */
    fun parseNetDev(output: String): Map<String, Pair<Long, Long>> {
        val map = LinkedHashMap<String, Pair<Long, Long>>()
        for (line in output.lineSequence()) {
            val colon = line.indexOf(':')
            if (colon < 0) continue
            val name = line.substring(0, colon).trim()
            if (name.isEmpty() || name == "lo") continue
            val nums = line.substring(colon + 1).trim().split(Regex("\\s+")).mapNotNull { it.toLongOrNull() }
            if (nums.size < 9) continue
            map[name] = nums[0] to nums[8] // rxBytes, txBytes
        }
        return map
    }

    // ── helpers ──

    /** Section name -> reason, for sections the probe reported as `!UNAVAILABLE <reason>`. */
    internal fun parseUnavailable(sections: Map<String, String>): Map<String, String> =
        sections.mapNotNull { (name, body) ->
            body.lineSequence()
                .firstOrNull { it.startsWith(UNAVAILABLE_MARKER) }
                ?.removePrefix(UNAVAILABLE_MARKER)
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
                ?.let { name to it }
        }.toMap()

    internal const val UNAVAILABLE_MARKER = "!UNAVAILABLE"

    private fun splitSections(output: String): Map<String, String> {
        val map = HashMap<String, String>()
        var key: String? = null
        val sb = StringBuilder()
        fun flush() { if (key != null) map[key!!] = sb.toString().trim() }
        for (line in output.lineSequence()) {
            if (line.startsWith("@")) {
                flush(); sb.setLength(0); key = line.substring(1).trim()
            } else {
                sb.append(line).append('\n')
            }
        }
        flush()
        return map
    }

    private fun extractTime(ts: String): String {
        // "2026-05-30T10:41:22+0530" → "10:41:22"; fall back to raw
        val afterT = ts.substringAfter('T', ts)
        val m = Regex("""(\d{2}:\d{2}:\d{2})""").find(afterT)
        return m?.groupValues?.get(1) ?: afterT.take(8)
    }

    private fun inferLevel(text: String): String {
        val l = text.lowercase()
        return when {
            // No trailing \b: these are word *stems*, and a closing boundary disabled every one
            // of them. "fail" could not match "failure" or "failing", "error" could not match
            // "errors", and "deprecat" — plainly written as a stem — could only ever match the
            // literal string "deprecat". Real errors were being shown as INFO in Monitor → Logs and
            // in Fleet broadcast output, which is exactly backwards for triage. The leading \b is
            // kept so a stem must still start a word and cannot match mid-token ("shutdown" is
            // still INFO).
            Regex("\\b(error|fail|failed|fatal|critical|denied|refused|panic|segfault)").containsMatchIn(l) -> "ERROR"
            Regex("\\b(warn|warning|deprecat|timeout|retry)").containsMatchIn(l) -> "WARN"
            else -> "INFO"
        }
    }

    fun humanBytes(bytes: Long): String {
        if (bytes <= 0) return "0 B"
        val units = arrayOf("B", "KB", "MB", "GB", "TB")
        var v = bytes.toDouble(); var i = 0
        while (v >= 1024 && i < units.size - 1) { v /= 1024; i++ }
        // Force Locale.US so the decimal separator is always '.' regardless of device locale.
        return if (i == 0) "${bytes} B" else String.format(java.util.Locale.US, "%.1f %s", v, units[i])
    }
}
