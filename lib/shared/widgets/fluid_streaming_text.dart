import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../theme/motion_tokens.dart';

/// Renders appended glyphs with a restrained rolling fade.
///
/// The already-settled prefix never animates. Provider chunks are tracked as
/// independent ranges, so a new chunk does not restart or dim older text.
/// This widget intentionally changes paint only: layout, selection, semantics,
/// and the Markdown tree remain owned by the original [Text].
class FluidStreamingText extends StatefulWidget {
  const FluidStreamingText({
    super.key,
    required this.text,
    required this.streaming,
    this.revealDuration = AppMotion.streamingReveal,
  });

  final Text text;
  final bool streaming;
  final Duration revealDuration;

  @override
  State<FluidStreamingText> createState() => _FluidStreamingTextState();
}

class _FluidStreamingTextState extends State<FluidStreamingText>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  final List<_RevealRange> _ranges = <_RevealRange>[];
  Duration _elapsed = Duration.zero;
  late String _plainText = _textOf(widget.text);
  var _initialized = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    if (widget.streaming &&
        _plainText.isNotEmpty &&
        !(MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      _ranges.add(
        _RevealRange(start: 0, end: _plainText.length, born: Duration.zero),
      );
      _ticker.start();
    }
  }

  @override
  void didUpdateWidget(covariant FluidStreamingText oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _textOf(widget.text);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.streaming && !reduceMotion) {
      if (!_ticker.isActive) {
        _elapsed = Duration.zero;
        _ranges.clear();
        _ticker.start();
      }
      if (next.length > _plainText.length && next.startsWith(_plainText)) {
        _ranges.add(
          _RevealRange(
            start: _plainText.length,
            end: next.length,
            born: _elapsed,
          ),
        );
      } else if (next != _plainText) {
        _ranges.clear();
      }
    } else {
      _ranges.clear();
      if (_ticker.isActive) _ticker.stop();
    }
    _plainText = next;
  }

  void _onTick(Duration elapsed) {
    _elapsed = elapsed;
    if (_ranges.isEmpty || !mounted) {
      if (_ticker.isActive) _ticker.stop();
      return;
    }
    final durationUs = widget.revealDuration.inMicroseconds;
    _ranges.removeWhere(
      (range) =>
          elapsed.inMicroseconds - range.born.inMicroseconds >= durationUs,
    );
    if (_ranges.isEmpty) _ticker.stop();
    setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.streaming ||
        _ranges.isEmpty ||
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      return widget.text;
    }

    final inlineSpan = widget.text.textSpan;
    if (inlineSpan != null && inlineSpan is! TextSpan) {
      return widget.text;
    }
    final TextSpan root = inlineSpan is TextSpan
        ? inlineSpan
        : TextSpan(text: widget.text.data);
    final fallbackColor = DefaultTextStyle.of(context).style.color;
    var offset = 0;
    final faded = _fadeSpan(root, fallbackColor, () => offset, (value) {
      offset = value;
    });
    return Text.rich(
      faded,
      style: widget.text.style,
      strutStyle: widget.text.strutStyle,
      textAlign: widget.text.textAlign,
      textDirection: widget.text.textDirection,
      locale: widget.text.locale,
      softWrap: widget.text.softWrap,
      overflow: widget.text.overflow,
      textScaler: widget.text.textScaler,
      maxLines: widget.text.maxLines,
      semanticsLabel: widget.text.semanticsLabel,
      textWidthBasis: widget.text.textWidthBasis,
      textHeightBehavior: widget.text.textHeightBehavior,
      selectionColor: widget.text.selectionColor,
    );
  }

  TextSpan _fadeSpan(
    TextSpan span,
    Color? fallbackColor,
    int Function() readOffset,
    void Function(int) writeOffset,
  ) {
    final content = span.text;
    final children = <InlineSpan>[];
    if (content != null && content.isNotEmpty) {
      final start = readOffset();
      final end = start + content.length;
      final cuts = <int>{start, end};
      for (final range in _ranges) {
        if (range.end <= start || range.start >= end) continue;
        cuts
          ..add(math.max(start, range.start))
          ..add(math.min(end, range.end));
      }
      final sorted = cuts.toList()..sort();
      for (var i = 0; i < sorted.length - 1; i++) {
        final partStart = sorted[i];
        final partEnd = sorted[i + 1];
        final opacity = _opacityAt(partStart);
        children.add(
          TextSpan(
            text: content.substring(partStart - start, partEnd - start),
            style: _withOpacity(span.style, fallbackColor, opacity),
            recognizer: span.recognizer,
            mouseCursor: span.mouseCursor,
            onEnter: span.onEnter,
            onExit: span.onExit,
            semanticsLabel: span.semanticsLabel,
            locale: span.locale,
            spellOut: span.spellOut,
          ),
        );
      }
      writeOffset(end);
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      if (child is TextSpan) {
        children.add(_fadeSpan(child, fallbackColor, readOffset, writeOffset));
      } else {
        // Widget spans occupy one object-replacement character in plain text.
        children.add(child);
        writeOffset(readOffset() + 1);
      }
    }
    return TextSpan(
      style: span.style,
      children: children,
      recognizer: span.recognizer,
      mouseCursor: span.mouseCursor,
      onEnter: span.onEnter,
      onExit: span.onExit,
      semanticsLabel: span.semanticsLabel,
      locale: span.locale,
      spellOut: span.spellOut,
    );
  }

  double _opacityAt(int offset) {
    for (final range in _ranges.reversed) {
      if (offset < range.start || offset >= range.end) continue;
      final elapsedUs = _elapsed.inMicroseconds - range.born.inMicroseconds;
      final t = (elapsedUs / widget.revealDuration.inMicroseconds).clamp(
        0.0,
        1.0,
      );
      return 0.22 + 0.78 * AppMotion.enter.transform(t);
    }
    return 1;
  }

  static TextStyle? _withOpacity(
    TextStyle? style,
    Color? fallbackColor,
    double opacity,
  ) {
    if (opacity >= 1 || style?.foreground != null) return style;
    final color = style?.color ?? fallbackColor;
    if (color == null) return style;
    return (style ?? const TextStyle()).copyWith(
      color: color.withValues(alpha: color.a * opacity),
    );
  }

  static String _textOf(Text text) =>
      text.textSpan?.toPlainText(includeSemanticsLabels: false) ??
      text.data ??
      '';
}

class _RevealRange {
  const _RevealRange({
    required this.start,
    required this.end,
    required this.born,
  });

  final int start;
  final int end;
  final Duration born;
}
