# Terminal compatibility matrix

This matrix describes the implemented contract, not full xterm compatibility. The SSH PTY advertises `xterm-256color` and `COLORTERM=truecolor`, while the renderer intentionally implements a defensive xterm/VT subset and ignores unknown controls.

| Area | Status | Contract / limitation |
|---|---|---|
| SSH interactive PTY | Supported | Resizable PTY with raw input/output and reconnect handling. |
| UTF-8 streams | Supported | Strict incremental decoding handles valid, malformed, split, and incomplete-at-EOF input without losing following bytes. Combining sequences, wide CJK, common emoji/ZWJ/flag/keycap clusters, and wide-cell reflow are supported. Unicode width remains a bounded terminal subset rather than a shaping engine for every complex script. |
| Colors and attributes | Supported | 16-color, xterm-256, 24-bit foreground/background; bold, dim, italic, underline, inverse. |
| Cursor, erase, insert/delete, scroll regions | Supported subset | Common CSI/DEC sequences are implemented; unknown sequences are ignored rather than rendered as text. |
| Alternate screen | Supported | DEC 47/1047/1049, including resize preservation for TUIs such as `vim`, `less`, and `htop`. |
| Normal-screen reflow | Supported | Soft-wrapped lines reflow on width changes; hard line breaks remain distinct. |
| OSC | Safely ignored | BEL and ST termination are parsed, but titles, hyperlinks, clipboard operations, and notifications are not acted on. In particular, OSC 52 cannot write the Android clipboard. |
| Mouse reporting | Not supported | Touch gestures operate local scrollback; tmux mouse mode is disabled for app-created persistent sessions. |
| Bracketed paste | Supported | DECSET 2004 is tracked and pasted blocks are wrapped with the standard begin/end markers. |
| Focus reporting | Not supported | Android focus changes are not emitted as terminal focus events. |
| Hardware keyboard | Supported | Navigation, Insert/Delete, Page Up/Down, F1–F12, explicit Ctrl-byte mappings, xterm modifiers, and Alt-prefixed input are encoded; Ctrl+Alt is reserved for AltGr/international text input. |
| Standard persistent tmux | Supported | App-created session, bounded history, reconnect/reattach, capture-based history recovery. Availability depends on tmux on the host. |
| tmux control mode (`tmux -C`) | Experimental, opt-in | Structured `%output` stream modeled on iTerm2 integration; fixtures are verified against tmux 3.3a. Split panes created inside tmux are not independent OmniTerm UI panes. |
| OmniTerm MultiSSH split | Supported | Two independent SSH sessions with separate PTYs, viewport, focus, resize, and lifecycle. Each pane can create a new session or attach any distinct background session, enabling new+new, new+existing, and existing+existing layouts. |
| Shell/platform | Broad SSH compatibility | Interactive shells should work wherever an SSH server grants a PTY. Linux is the primary test target; monitoring/installation helpers require platform tools and are separate from terminal emulation. |

## Regression minimum

Terminal changes should cover fragmented/malformed byte streams, C0/ESC/CSI/OSC state transitions, alternate-screen entry/exit and resize, soft-wrap reflow, bounded scrollback, cursor modes, Unicode wide/combined clusters, hardware modifiers, bracketed paste, 256/truecolor SGR, tmux control framing and octal decoding, reconnect/close races, input backpressure, and split-pane resizing. Real-device smoke tests should include rotation, IME show/hide, international hardware layouts/AltGr, background/foreground, network loss, and a long-running tmux command.
