import 'package:flutter/material.dart';

import '../../domain/code_highlighter.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import 'omni_components.dart';

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
  final _verticalScroll = ScrollController();
  final _horizontalScroll = ScrollController();
  String? _patternError;

  @override
  void dispose() {
    _query.dispose();
    _replacement.dispose();
    _verticalScroll.dispose();
    _horizontalScroll.dispose();
    super.dispose();
  }

  List<RegExpMatch> get _matches {
    if (_query.text.isEmpty) return const [];
    try {
      _patternError = null;
      final pattern = _regex ? _query.text : RegExp.escape(_query.text);
      return RegExp(
        pattern,
        caseSensitive: _caseSensitive,
      ).allMatches(widget.controller.text).toList();
    } on FormatException {
      _patternError = 'Invalid pattern';
      return const [];
    }
  }

  void _selectMatch({required bool previous}) {
    final matches = _matches;
    if (matches.isEmpty) return;
    final cursor = widget.controller.selection.isValid ? widget.controller.selection.start : 0;
    RegExpMatch match;
    if (previous) {
      match = matches.lastWhere((item) => item.end < cursor, orElse: () => matches.last);
    } else {
      match = matches.firstWhere((item) => item.start > cursor, orElse: () => matches.first);
    }
    widget.controller.selection = TextSelection(baseOffset: match.start, extentOffset: match.end);
    setState(() {});
  }

  void _replaceCurrent() {
    if (widget.readOnly) return;
    final selection = widget.controller.selection;
    if (!selection.isValid || selection.isCollapsed) return;
    // Replace what the *search* found, not whatever happens to be selected. Without this, a query
    // matching nothing plus an ordinary hand-made selection turned Replace into "delete my
    // selection": the button was live, the selection was valid, and no match was ever consulted.
    final selected = _matches.any(
      (match) => match.start == selection.start && match.end == selection.end,
    );
    if (!selected) return;
    final next = widget.controller.text.replaceRange(
      selection.start,
      selection.end,
      _replacement.text,
    );
    widget.controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: selection.start + _replacement.text.length),
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
      widget.controller.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
      widget.onChanged?.call(next);
      setState(() => _patternError = null);
    } on FormatException {
      setState(() => _patternError = 'Invalid pattern');
    }
  }

  Future<void> _goToLine() async {
    var entered = '';
    final line = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Go to line'),
        content: TextField(
          key: const ValueKey('codeEditor.goToLine.value'),
          autofocus: true,
          keyboardType: TextInputType.number,
          onChanged: (value) => entered = value,
          decoration: omniInputDecoration(dialogContext, labelText: 'Line number'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, int.tryParse(entered)),
            child: const Text('Go'),
          ),
        ],
      ),
    );
    if (line == null || line < 1) return;
    var offset = 0;
    for (var current = 1; current < line; current++) {
      final newline = widget.controller.text.indexOf('\n', offset);
      if (newline < 0) {
        offset = widget.controller.text.length;
        break;
      }
      offset = newline + 1;
    }
    widget.controller.selection = TextSelection.collapsed(offset: offset);
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
    final count = _matches.length;
    return Column(
      children: [
        Row(
          children: [
            IconButton(
              key: const ValueKey('codeEditor.find'),
              tooltip: 'Find and replace',
              onPressed: () => setState(() => _findVisible = !_findVisible),
              icon: const Icon(Icons.find_replace, size: 20),
            ),
            IconButton(
              key: const ValueKey('codeEditor.goToLine'),
              tooltip: 'Go to line',
              onPressed: _goToLine,
              icon: const Icon(Icons.format_list_numbered, size: 20),
            ),
            IconButton(
              key: const ValueKey('codeEditor.wrap'),
              tooltip: _wrap ? 'Word wrap: on' : 'Word wrap: off',
              onPressed: () => setState(() => _wrap = !_wrap),
              color: _wrap ? OmniColors.cyan : null,
              icon: const Icon(Icons.wrap_text, size: 20),
            ),
            const Spacer(),
            Text(
              '${controller.text.split('\n').length} lines',
              style: const TextStyle(fontSize: 10),
            ),
          ],
        ),
        if (_findVisible)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('codeEditor.query'),
                        controller: _query,
                        decoration: omniInputDecoration(context, hintText: 'Find'),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Previous match',
                      onPressed: count > 0 ? () => _selectMatch(previous: true) : null,
                      icon: const Icon(Icons.keyboard_arrow_up),
                    ),
                    IconButton(
                      tooltip: 'Next match',
                      onPressed: count > 0 ? () => _selectMatch(previous: false) : null,
                      icon: const Icon(Icons.keyboard_arrow_down),
                    ),
                    Text('$count', style: const TextStyle(fontSize: 11)),
                  ],
                ),
                if (!widget.readOnly)
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const ValueKey('codeEditor.replacement'),
                          controller: _replacement,
                          decoration: omniInputDecoration(context, hintText: 'Replace with'),
                        ),
                      ),
                      TextButton(
                        onPressed: count > 0 ? _replaceCurrent : null,
                        child: const Text('Replace'),
                      ),
                      TextButton(
                        onPressed: count > 0 ? _replaceAll : null,
                        child: const Text('All'),
                      ),
                    ],
                  ),
                Row(
                  children: [
                    FilterChip(
                      label: const Text('Aa'),
                      selected: _caseSensitive,
                      onSelected: (value) => setState(() => _caseSensitive = value),
                    ),
                    const SizedBox(width: 6),
                    FilterChip(
                      label: const Text('.*'),
                      selected: _regex,
                      onSelected: (value) => setState(() => _regex = value),
                    ),
                    if (_patternError != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(
                          _patternError!,
                          style: const TextStyle(color: OmniColors.red, fontSize: 11),
                        ),
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
