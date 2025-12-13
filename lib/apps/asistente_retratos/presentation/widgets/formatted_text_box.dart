// lib/apps/asistente_retratos/presentation/widgets/formatted_text_box.dart
import 'dart:convert' show JsonEncoder, jsonDecode;
import 'dart:ui' as ui show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

class FormattedTextBox extends StatefulWidget {
  const FormattedTextBox({
    super.key,
    required this.text,
    this.title = 'Resultado',
    this.maxHeight,
    this.child,
    this.copyText,
    this.collapsible = false,
    this.initiallyExpanded = true,
  });

  final String text;
  final String title;
  final double? maxHeight;
  final Widget? child;
  final String? copyText;
  final bool collapsible;
  final bool initiallyExpanded;

  @override
  State<FormattedTextBox> createState() => _FormattedTextBoxState();
}

class _FormattedTextBoxState extends State<FormattedTextBox> {
  late final ScrollController _scrollController = ScrollController();
  late bool _expanded = widget.initiallyExpanded;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
    if (!widget.collapsible) return;
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rawTrimmed = widget.text.trim();
    final formatted = widget.child == null ? _prettyFormat(widget.text) : '';
    final copySource = (widget.copyText ??
            (widget.child == null ? formatted : rawTrimmed))
        .trim();
    if (widget.child == null && formatted.isEmpty) return const SizedBox.shrink();
    if (widget.child != null && rawTrimmed.isEmpty && copySource.isEmpty) {
      return const SizedBox.shrink();
    }
    final effectiveMaxHeight = widget.maxHeight ?? 240.0;

    final baseStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          height: 1.35,
          color: scheme.onSurface,
        ) ??
        TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          height: 1.35,
          color: scheme.onSurface,
        );

    final Widget scrollChild;
    if (widget.child != null) {
      scrollChild = widget.child!;
    } else {
      final spans = _jsonSyntaxHighlight(
        formatted,
        scheme,
        baseStyle,
      );
      scrollChild = Text.rich(
        TextSpan(children: spans),
        style: baseStyle,
      );
    }

    final content = Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: SelectionArea(
          child: scrollChild,
        ),
      ),
    );

    final shouldShowContent = !widget.collapsible || _expanded;

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surface.withOpacity(0.72),
            border: Border.all(
              color: scheme.outlineVariant.withOpacity(0.35),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Header(
                title: widget.title,
                collapsible: widget.collapsible,
                expanded: _expanded,
                onToggle: _toggleExpanded,
                onCopy: () async {
                  await Clipboard.setData(ClipboardData(text: copySource));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copiado al portapapeles')),
                  );
                },
              ),
              AnimatedCrossFade(
                firstChild: const SizedBox.shrink(),
                secondChild: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: effectiveMaxHeight),
                  child: content,
                ),
                crossFadeState: shouldShowContent
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 220),
                reverseDuration: const Duration(milliseconds: 160),
                sizeCurve: Curves.easeOutCubic,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _prettyFormat(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    try {
      final obj = jsonDecode(trimmed);
      return const JsonEncoder.withIndent('  ').convert(obj);
    } catch (_) {
      return trimmed;
    }
  }

  static List<TextSpan> _jsonSyntaxHighlight(
    String source,
    ColorScheme scheme,
    TextStyle baseStyle,
  ) {
    final re = RegExp(
      r'"(?:\\.|[^"\\])*"'
      r'|\s+'
      r'|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?'
      r'|true|false|null'
      r'|[{}\[\]:,]',
    );

    final matches = re.allMatches(source).toList(growable: false);
    if (matches.isEmpty) {
      return [TextSpan(text: source)];
    }

    final tokens = <String>[];
    var lastEnd = 0;
    for (final m in matches) {
      if (m.start > lastEnd) {
        tokens.add(source.substring(lastEnd, m.start));
      }
      tokens.add(m.group(0)!);
      lastEnd = m.end;
    }
    if (lastEnd < source.length) {
      tokens.add(source.substring(lastEnd));
    }

    final spans = <TextSpan>[];
    for (var i = 0; i < tokens.length; i++) {
      final t = tokens[i];
      final isWhitespace = t.trim().isEmpty;

      TextStyle? style;
      if (isWhitespace) {
        style = null;
      } else if (t.startsWith('"')) {
        final isKey = _isJsonKeyToken(tokens, i);
        style = baseStyle.copyWith(
          color: isKey ? scheme.primary : scheme.onSurface,
          fontWeight: isKey ? FontWeight.w600 : FontWeight.w400,
        );
      } else if (t == 'true' || t == 'false' || t == 'null') {
        style = baseStyle.copyWith(
          color: scheme.secondary,
          fontWeight: FontWeight.w600,
        );
      } else if (_looksLikeNumber(t)) {
        style = baseStyle.copyWith(
          color: scheme.tertiary,
          fontWeight: FontWeight.w600,
        );
      } else if (_isPunctuation(t)) {
        style = baseStyle.copyWith(color: scheme.outline);
      } else {
        style = baseStyle;
      }

      spans.add(TextSpan(text: t, style: style));
    }
    return spans;
  }

  static bool _isJsonKeyToken(List<String> tokens, int i) {
    for (var j = i + 1; j < tokens.length; j++) {
      final next = tokens[j];
      if (next.trim().isEmpty) continue;
      return next == ':';
    }
    return false;
  }

  static bool _looksLikeNumber(String t) {
    if (t.isEmpty) return false;
    final c = t.codeUnitAt(0);
    return (c >= 48 && c <= 57) || c == 45;
  }

  static bool _isPunctuation(String t) =>
      t.length == 1 && '{}[]:,'.contains(t);
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.collapsible,
    required this.expanded,
    required this.onToggle,
    required this.onCopy,
  });

  final String title;
  final bool collapsible;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.titleSmall?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w700,
        ) ??
        TextStyle(
          color: scheme.onSurface,
          fontWeight: FontWeight.w700,
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
      child: Row(
        children: [
          Icon(Icons.data_object, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              onTap: collapsible ? onToggle : null,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: textStyle,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (collapsible)
                      AnimatedRotation(
                        turns: expanded ? 0.5 : 0.0,
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOut,
                        child: Icon(
                          Icons.expand_more_rounded,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: onCopy,
            tooltip: 'Copiar',
            icon: const Icon(Icons.copy_rounded),
          ),
        ],
      ),
    );
  }
}
