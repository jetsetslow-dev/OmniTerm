import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/terminal_key_encoder.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../view_model/shell_view_model.dart';

enum KeyBarLayer { nav, function, symbol }

/// Kotlin's two-row terminal keyboard, with its compact landscape-IME variant.
class TerminalKeyBar extends StatefulWidget {
  const TerminalKeyBar({super.key, required this.viewModel, this.compact = false});

  final ShellViewModel viewModel;
  final bool compact;

  @override
  State<TerminalKeyBar> createState() => _TerminalKeyBarState();
}

class _TerminalKeyBarState extends State<TerminalKeyBar> {
  KeyBarLayer _layer = KeyBarLayer.nav;

  static const _keys = <String, TermKey>{
    'ESC': TermKey.esc,
    'TAB': TermKey.tab,
    'HOME': TermKey.home,
    'END': TermKey.end,
    'PGUP': TermKey.pageUp,
    'PGDN': TermKey.pageDown,
    '←': TermKey.left,
    '↑': TermKey.up,
    '↓': TermKey.down,
    '→': TermKey.right,
    '⌫': TermKey.backspace,
    'DEL': TermKey.delete,
    '↵': TermKey.enter,
    'F1': TermKey.f1,
    'F2': TermKey.f2,
    'F3': TermKey.f3,
    'F4': TermKey.f4,
    'F5': TermKey.f5,
    'F6': TermKey.f6,
    'F7': TermKey.f7,
    'F8': TermKey.f8,
    'F9': TermKey.f9,
    'F10': TermKey.f10,
    'F11': TermKey.f11,
    'F12': TermKey.f12,
  };
  static const _repeatable = {'TAB', 'HOME', 'END', 'PGUP', 'PGDN', '←', '↑', '↓', '→', '⌫', 'DEL'};

  List<List<String>> get _rows {
    if (widget.compact) {
      return [
        switch (_layer) {
          KeyBarLayer.nav => [
            'ESC',
            'TAB',
            'CTRL',
            'ALT',
            'SHFT',
            '-',
            '/',
            'HOME',
            '←',
            '↑',
            '↓',
            '→',
            'END',
            'PGUP',
            'PGDN',
            '⌫',
            'DEL',
            '↵',
            'SYM',
            'FN',
          ],
          KeyBarLayer.function => [
            for (var n = 1; n <= 12; n++) 'F$n',
            'PGUP',
            'PGDN',
            'HOME',
            'END',
            'ESC',
            '⌫',
            'SYM',
            'NAV',
          ],
          KeyBarLayer.symbol => [
            '~',
            '_',
            '.',
            ':',
            ';',
            "'",
            '"',
            '`',
            r'$',
            '&',
            '*',
            '(',
            ')',
            '[',
            ']',
            '{',
            '}',
            '|',
            'SYM',
            'FN',
          ],
        },
      ];
    }
    return switch (_layer) {
      KeyBarLayer.nav => [
        ['ESC', 'CTRL', '-', '|', 'HOME', '↑', 'END', 'PGUP', '⌫', 'DEL', 'FN'],
        ['TAB', 'ALT', '/', '~', '←', '↓', '→', 'PGDN', '↵', 'SHFT', 'SYM'],
      ],
      KeyBarLayer.function => [
        ['F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'PGUP', 'HOME', '↑', 'ESC', 'NAV'],
        ['F7', 'F8', 'F9', 'F10', 'F11', 'F12', 'PGDN', 'END', '↓', '⌫', 'SYM'],
      ],
      KeyBarLayer.symbol => [
        ['~', '_', '.', ':', ';', "'", '"', '`', '|', '\\', 'FN'],
        [r'$', '&', '*', '(', ')', '[', ']', '{', '}', '!', 'SYM'],
      ],
    };
  }

  void _press(String label) {
    final vm = widget.viewModel;
    switch (label) {
      case 'CTRL':
        vm.toggleCtrl();
      case 'ALT':
        vm.toggleAlt();
      case 'SHFT':
        vm.toggleShift();
      case 'FN':
        setState(() => _layer = KeyBarLayer.function);
      case 'NAV':
        setState(() => _layer = KeyBarLayer.nav);
      case 'SYM':
        setState(
          () => _layer = _layer == KeyBarLayer.symbol ? KeyBarLayer.nav : KeyBarLayer.symbol,
        );
      default:
        final key = _keys[label];
        if (key != null) {
          vm.sendKey(key);
        } else {
          vm.typeText(label);
        }
    }
  }

  Widget _cap(String label) {
    final vm = widget.viewModel;
    final active = switch (label) {
      'CTRL' => vm.ctrl,
      'ALT' => vm.alt,
      'SHFT' => vm.shift,
      'SYM' || 'FN' || 'NAV' => true,
      _ => false,
    };
    return _TerminalKeyCap(
      key: ValueKey('shell.key.$label'),
      label: label,
      active: active,
      activeColor: label == 'SYM' ? OmniColors.purple : OmniColors.amber,
      repeatable: _repeatable.contains(label),
      onPressed: () => _press(label),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.viewModel,
    builder: (context, _) {
      final readOnly = widget.viewModel.current?.readOnly ?? false;
      final scheme = Theme.of(context).colorScheme;
      return ColoredBox(
        key: const ValueKey('shell.keyBar'),
        color: scheme.surface,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: readOnly ? 6 : 4, vertical: 4),
          child: readOnly
              ? Row(
                  key: const ValueKey('shell.keyBar.readOnly'),
                  children: [
                    Expanded(
                      flex: 2,
                      child: Text(
                        'READ ONLY · drag to scroll',
                        style: TextStyle(
                          fontFamily: OmniFonts.mono,
                          fontSize: 10,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(child: _cap('PGUP')),
                    const SizedBox(width: 6),
                    Expanded(child: _cap('PGDN')),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var row = 0; row < _rows.length; row++) ...[
                      if (row != 0) const SizedBox(height: 4),
                      Row(children: [for (final label in _rows[row]) Expanded(child: _cap(label))]),
                    ],
                  ],
                ),
        ),
      );
    },
  );
}

/// Repeat the same navigation/editing keys Kotlin repeats: press, 400 ms delay, then every 60 ms.
/// Releasing, cancelling, replacing the cap or leaving the app ends the repeat immediately.
class _TerminalKeyCap extends StatefulWidget {
  const _TerminalKeyCap({
    super.key,
    required this.label,
    required this.active,
    required this.activeColor,
    required this.repeatable,
    required this.onPressed,
  });

  final String label;
  final bool active;
  final Color activeColor;
  final bool repeatable;
  final VoidCallback onPressed;

  @override
  State<_TerminalKeyCap> createState() => _TerminalKeyCapState();
}

class _TerminalKeyCapState extends State<_TerminalKeyCap> with WidgetsBindingObserver {
  Timer? _repeat;
  int? _pointer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _press() {
    unawaited(HapticFeedback.selectionClick());
    widget.onPressed();
  }

  void _start(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    _press();
    _repeat = Timer(const Duration(milliseconds: 400), () {
      _press();
      _repeat = Timer.periodic(const Duration(milliseconds: 60), (_) => _press());
    });
  }

  void _stop() {
    _repeat?.cancel();
    _repeat = null;
    _pointer = null;
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      _stop();
      return;
    }
    // Compose cancels a held key when the pointer leaves its touch target. Retain the same
    // minimum 48-dp target around a narrow/short cap, then end the repeat outside that target.
    final dx = (48 - box.size.width).clamp(0.0, 48.0) / 2;
    final dy = (48 - box.size.height).clamp(0.0, 48.0) / 2;
    final bounds = Rect.fromLTRB(-dx, -dy, box.size.width + dx, box.size.height + dy);
    if (!bounds.contains(event.localPosition)) _stop();
  }

  void _release(PointerEvent event) {
    if (event.pointer == _pointer) _stop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _stop();
  }

  @override
  void didUpdateWidget(covariant _TerminalKeyCap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.label != oldWidget.label || widget.repeatable != oldWidget.repeatable) _stop();
  }

  @override
  void deactivate() {
    _stop();
    super.deactivate();
  }

  @override
  void dispose() {
    _stop();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cap = Container(
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: widget.active ? widget.activeColor : scheme.surfaceContainerHigh,
        border: Border.all(color: widget.active ? widget.activeColor : scheme.outline),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        widget.label,
        maxLines: 1,
        style: TextStyle(
          fontFamily: OmniFonts.mono,
          fontSize: widget.label == '↵' || widget.label == '-' ? 18 : 12,
          fontWeight: FontWeight.bold,
          color: widget.active ? Colors.black : scheme.onSurface,
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: widget.repeatable
          ? Semantics(
              button: true,
              onTap: _press,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _start,
                onPointerMove: _move,
                onPointerUp: _release,
                onPointerCancel: _release,
                child: cap,
              ),
            )
          : InkWell(onTap: _press, canRequestFocus: false, child: cap),
    );
  }
}
