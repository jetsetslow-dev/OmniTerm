import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../../domain/host_display.dart';
import '../../../domain/terminal_key_encoder.dart';
import '../../../domain/terminal_soft_input.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/shell_session.dart';
import '../../view_model/shell_view_model.dart';
import '../../widgets/terminal_key_bar.dart';
import '../../widgets/terminal_surface.dart';
import '../../widgets/omni_components.dart';

/// The Shell screen, ported from `ShellScreen` in `ui/ShellScreen.kt`.
///
/// Three states: nothing to connect to, a host waiting for a connection, and a live terminal. The
/// screen never shows an empty black rectangle that looks like a working shell — every state says
/// what it is.
class ShellScreen extends StatelessWidget {
  const ShellScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<ShellViewModel>();
    final session = vm.current;

    return Container(
      color: const Color(0xFF05070C),
      child: Column(
        children: [
          if (vm.sessions.isNotEmpty || session != null) _SessionBar(vm: vm),
          Expanded(
            child: session == null
                ? _ConnectPane(vm: vm)
                : vm.isSplit
                ? _SplitTerminals(vm: vm, first: session, second: vm.splitSession!)
                : _ActiveTerminal(vm: vm, session: session),
          ),
          if (session != null) TerminalKeyBar(viewModel: vm),
        ],
      ),
    );
  }
}

// ── connect / empty states ────────────────────────────────────────────────────

class _ConnectPane extends StatelessWidget {
  const _ConnectPane({required this.vm});

  final ShellViewModel vm;

  @override
  Widget build(BuildContext context) {
    if (vm.isConnecting) return _ConnectingView(phase: vm.connectPhase);

    final server = vm.server;
    if (server == null) {
      return _EmptyState(
        key: const ValueKey('shell.empty'),
        message: !vm.hasAnyHost
            // The two are different problems with different fixes, so they get different sentences.
            // "No hosts" is solved by adding one; "none online" is solved from the Hosts tab, which
            // is also the only place that warns before forcing SSH to a host believed to be down.
            ? 'Add a host first.'
            : 'No online hosts. To SSH into an offline host anyway, use its connect button on the '
                  'Hosts tab.',
        error: vm.error,
      );
    }

    return Column(
      children: [
        Expanded(
          child: _ConnectPrompt(vm: vm, server: server),
        ),
        // Below the connect prompt rather than instead of it: a session left running on a server is
        // something to *come back to*, so it belongs where the user arrives looking for a terminal.
        if (vm.resumableSessions.isNotEmpty) _ResumableSessions(vm: vm),
      ],
    );
  }
}

/// tmux sessions still running on a server with nothing attached to them.
class _ResumableSessions extends StatelessWidget {
  const _ResumableSessions({required this.vm});

  final ShellViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      key: const ValueKey('shell.resumable'),
      constraints: const BoxConstraints(maxHeight: 200),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Left running', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          Text(
            // Saying where they are, because "resumable" alone reads as a local draft rather than
            // work still executing on someone else's machine.
            'These are still running on their servers. Resuming attaches to one again.',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final row in vm.resumableSessions)
                  OmniCard(
                    key: ValueKey('shell.resumable.${row.tmuxName}'),
                    leftAccent: OmniColors.amber,
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                row.serverName,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                              Text(
                                row.tmuxName,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontFamily: OmniFonts.mono,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          key: ValueKey('shell.resumable.${row.tmuxName}.resume'),
                          onPressed: vm.isConnecting ? null : () => vm.resume(row),
                          child: const Text('Resume', style: TextStyle(fontSize: 12)),
                        ),
                        TextButton(
                          key: ValueKey('shell.resumable.${row.tmuxName}.forget'),
                          onPressed: () => _confirmForget(context, vm, row),
                          child: Text(
                            'Forget',
                            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _confirmForget(BuildContext context, ShellViewModel vm, PersistentSession row) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('shell.resumable.forget.dialog'),
      title: Text('Forget "${row.serverName}"?'),
      content: const Text(
        // The distinction that matters: this is a pointer on this device, not the session itself.
        'This only removes it from this list. The tmux session keeps running on the server — to '
        'end it, resume it and exit the shell.',
      ),
      actions: [
        TextButton(
          key: const ValueKey('shell.resumable.forget.cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('shell.resumable.forget.confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Forget', style: TextStyle(color: OmniColors.red)),
        ),
      ],
    ),
  );
  if (confirmed ?? false) await vm.forgetResumable(row);
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({super.key, required this.message, this.error});

  final String message;
  final String? error;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: OmniFonts.mono,
              fontSize: 13,
              color: Color(0xFF7C8AA5),
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 16),
            Text(
              error!,
              key: const ValueKey('shell.error'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: OmniColors.red),
            ),
          ],
        ],
      ),
    ),
  );
}

class _ConnectPrompt extends StatelessWidget {
  const _ConnectPrompt({required this.vm, required this.server});

  final ShellViewModel vm;
  final Server server;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '>_',
            style: TextStyle(
              color: OmniColors.cyan,
              fontSize: 34,
              fontFamily: OmniFonts.mono,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            server.name,
            style: const TextStyle(
              fontFamily: OmniFonts.mono,
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: Color(0xFFC8D4E8),
            ),
          ),
          // Routed through HostDisplay so "hide addresses" covers the terminal too. A screen the
          // user is most likely to be sharing is the last place to leak a host name.
          ListenableBuilder(
            listenable: HostDisplay.instance,
            builder: (context, _) => Text(
              '${HostDisplay.instance.userAtHost(server)}:${server.port}',
              key: const ValueKey('shell.connect.target'),
              style: const TextStyle(
                fontFamily: OmniFonts.mono,
                fontSize: 11,
                color: Color(0xFF7C8AA5),
              ),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const ValueKey('shell.connect'),
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text('Connect'),
            onPressed: vm.canConnect ? () => vm.connect(server) : null,
          ),
          if (!vm.canConnect)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text(
                // Convention 4: say the feature is off rather than opening a terminal that will
                // never receive a byte.
                'The terminal is unavailable in this build: no SSH transport is wired.',
                key: ValueKey('shell.unavailable'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: OmniColors.amber),
              ),
            ),
          if (vm.error != null) ...[
            const SizedBox(height: 16),
            Text(
              vm.error!,
              key: const ValueKey('shell.error'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: OmniColors.red),
            ),
          ],
        ],
      ),
    ),
  );
}

class _ConnectingView extends StatelessWidget {
  const _ConnectingView({this.phase});

  final String? phase;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2, color: OmniColors.cyan),
        ),
        const SizedBox(height: 14),
        Text(
          // The transport's own phase, not a generic spinner label: "Authenticating…" that sits
          // there for ten seconds tells the user which step is hanging.
          phase ?? 'Connecting…',
          key: const ValueKey('shell.phase'),
          style: const TextStyle(
            fontFamily: OmniFonts.mono,
            fontSize: 12,
            color: Color(0xFF7C8AA5),
          ),
        ),
      ],
    ),
  );
}

// ── session chips ─────────────────────────────────────────────────────────────

class _SessionBar extends StatelessWidget {
  const _SessionBar({required this.vm});

  final ShellViewModel vm;

  @override
  Widget build(BuildContext context) {
    final current = vm.current;

    return Container(
      key: const ValueKey('shell.sessionBar'),
      height: 40,
      color: const Color(0xFF0B1017),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final session in vm.sessions)
                  _SessionChip(
                    session: session,
                    selected: session.id == current?.id,
                    onTap: () => vm.select(session.id),
                    onClose: () => vm.close(session),
                  ),
              ],
            ),
          ),
          // Splitting needs a second session to show, so the control lives next to the one that
          // creates them.
          if (vm.sessions.length > 1 && !vm.isSplit)
            IconButton(
              key: const ValueKey('shell.split'),
              tooltip: 'Split the view',
              iconSize: 18,
              icon: const Icon(Icons.vertical_split, color: OmniColors.cyan),
              onPressed: () => _openSplitPicker(context, vm),
            ),
          if (vm.server != null && !vm.isConnecting)
            IconButton(
              key: const ValueKey('shell.newSession'),
              tooltip: 'New session',
              iconSize: 18,
              icon: const Icon(Icons.add, color: OmniColors.cyan),
              onPressed: vm.canConnect ? () => vm.connect(vm.server!) : null,
            ),
        ],
      ),
    );
  }
}

class _SessionChip extends StatelessWidget {
  const _SessionChip({
    required this.session,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  final ShellSession session;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      // A dead session keeps its chip until it is dismissed: its scrollback is the only record
      // of why it died, and closing it automatically would erase that at the worst moment.
      final live = session.isOpen;
      final colour = live ? OmniColors.green : OmniColors.red;

      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 3),
        child: InkWell(
          key: ValueKey('shell.session.${session.id}'),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: selected ? const Color(0xFF16202F) : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: selected ? OmniColors.cyan : const Color(0xFF243044)),
            ),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text(
                  session.serverName,
                  style: const TextStyle(
                    fontFamily: OmniFonts.mono,
                    fontSize: 11,
                    color: Color(0xFFC8D4E8),
                  ),
                ),
                const SizedBox(width: 4),
                InkWell(
                  key: ValueKey('shell.session.${session.id}.close'),
                  onTap: onClose,
                  child: const Icon(Icons.close, size: 13, color: Color(0xFF7C8AA5)),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

// ── the live terminal ─────────────────────────────────────────────────────────

class _ActiveTerminal extends StatefulWidget {
  const _ActiveTerminal({required this.vm, required this.session});

  final ShellViewModel vm;
  final ShellSession session;

  @override
  State<_ActiveTerminal> createState() => _ActiveTerminalState();
}

class _ActiveTerminalState extends State<_ActiveTerminal> {
  /// Drives the platform's software keyboard.
  ///
  /// Invisible, and emptied after every commit: the terminal — not this field — is the record of
  /// what was typed, and leaving text in it would let a backspace edit history the remote has
  /// already consumed.
  final TextEditingController _input = TextEditingController();

  /// Owns the platform IME, so focusing it raises the software keyboard.
  final FocusNode _imeFocus = FocusNode(debugLabel: 'terminal-ime');

  /// Sits *above* the field and takes first refusal on hardware keys.
  ///
  /// Two nodes rather than one because a [FocusNode] can only be attached to a single widget, and
  /// the two jobs are genuinely different: the field must hold focus for the soft keyboard to have
  /// anywhere to deliver text, while Escape, the arrows and the function row have to be intercepted
  /// before the text field's own editing shortcuts turn them into cursor movement inside a field
  /// the user cannot even see.
  final FocusNode _keyFocus = FocusNode(debugLabel: 'terminal-keys');

  @override
  void dispose() {
    _input.dispose();
    _imeFocus.dispose();
    _keyFocus.dispose();
    super.dispose();
  }

  void _onCommit(String text) {
    _input.clear();
    final action = interpretSoftInput(text);
    switch (action) {
      case SoftInputType(text: final t):
        widget.vm.typeText(t);
      case SoftInputEnter():
        widget.vm.sendKey(TermKey.enter);
      case SoftInputPaste(text: final t):
        widget.vm.paste(t);
      case null:
        break;
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;

    final key = _termKeyFor(event.logicalKey);
    if (key != null) {
      widget.vm.sendKey(key);
      return KeyEventResult.handled;
    }
    final character = event.character;
    if (character != null && character.isNotEmpty && character.codeUnitAt(0) >= 0x20) {
      widget.vm.typeText(character);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;

    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => Column(
        children: [
          _TerminalStatusRow(vm: widget.vm, session: session),
          Expanded(
            child: Focus(
              focusNode: _keyFocus,
              // Ancestor of the field, so it sees a hardware key before the field's own editing
              // shortcuts do. Anything it does not claim falls through to ordinary text entry.
              onKeyEvent: _onKey,
              child: Stack(
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    // The pane that takes the keyboard is the pane that should be current. Doing
                    // this here rather than in an ancestor detector is not a detail: the surface
                    // claims the gesture arena, so an outer detector's tap never arrives.
                    onTap: () {
                      widget.vm.focusPane(session.id);
                      _imeFocus.requestFocus();
                    },
                    child: TerminalSurface(
                      session: session,
                      focused: _imeFocus.hasFocus,
                      onGridChanged: widget.vm.rememberGrid,
                    ),
                  ),
                  // Sized to nothing and painted with nothing: it exists purely to own the platform
                  // IME connection so the software keyboard has somewhere to deliver text.
                  Positioned(
                    width: 1,
                    height: 1,
                    child: Opacity(
                      opacity: 0,
                      child: TextField(
                        key: const ValueKey('shell.input'),
                        controller: _input,
                        focusNode: _imeFocus,
                        onChanged: _onCommit,
                        // A terminal needs literal keystrokes. Sentence casing would capitalise the
                        // first letter of every command, and autocorrect would rewrite flag names.
                        autocorrect: false,
                        enableSuggestions: false,
                        textCapitalization: TextCapitalization.none,
                        keyboardType: TextInputType.multiline,
                        maxLines: null,
                      ),
                    ),
                  ),
                  if (!session.followTail)
                    Positioned(
                      right: 12,
                      bottom: 12,
                      child: FloatingActionButton.small(
                        key: const ValueKey('shell.jumpToBottom'),
                        backgroundColor: OmniColors.cyan,
                        onPressed: session.scrollToTail,
                        child: const Icon(Icons.arrow_downward, size: 18, color: Colors.black),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static TermKey? _termKeyFor(LogicalKeyboardKey key) => switch (key) {
    LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter => TermKey.enter,
    LogicalKeyboardKey.backspace => TermKey.backspace,
    LogicalKeyboardKey.tab => TermKey.tab,
    LogicalKeyboardKey.escape => TermKey.esc,
    LogicalKeyboardKey.arrowUp => TermKey.up,
    LogicalKeyboardKey.arrowDown => TermKey.down,
    LogicalKeyboardKey.arrowLeft => TermKey.left,
    LogicalKeyboardKey.arrowRight => TermKey.right,
    LogicalKeyboardKey.home => TermKey.home,
    LogicalKeyboardKey.end => TermKey.end,
    LogicalKeyboardKey.insert => TermKey.insert,
    LogicalKeyboardKey.delete => TermKey.delete,
    LogicalKeyboardKey.pageUp => TermKey.pageUp,
    LogicalKeyboardKey.pageDown => TermKey.pageDown,
    LogicalKeyboardKey.f1 => TermKey.f1,
    LogicalKeyboardKey.f2 => TermKey.f2,
    LogicalKeyboardKey.f3 => TermKey.f3,
    LogicalKeyboardKey.f4 => TermKey.f4,
    LogicalKeyboardKey.f5 => TermKey.f5,
    LogicalKeyboardKey.f6 => TermKey.f6,
    LogicalKeyboardKey.f7 => TermKey.f7,
    LogicalKeyboardKey.f8 => TermKey.f8,
    LogicalKeyboardKey.f9 => TermKey.f9,
    LogicalKeyboardKey.f10 => TermKey.f10,
    LogicalKeyboardKey.f11 => TermKey.f11,
    LogicalKeyboardKey.f12 => TermKey.f12,
    _ => null,
  };
}

/// The strip above the grid: what state this session is in, and the two toggles that change it.
class _TerminalStatusRow extends StatelessWidget {
  const _TerminalStatusRow({required this.vm, required this.session});

  final ShellViewModel vm;
  final ShellSession session;

  @override
  Widget build(BuildContext context) {
    final ended = !session.isOpen;

    return Container(
      height: 30,
      color: const Color(0xFF0B1017),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _status(),
              key: const ValueKey('shell.status'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: OmniFonts.mono,
                fontSize: 10,
                color: ended ? OmniColors.amber : const Color(0xFF7C8AA5),
              ),
            ),
          ),
          if (!ended)
            _Toggle(
              label: 'RO',
              tooltip: 'Read-only: refuse every keystroke',
              active: session.readOnly,
              keyName: 'shell.readOnly',
              onTap: () => session.setReadOnly(!session.readOnly),
            ),
          if (ended)
            TextButton(
              key: const ValueKey('shell.dismiss'),
              onPressed: () => vm.dismissEnded(session),
              child: const Text('Dismiss', style: TextStyle(fontSize: 11)),
            ),
        ],
      ),
    );
  }

  String _status() => switch (session.endReason) {
    ShellSessionEnd.open =>
      session.readOnly
          ? 'READ ONLY · ${session.cols}×${session.rows} · drag to scroll'
          : '${session.serverName} · ${session.cols}×${session.rows}',
    // The exit status is the useful part of a clean exit, so it is shown rather than summarised.
    ShellSessionEnd.remoteExited =>
      'Session ended (exit ${session.exitStatus ?? 0}). Scrollback kept.',
    // Named as a connection problem, not as an exit: the remote may well still be running, and
    // telling the user their shell "ended" would be a lie they act on.
    ShellSessionEnd.disconnected => 'Connection lost. Scrollback kept.',
    ShellSessionEnd.closedByUser => 'Closed.',
  };
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.label,
    required this.tooltip,
    required this.active,
    required this.keyName,
    required this.onTap,
  });

  final String label;
  final String tooltip;
  final bool active;
  final String keyName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      key: ValueKey(keyName),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: active ? OmniColors.amber.withValues(alpha: 0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: active ? OmniColors.amber : const Color(0xFF243044)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: OmniFonts.mono,
            fontSize: 10,
            color: active ? OmniColors.amber : const Color(0xFF7C8AA5),
          ),
        ),
      ),
    ),
  );
}

/// Two terminals at once, the app's headline Shell feature.
///
/// Each pane is an ordinary [_ActiveTerminal]; nothing about a session changes because it is in a
/// split. That is why this could be added late — `ShellSession` has owned its own geometry, scroll
/// position and read-only flag since it was first ported, so the surface reports its real grid to
/// the remote per pane and neither terminal learns the other exists.
class _SplitTerminals extends StatelessWidget {
  const _SplitTerminals({required this.vm, required this.first, required this.second});

  final ShellViewModel vm;
  final ShellSession first;
  final ShellSession second;

  @override
  Widget build(BuildContext context) {
    final panes = [
      Expanded(
        child: _FocusablePane(vm: vm, session: first, focused: true),
      ),
      const _SplitDivider(),
      Expanded(
        child: _FocusablePane(vm: vm, session: second, focused: false),
      ),
    ];

    return Column(
      key: const ValueKey('shell.splitView'),
      children: [
        _SplitControls(vm: vm),
        Expanded(
          child: vm.splitStacked ? Column(children: panes) : Row(children: panes),
        ),
      ],
    );
  }
}

class _SplitDivider extends StatelessWidget {
  const _SplitDivider();

  @override
  Widget build(BuildContext context) => Container(width: 1, height: 1, color: OmniColors.cyan);
}

/// A pane that takes focus when tapped, and shows which one has it.
///
/// Focus is not decoration here: every per-session action — keystrokes, the key bar, disconnect —
/// targets the focused pane, so a split with no visible focus would leave the user guessing which
/// terminal is about to receive what they type.
class _FocusablePane extends StatelessWidget {
  const _FocusablePane({required this.vm, required this.session, required this.focused});

  final ShellViewModel vm;
  final ShellSession session;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    // No gesture detector here on purpose — the terminal surface below claims the arena, so a
    // wrapper's tap would never fire. Focus is taken in `_ActiveTerminal`, where the tap lands.
    return DecoratedBox(
      key: ValueKey('shell.pane.${session.id}'),
      decoration: BoxDecoration(
        border: Border.all(color: focused ? OmniColors.cyan : Colors.transparent),
      ),
      child: _ActiveTerminal(vm: vm, session: session),
    );
  }
}

class _SplitControls extends StatelessWidget {
  const _SplitControls({required this.vm});

  final ShellViewModel vm;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('shell.splitControls'),
      height: 34,
      color: const Color(0xFF0B1017),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          TextButton.icon(
            key: const ValueKey('shell.split.axis'),
            icon: Icon(
              vm.splitStacked ? Icons.swap_vert : Icons.swap_horiz,
              size: 16,
              color: OmniColors.cyan,
            ),
            // Named for what the layout *is*, matching the Kotlin's own chips, so the button says
            // the current state rather than the action.
            label: Text(
              vm.splitStacked ? 'STACK' : 'COLS',
              style: const TextStyle(fontSize: 11, color: OmniColors.cyan),
            ),
            onPressed: vm.toggleSplitAxis,
          ),
          const Spacer(),
          TextButton(
            key: const ValueKey('shell.split.single'),
            onPressed: vm.unsplit,
            child: const Text('SINGLE', style: TextStyle(fontSize: 11, color: OmniColors.cyan)),
          ),
        ],
      ),
    );
  }
}

/// Picks the session for the second pane.
Future<void> _openSplitPicker(BuildContext context, ShellViewModel vm) async {
  final candidates = vm.splitCandidates;
  await showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Show alongside', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          if (candidates.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                // A split needs two terminals, and saying so beats an empty sheet.
                'Open a second session first — a split shows two of them at once.',
                key: ValueKey('shell.split.none'),
                style: TextStyle(fontSize: 12),
              ),
            )
          else
            for (final session in candidates)
              ListTile(
                key: ValueKey('shell.split.pick.${session.id}'),
                dense: true,
                title: Text(session.serverName, style: const TextStyle(fontSize: 13)),
                onTap: () {
                  vm.splitWith(session.id);
                  Navigator.of(sheetContext).pop();
                },
              ),
        ],
      ),
    ),
  );
}
