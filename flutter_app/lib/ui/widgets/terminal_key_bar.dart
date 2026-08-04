import 'package:flutter/material.dart';

import '../../domain/terminal_key_encoder.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../view_model/shell_view_model.dart';

/// Which set of caps the bar is showing.
enum KeyBarLayer { nav, function, symbol }

/// The on-screen key bar, ported from `TerminalKeyBar` in `ui/ShellScreen.kt`.
///
/// A software keyboard has none of the keys a terminal needs — no Esc, no Ctrl, no arrows, no
/// function row — so this bar is not a convenience, it is the difference between the terminal being
/// usable and not.
class TerminalKeyBar extends StatefulWidget {
  const TerminalKeyBar({super.key, required this.viewModel});

  final ShellViewModel viewModel;

  @override
  State<TerminalKeyBar> createState() => _TerminalKeyBarState();
}

class _TerminalKeyBarState extends State<TerminalKeyBar> {
  KeyBarLayer _layer = KeyBarLayer.nav;

  void _show(KeyBarLayer layer) => setState(() => _layer = layer);

  @override
  Widget build(BuildContext context) {
    final vm = widget.viewModel;

    return ListenableBuilder(
      listenable: vm,
      builder: (context, _) => Container(
        key: const ValueKey('shell.keyBar'),
        color: const Color(0xFF10151F),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(children: _caps(vm).map((cap) => Expanded(child: cap)).toList()),
      ),
    );
  }

  /// Every layer emits the same number of caps, and SYM/FN are always the last two.
  ///
  /// That fixed geometry is deliberate: a cap that moves between layers gets pressed by mistake,
  /// and on a terminal a mis-pressed key is a command you did not mean to run.
  List<Widget> _caps(ShellViewModel vm) => switch (_layer) {
    KeyBarLayer.symbol => [
      for (final symbol in const [
        '~', '_', '.', ':', ';', "'", '"', '`', //
        r'$', '&', '*', '(', ')', '[', ']', '{', '}', '|',
      ])
        _cap(symbol, onTap: () => vm.typeText(symbol)),
      _cap(
        'SYM',
        active: true,
        activeColor: OmniColors.purple,
        onTap: () => _show(KeyBarLayer.nav),
      ),
      _cap(
        'FN',
        active: true,
        activeColor: OmniColors.amber,
        onTap: () => _show(KeyBarLayer.function),
      ),
    ],
    KeyBarLayer.function => [
      for (var n = 1; n <= 12; n++) _cap('F$n', onTap: () => vm.sendKey(_functionKey(n))),
      _cap('PGUP', onTap: () => vm.sendKey(TermKey.pageUp)),
      _cap('PGDN', onTap: () => vm.sendKey(TermKey.pageDown)),
      _cap('HOME', onTap: () => vm.sendKey(TermKey.home)),
      _cap('END', onTap: () => vm.sendKey(TermKey.end)),
      _cap('ESC', onTap: () => vm.sendKey(TermKey.esc)),
      _cap('⌫', onTap: () => vm.sendKey(TermKey.backspace)),
      _cap(
        'SYM',
        active: true,
        activeColor: OmniColors.purple,
        onTap: () => _show(KeyBarLayer.symbol),
      ),
      _cap('NAV', active: true, activeColor: OmniColors.amber, onTap: () => _show(KeyBarLayer.nav)),
    ],
    // ESC TAB CTRL ALT SHFT │ - / │ HOME ← ↑ ↓ → END │ PGUP PGDN ⌫ DEL ↵ │ SYM FN
    //
    // The arrows stay one contiguous run centred on the bar: an inverted T is impossible in a
    // single row, and splitting them around HOME/END made the cluster hard to hit blind.
    KeyBarLayer.nav => [
      _cap('ESC', onTap: () => vm.sendKey(TermKey.esc)),
      _cap('TAB', onTap: () => vm.sendKey(TermKey.tab)),
      _cap('CTRL', active: vm.ctrl, onTap: vm.toggleCtrl),
      _cap('ALT', active: vm.alt, onTap: vm.toggleAlt),
      _cap('SHFT', active: vm.shift, onTap: vm.toggleShift),
      _cap('-', onTap: () => vm.typeText('-')),
      _cap('/', onTap: () => vm.typeText('/')),
      _cap('HOME', onTap: () => vm.sendKey(TermKey.home)),
      _cap('←', onTap: () => vm.sendKey(TermKey.left)),
      _cap('↑', onTap: () => vm.sendKey(TermKey.up)),
      _cap('↓', onTap: () => vm.sendKey(TermKey.down)),
      _cap('→', onTap: () => vm.sendKey(TermKey.right)),
      _cap('END', onTap: () => vm.sendKey(TermKey.end)),
      _cap('PGUP', onTap: () => vm.sendKey(TermKey.pageUp)),
      _cap('PGDN', onTap: () => vm.sendKey(TermKey.pageDown)),
      _cap('⌫', onTap: () => vm.sendKey(TermKey.backspace)),
      _cap('DEL', onTap: () => vm.sendKey(TermKey.delete)),
      _cap('↵', onTap: () => vm.sendKey(TermKey.enter)),
      _cap(
        'SYM',
        active: true,
        activeColor: OmniColors.purple,
        onTap: () => _show(KeyBarLayer.symbol),
      ),
      _cap(
        'FN',
        active: true,
        activeColor: OmniColors.amber,
        onTap: () => _show(KeyBarLayer.function),
      ),
    ],
  };

  static TermKey _functionKey(int n) => const [
    TermKey.f1, TermKey.f2, TermKey.f3, TermKey.f4, TermKey.f5, TermKey.f6, //
    TermKey.f7, TermKey.f8, TermKey.f9, TermKey.f10, TermKey.f11, TermKey.f12,
  ][n - 1];

  Widget _cap(
    String label, {
    required VoidCallback onTap,
    bool active = false,
    Color activeColor = OmniColors.cyan,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 1),
    child: InkWell(
      key: ValueKey('shell.key.$label'),
      onTap: onTap,
      child: Container(
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? activeColor.withValues(alpha: 0.22) : const Color(0xFF1B2233),
          borderRadius: BorderRadius.circular(4),
          border: active ? Border.all(color: activeColor, width: 1) : null,
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.clip,
          style: TextStyle(
            fontFamily: OmniFonts.mono,
            fontSize: label.length > 3 ? 9 : 11,
            color: active ? activeColor : const Color(0xFFB8C4D8),
          ),
        ),
      ),
    ),
  );
}
