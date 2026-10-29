import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/code_highlighter.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

class HighlightEditingController extends TextEditingController {
  HighlightEditingController({super.text, required this.language, required this.maxChars});

  CodeLanguage language;
  int maxChars;
  HighlightPalette? palette;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final source = text;
    final colors = palette;
    if (colors == null || language == CodeLanguage.none || source.length > maxChars) {
      return TextSpan(text: source, style: style);
    }
    final children = <InlineSpan>[];
    var offset = 0;
    for (final token in highlightAll(source, language)) {
      if (token.start < offset || token.end > source.length) {
        continue;
      }
      if (token.start > offset) {
        children.add(TextSpan(text: source.substring(offset, token.start)));
      }
      children.add(
        TextSpan(
          text: source.substring(token.start, token.end),
          style: TextStyle(color: colors.colorFor(token.kind)),
        ),
      );
      offset = token.end;
    }
    if (offset < source.length) {
      children.add(TextSpan(text: source.substring(offset)));
    }
    return TextSpan(style: style, children: children);
  }
}

class HighlightPalette {
  const HighlightPalette({
    required this.comment,
    required this.string,
    required this.number,
    required this.key,
    required this.keyword,
  });

  final Color comment;
  final Color string;
  final Color number;
  final Color key;
  final Color keyword;

  factory HighlightPalette.forTheme(ThemeData theme) {
    final dark = theme.brightness == Brightness.dark;
    return dark
        ? const HighlightPalette(
            comment: Color(0xFF6B7A90),
            string: Color(0xFF6BE39B),
            number: Color(0xFFFFC04D),
            key: Color(0xFF4DD0E1),
            keyword: Color(0xFFCE93D8),
          )
        : const HighlightPalette(
            comment: Color(0xFF6A737D),
            string: Color(0xFF0A7D33),
            number: Color(0xFF9A5B00),
            key: Color(0xFF00697A),
            keyword: Color(0xFF7B1FA2),
          );
  }

  Color colorFor(HighlightKind kind) => switch (kind) {
    HighlightKind.comment => comment,
    HighlightKind.string => string,
    HighlightKind.number => number,
    HighlightKind.key => key,
    HighlightKind.keyword => keyword,
  };
}

/// Shared code editor used by SFTP and Compose raw YAML.
class CodeEditor extends StatefulWidget {
  const CodeEditor({
    super.key,
    required this.controller,
    required this.language,
    this.readOnly = false,
    this.enabled = true,
    this.maxHighlightChars = 100000,
    this.onChanged,
    this.textKey,
  });

  final TextEditingController controller;
  final CodeLanguage language;
  final bool readOnly;
  final bool enabled;
  final int maxHighlightChars;
  final ValueChanged<String>? onChanged;
  final Key? textKey;

  @override
  State<CodeEditor> createState() => _CodeEditorState();
}

class _CodeEditorState extends State<CodeEditor> {
  bool _findVisible = false;
  bool _wrap = false;
  bool _caseSensitive = false;
  bool _regex = false;
  final _query = TextEditingController();
  final _replacement = TextEditingController();
  final _goTo = TextEditingController();
  final _verticalScroll = ScrollController();
  final _horizontalScroll = ScrollController();
  String? _patternError;

  @override
  void dispose() {
    _query.dispose();
    _replacement.dispose();
    _goTo.dispose();
    _verticalScroll.dispose();
    _horizontalScroll.dispose();
    super.dispose();
  }

  /// Kotlin's `findMatches`: start/end pairs, with zero-width regex matches skipped.
  List<(int, int)> get _matches {
    _patternError = null;
    if (_query.text.isEmpty) return const [];
    try {
      final pattern = _regex ? _query.text : RegExp.escape(_query.text);
      return [
        for (final match in RegExp(
          pattern,
          caseSensitive: _caseSensitive,
        ).allMatches(widget.controller.text))
          if (match.end > match.start) (match.start, match.end),
      ];
    } on FormatException {
      _patternError = 'Invalid pattern';
      return const [];
    }
  }

  /// Kotlin's current match: the first one at or after the cursor, else the first.
  int _currentIndex(List<(int, int)> matches) {
    if (matches.isEmpty) return -1;
    final selection = widget.controller.selection;
    final cursor = selection.isValid ? math.min(selection.start, selection.end) : 0;
    final index = matches.indexWhere((match) => match.$1 >= cursor);
    return index < 0 ? 0 : index;
  }

  void _selectMatch(int index) {
    final matches = _matches;
    if (matches.isEmpty) return;
    final match = matches[(index % matches.length + matches.length) % matches.length];
    widget.controller.selection = TextSelection(baseOffset: match.$1, extentOffset: match.$2);
    setState(() {});
  }

  /// Replaces the current match: always one the search found, never an arbitrary selection.
  void _replaceCurrent() {
    final matches = _matches;
    final index = _currentIndex(matches);
    if (widget.readOnly || index < 0) return;
    final (start, end) = matches[index];
    final next = widget.controller.text.replaceRange(start, end, _replacement.text);
    widget.controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + _replacement.text.length),
    );
    widget.onChanged?.call(next);
    setState(() {});
  }

  void _replaceAll() {
    if (widget.readOnly || _query.text.isEmpty) return;
    try {
      final pattern = _regex ? _query.text : RegExp.escape(_query.text);
      final next = widget.controller.text.replaceAll(
        RegExp(pattern, caseSensitive: _caseSensitive),
        _replacement.text,
      );
      widget.controller.value = widget.controller.value.copyWith(
        text: next,
        selection: TextSelection.collapsed(
          offset: math.min(
            widget.controller.selection.baseOffset.clamp(0, next.length),
            next.length,
          ),
        ),
      );
      widget.onChanged?.call(next);
      setState(() {});
    } on FormatException {
      setState(() => _patternError = 'Invalid pattern');
    }
  }

  /// Kotlin's `goToLine`: the start of 1-based [line]; a line past the end goes to the start of the
  /// last line rather than the end of the buffer.
  void _goToLine(int line) {
    final text = widget.controller.text;
    var offset = 0;
    for (var current = 1; current < math.max(line, 1); current++) {
      final newline = text.indexOf('\n', offset);
      if (newline < 0) break;
      offset = newline + 1;
    }
    widget.controller.selection = TextSelection.collapsed(offset: offset);
  }

  Widget _findInput(String key, TextEditingController controller, String hint) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: TextField(
        key: ValueKey(key),
        controller: controller,
        style: TextStyle(fontFamily: OmniFonts.mono, fontSize: 12, color: scheme.onSurface),
        cursorColor: OmniColors.amber,
        decoration: InputDecoration.collapsed(
          hintText: hint,
          hintStyle: TextStyle(
            fontFamily: OmniFonts.mono,
            fontSize: 12,
            color: scheme.onSurfaceVariant,
          ),
        ),
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller is HighlightEditingController) {
      controller
        ..language = widget.language
        ..maxChars = widget.maxHighlightChars.clamp(0, highlightMaxCharsCap)
        ..palette = HighlightPalette.forTheme(Theme.of(context));
    }
    final scheme = Theme.of(context).colorScheme;
    final matches = _matches;
    final count = matches.length;
    final current = _currentIndex(matches);
    final enabled = widget.enabled;
    return Column(
      children: [
        // Kotlin's `EditorToolbar`.
        Container(
          color: scheme.surfaceContainer,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            children: [
              IconButton(
                key: const ValueKey('codeEditor.find'),
                tooltip: _findVisible ? 'Hide find' : 'Find / replace',
                onPressed: enabled ? () => setState(() => _findVisible = !_findVisible) : null,
                icon: Icon(
                  _findVisible ? Icons.close : Icons.search,
                  color: _findVisible ? OmniColors.cyan : scheme.onSurfaceVariant,
                ),
              ),
              IconButton(
                key: const ValueKey('codeEditor.wrap'),
                tooltip: _wrap ? 'Word wrap: on' : 'Word wrap: off',
                onPressed: enabled ? () => setState(() => _wrap = !_wrap) : null,
                icon: Icon(
                  Icons.wrap_text,
                  color: _wrap ? OmniColors.cyan : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 4),
              Text('Line', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
              const SizedBox(width: 4),
              Container(
                width: 56,
                color: scheme.surface,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: TextField(
                  key: const ValueKey('codeEditor.goToLine'),
                  controller: _goTo,
                  enabled: enabled,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(7),
                  ],
                  style: TextStyle(
                    fontFamily: OmniFonts.mono,
                    fontSize: 12,
                    color: scheme.onSurface,
                  ),
                  cursorColor: OmniColors.amber,
                  decoration: const InputDecoration.collapsed(hintText: ''),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              TextButton(
                key: const ValueKey('codeEditor.goToLine.go'),
                onPressed: enabled && _goTo.text.isNotEmpty
                    ? () => _goToLine(int.parse(_goTo.text))
                    : null,
                child: const Text('Go', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        // Kotlin's `FindReplaceBar`.
        if (_findVisible)
          Container(
            color: scheme.surfaceContainerHigh,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Column(
              spacing: 6,
              children: [
                Row(
                  children: [
                    Expanded(child: _findInput('codeEditor.query', _query, 'Find')),
                    const SizedBox(width: 6),
                    Text(
                      _query.text.isEmpty
                          ? ''
                          : count == 0
                          ? '0/0'
                          : '${current + 1}/$count',
                      key: const ValueKey('codeEditor.matchCount'),
                      style: TextStyle(
                        fontFamily: OmniFonts.mono,
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('codeEditor.previous'),
                      tooltip: 'Previous match',
                      onPressed: count > 0 ? () => _selectMatch(current - 1) : null,
                      icon: const Icon(Icons.arrow_upward, size: 18),
                    ),
                    IconButton(
                      key: const ValueKey('codeEditor.next'),
                      tooltip: 'Next match',
                      onPressed: count > 0 ? () => _selectMatch(current + 1) : null,
                      icon: const Icon(Icons.arrow_downward, size: 18),
                    ),
                    IconButton(
                      key: const ValueKey('codeEditor.closeFind'),
                      tooltip: 'Close find',
                      onPressed: () => setState(() => _findVisible = false),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: _findInput('codeEditor.replacement', _replacement, 'Replace with'),
                    ),
                    const SizedBox(width: 6),
                    // Shown in read-only mode too, as in Kotlin, but disabled there: a button that
                    // is enabled and does nothing is worse than one that says it cannot.
                    TextButton(
                      key: const ValueKey('codeEditor.replace'),
                      onPressed: !widget.readOnly && count > 0 ? _replaceCurrent : null,
                      child: const Text('Replace', style: TextStyle(fontSize: 12)),
                    ),
                    TextButton(
                      key: const ValueKey('codeEditor.replaceAll'),
                      onPressed: !widget.readOnly && count > 0 ? _replaceAll : null,
                      child: const Text('All', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
                Row(
                  spacing: 6,
                  children: [
                    FilterChip(
                      label: const Text('Aa', style: TextStyle(fontSize: 11)),
                      selected: _caseSensitive,
                      onSelected: (value) => setState(() => _caseSensitive = value),
                    ),
                    FilterChip(
                      label: const Text('.*', style: TextStyle(fontSize: 11)),
                      selected: _regex,
                      onSelected: (value) => setState(() => _regex = value),
                    ),
                    if (_patternError != null)
                      Text(
                        _patternError!,
                        style: const TextStyle(color: OmniColors.red, fontSize: 11),
                      ),
                  ],
                ),
              ],
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => _wrap
                ? _wrappedEditor(controller, constraints.maxWidth)
                : _unwrappedEditor(controller, constraints.maxWidth),
          ),
        ),
      ],
    );
  }

  static const _fontSize = 12.0;
  static const _lineHeight = _fontSize * 1.35;

  Widget _editorField(
    TextEditingController controller, {
    required bool expands,
    required ScrollController? scrollController,
  }) => TextField(
    key: widget.textKey ?? const ValueKey('codeEditor.text'),
    controller: controller,
    readOnly: widget.readOnly,
    enabled: widget.enabled,
    expands: expands,
    minLines: expands ? null : 1,
    maxLines: expands ? null : null,
    scrollController: scrollController,
    textAlignVertical: TextAlignVertical.top,
    style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: _fontSize, height: 1.35),
    decoration: InputDecoration(
      border: const OutlineInputBorder(),
      filled: true,
      fillColor: Theme.of(context).colorScheme.surfaceContainer,
      contentPadding: const EdgeInsets.all(10),
    ),
    onChanged: (value) {
      widget.onChanged?.call(value);
      setState(() {});
    },
  );

  Widget _wrappedEditor(TextEditingController controller, double width) {
    final gutterWidth = _gutterWidth(controller.text);
    final usableWidth = (width - gutterWidth - 22).clamp(40.0, double.infinity);
    // JetBrains Mono is roughly 0.6 em wide. The two-character margin accounts for the caret and
    // avoids claiming a logical line fits when the editable's internal padding wraps its last word.
    final columns = (usableWidth / (_fontSize * 0.6)).floor().clamp(1, 10000);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: gutterWidth,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _verticalScroll,
              builder: (context, child) => Transform.translate(
                offset: Offset(0, -(_verticalScroll.hasClients ? _verticalScroll.offset : 0.0)),
                child: child,
              ),
              child: _lineNumbers(controller.text, wrapColumns: columns),
            ),
          ),
        ),
        Expanded(child: _editorField(controller, expands: true, scrollController: _verticalScroll)),
      ],
    );
  }

  Widget _unwrappedEditor(TextEditingController controller, double width) {
    final gutterWidth = _gutterWidth(controller.text);
    final longest = controller.text
        .split('\n')
        .fold<int>(1, (value, line) => line.runes.length > value ? line.runes.length : value);
    final editorWidth = (longest * _fontSize * 0.62 + 30)
        .clamp((width - gutterWidth).clamp(40.0, double.infinity), double.infinity)
        .toDouble();
    return Scrollbar(
      controller: _verticalScroll,
      child: SingleChildScrollView(
        controller: _verticalScroll,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: gutterWidth, child: _lineNumbers(controller.text)),
            SizedBox(
              width: width - gutterWidth,
              child: Scrollbar(
                controller: _horizontalScroll,
                notificationPredicate: (notification) => notification.depth == 0,
                child: SingleChildScrollView(
                  controller: _horizontalScroll,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: editorWidth,
                    child: _editorField(controller, expands: false, scrollController: null),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  double _gutterWidth(String text) {
    final digits = text.split('\n').length.toString().length;
    return (digits * 8 + 22).clamp(38, 72).toDouble();
  }

  Widget _lineNumbers(String text, {int? wrapColumns}) {
    final lines = text.split('\n');
    return Padding(
      padding: const EdgeInsets.only(top: 11, right: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < lines.length; index++)
            SizedBox(
              height:
                  _lineHeight *
                  (wrapColumns == null
                      ? 1
                      : ((lines[index].runes.length + wrapColumns - 1) ~/ wrapColumns).clamp(
                          1,
                          100000,
                        )),
              child: Text(
                '${index + 1}',
                key: ValueKey('codeEditor.line.${index + 1}'),
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontFamily: OmniFonts.mono,
                  fontSize: 10,
                  height: _lineHeight / 10,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
