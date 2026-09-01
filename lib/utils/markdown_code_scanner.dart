/// Single source of truth for markdown code recognition: inline code spans
/// (backtick runs) and fenced code blocks (```` ``` ```` / `~~~`).
///
/// Consumers (all driven by these rules, no private copies):
/// - the render pipeline in `widgets/markdown_with_highlight.dart`
/// - the streaming line lexer in `widgets/markdown_line_lexer.dart`
/// - the display-math scanner in `widgets/markdown_line_lexer.dart` (
///   keep their own state machines; only the rules are shared)
/// - the chat API image extractor in `services/api/chat_api_service.dart`
/// - the TTS code removal in `services/tts/tts_text_selection.dart` and
///   `providers/tts_provider.dart` ([markdownRemoveCode])
///
/// Core rules (CommonMark except where noted):
/// - A fence opens on a complete line holding a run of >= 3 backticks or
///   tildes after arbitrary horizontal indent (the app widens CommonMark's
///   0-3 spaces: LLMs emit deeper-indented fences); the info string is the
///   remainder of that line, trimmed.
/// - A fence closes on a line with the same marker, run length >= the
///   opening run, and only horizontal whitespace afterwards. A line with
///   trailing content (e.g. "``` not-a-closer") does NOT close.
/// - App extensions ported verbatim:
///   * an opener inside a blockquote (`^[ \t]*>...`) is a *quote fence*;
///   * an opener written after a list marker on the same line (backticks
///     only; info string without whitespace, like the legacy bullet-fence
///     rewrite) is a *list fence*;
///   * inside an open fence a line that merely ENDS with a run of >= the
///     opening length preceded by a non-backtick character closes it (LLMs
///     emit "}```" closers; CommonMark would keep the fence open).
/// - A code span pairs an opening backtick run that is not preceded by an
///   odd number of backslashes (the app's escape convention) with the next
///   run of the exact same length on the same line. Backslashes inside a
///   span are literal; a backtick inside a span closes it even when it is
///   immediately preceded by a backslash (CommonMark: no escapes in spans).
///
/// The details walker hides HTML tags inside backtick runs to protect the
/// `<details>` renderer; that hiding rule is deliberately one step WIDER:
/// [markdownCodePairInline] with `escapeSensitive: false` pairs all runs so
/// that prose like "`<details>` with an escaped opening backtick is never
/// lifted into a details card.
library;

enum MarkdownCodeFenceMarker { backtick, tilde }

enum MarkdownCodeSegmentKind { inlineCode, codeBlock }

enum MarkdownCodeFenceContext { none, blockquote, list }

class MarkdownCodeFenceMark {
  const MarkdownCodeFenceMark({
    required this.start,
    required this.length,
    required this.marker,
    required this.canClose,
  });

  final int start;
  final int length;
  final MarkdownCodeFenceMarker marker;

  /// True when everything after the run is horizontal whitespace.
  final bool canClose;
}

class MarkdownCodeInlinePair {
  const MarkdownCodeInlinePair({
    required this.openStart,
    required this.openLength,
    required this.closeStart,
    required this.closeLength,
  });

  final int openStart;
  final int openLength;
  final int closeStart;
  final int closeLength;

  int get openEnd => openStart + openLength;
  int get closeEnd => closeStart + closeLength;
}

class MarkdownCodeSegment {
  const MarkdownCodeSegment({
    required this.start,
    required this.end,
    required this.kind,
    required this.content,
    this.identifier = '',
    this.closed = true,
    this.context = MarkdownCodeFenceContext.none,
    this.contextPrefix = '',
    this.marker,
  });

  /// Code-unit offsets in the scanned text (exclusive end).
  final int start;
  final int end;

  final MarkdownCodeSegmentKind kind;

  /// Spans: the visible content between the delimiters, normalized for
  /// display (line endings -> space; one leading/trailing space peeled when
  /// the body both begins and ends with a space but is not all whitespace).
  /// Fences: the code lines between opener and closer joined by `\n`; for
  /// quote fences the `(indent)> ` prefix is stripped from each interior
  /// line (that is how blockquote bodies are stripped before re-parsing).
  final String content;

  /// Fence info string, trimmed; '' when absent. Always '' for spans.
  final String identifier;

  /// False only for a fence running to the text end without a closer
  /// (streaming interrupt).
  final bool closed;

  final MarkdownCodeFenceContext context;

  /// Quote fence: the opener-line prefix up to the fence marker (e.g. "> ").
  /// List fence: the prefix including the list marker (e.g. "- ").
  final String contextPrefix;

  /// Fence marker run kind; null for inline spans.
  final MarkdownCodeFenceMarker? marker;
}

final class MarkdownCodeScanResult {
  const MarkdownCodeScanResult(this.segments);

  final List<MarkdownCodeSegment> segments;
}

final class _FenceMark {
  const _FenceMark({
    required this.start,
    required this.length,
    required this.marker,
    required this.canClose,
  });

  final int start;
  final int length;
  final MarkdownCodeFenceMarker marker;
  final bool canClose;
}

_FenceMark? _fenceMarkOf(String line) {
  var i = 0;
  while (i < line.length) {
    final unit = line.codeUnitAt(i);
    if (unit != 0x20 && unit != 0x09) break;
    i++;
  }
  if (i >= line.length) return null;
  final unit = line.codeUnitAt(i);
  if (unit != 0x60 && unit != 0x7E) return null;
  var n = i + 1;
  while (n < line.length && line.codeUnitAt(n) == unit) {
    n++;
  }
  if (n - i < 3) return null;
  var canClose = true;
  for (var j = n; j < line.length; j++) {
    final u = line.codeUnitAt(j);
    if (u != 0x20 && u != 0x09) {
      canClose = false;
      break;
    }
  }
  return _FenceMark(
    start: i,
    length: n - i,
    marker: unit == 0x60
        ? MarkdownCodeFenceMarker.backtick
        : MarkdownCodeFenceMarker.tilde,
    canClose: canClose,
  );
}

/// A fence mark on a logical line, or null when the line does not start
/// with one (after horizontal indent).
MarkdownCodeFenceMark? markdownCodeFenceMark(String line) {
  final m = _fenceMarkOf(line);
  if (m == null) return null;
  return MarkdownCodeFenceMark(
    start: m.start,
    length: m.length,
    marker: m.marker,
    canClose: m.canClose,
  );
}

/// Whether [index] holds a backtick preceded by an ODD number of backslashes.
/// Per the app's escape convention such a backtick is literal punctuation in
/// prose and cannot open a code span.
bool markdownCodeBackslashEscapedAt(String line, int index) {
  var n = 0;
  for (var j = index - 1; j >= 0 && line.codeUnitAt(j) == 0x5C; j--) {
    n++;
  }
  return n.isOdd;
}

/// Pairs inline code runs on one logical line, left to right (equal-run
/// pairing, same shape as the legacy lexer jump table).
///
/// [escapeSensitive] true: a backslash-escaped backtick never opens a span
/// (the display rule). false: the wider hiding rule — every run
/// participates — used by the details walker.
List<MarkdownCodeInlinePair> markdownCodePairInline(
  String line, {
  bool escapeSensitive = true,
}) {
  final starts = <int>[];
  final lengths = <int>[];
  final escaped = <bool>[];
  var i = 0;
  while (i < line.length) {
    if (line.codeUnitAt(i) != 0x60) {
      i++;
      continue;
    }
    final start = i;
    i++;
    while (i < line.length && line.codeUnitAt(i) == 0x60) {
      i++;
    }
    starts.add(start);
    lengths.add(i - start);
    escaped.add(markdownCodeBackslashEscapedAt(line, start));
  }
  final runCount = starts.length;
  if (runCount == 0) return const [];
  final nextSame = List<int>.filled(runCount, -1);
  final lastByLength = <int, int>{};
  for (var r = runCount - 1; r >= 0; r--) {
    nextSame[r] = lastByLength[lengths[r]] ?? -1;
    lastByLength[lengths[r]] = r;
  }
  final consumed = List<bool>.filled(runCount, false);
  final pairs = <MarkdownCodeInlinePair>[];
  for (var r = 0; r < runCount; r++) {
    if (consumed[r]) continue;
    if (escapeSensitive && escaped[r]) {
      consumed[r] = true;
      continue;
    }
    final closer = nextSame[r];
    if (closer < 0) {
      consumed[r] = true;
      continue;
    }
    pairs.add(
      MarkdownCodeInlinePair(
        openStart: starts[r],
        openLength: lengths[r],
        closeStart: starts[closer],
        closeLength: lengths[closer],
      ),
    );
    for (var k = r; k <= closer; k++) {
      consumed[k] = true;
    }
  }
  return pairs;
}

/// CommonMark normalization of a code span body at display time.
String markdownCodeSpanNormalize(String raw) {
  var body = raw;
  if (body.contains('\n')) {
    body = body
        .replaceAll('\r\n', ' ')
        .replaceAll('\r', ' ')
        .replaceAll('\n', ' ');
  }
  if (body.startsWith(' ') && body.endsWith(' ') && body.trim().isNotEmpty) {
    body = body.substring(1, body.length - 1);
  }
  return body;
}

/// The start index of the trailing backtick run when [line] ENDS with a run
/// of >= [openLength] backticks preceded by a non-backtick character — the
/// app's "inline closing" extension. null when the line does not close.
int? markdownCodeInlineClosingFence(String line, int openLength) {
  var i = line.length - 1;
  while (i >= 0 && (line.codeUnitAt(i) == 0x20 || line.codeUnitAt(i) == 0x09)) {
    i--;
  }
  if (i < 0) return null;
  var n = 0;
  while (i >= 0 && line.codeUnitAt(i) == 0x60) {
    n++;
    i--;
  }
  if (n < openLength) return null;
  if (i < 0) return null;
  if (line.codeUnitAt(i) == 0x60) return null;
  // The run must follow real content: an indented full-line closer
  // ("   ``` " on its own line) is already closed by [markdownCodeScan],
  // and the whitespace here is just the line indent, not content.
  if (line.codeUnitAt(i) == 0x20 || line.codeUnitAt(i) == 0x09) return null;
  return i + 1;
}

/// The `(indent)>` (+ one optional space) prefix when [line] starts with a
/// blockquote marker. '' otherwise.
String markdownCodeQuotePrefix(String line) {
  var i = 0;
  while (i < line.length &&
      (line.codeUnitAt(i) == 0x20 || line.codeUnitAt(i) == 0x09)) {
    i++;
  }
  if (i >= line.length || line.codeUnitAt(i) != 0x3E) return '';
  var j = i + 1;
  if (j < line.length && line.codeUnitAt(j) == 0x20) j++;
  return line.substring(0, j);
}

final class _LineSpan {
  const _LineSpan(this.start, this.end);
  final int start;
  final int end;
}

// One logical line per entry; [complete] is false for a final line that is
// not followed by a line break (a fence cannot open on an incomplete line).
List<_LineSpan> _logicalLines(String text) {
  final spans = <_LineSpan>[];
  var i = 0;
  while (i < text.length) {
    var end = i;
    while (end < text.length) {
      final u = text.codeUnitAt(end);
      if (u == 0x0A || u == 0x0D || u == 0x2028 || u == 0x2029) break;
      end++;
    }
    spans.add(_LineSpan(i, end));
    if (end >= text.length) break;
    i = end + 1;
    if (i < text.length &&
        text.codeUnitAt(end) == 0x0D &&
        text.codeUnitAt(i) == 0x0A) {
      i++;
    }
  }
  return spans;
}

final class _OpenFence {
  int lineStart = 0;
  String prefix = '';
  MarkdownCodeFenceContext context = MarkdownCodeFenceContext.none;
  _FenceMark? mark;
  String identifier = '';
  final List<String> contentLines = [];
}

/// Whether the remainder of a list-fence line [inner] (after [runEnd]) holds
/// the legacy info shape: `[^\s`]*` then horizontal whitespace only.
bool _listFenceInfoOk(String inner, int runEnd) {
  var i = runEnd;
  while (i < inner.length) {
    final u = inner.codeUnitAt(i);
    if (u == 0x20 || u == 0x09 || u == 0x60) break;
    i++;
  }
  while (i < inner.length &&
      (inner.codeUnitAt(i) == 0x20 || inner.codeUnitAt(i) == 0x09)) {
    i++;
  }
  return i == inner.length;
}

/// Scans [text] and returns every code segment (spans and fences) in source
/// order. Regions never overlap; a fence segment spans from its opener
/// line's start to the closer line's end (or the text end when unclosed;
/// the line break after a closer stays outside the segment).
MarkdownCodeScanResult markdownCodeScan(String text) {
  final spans = _logicalLines(text);
  final segments = <MarkdownCodeSegment>[];
  _OpenFence? fence;

  for (var li = 0; li < spans.length; li++) {
    final span = spans[li];
    final line = text.substring(span.start, span.end);
    final complete = span.end < text.length;
    final quotePrefix = markdownCodeQuotePrefix(line);

    if (fence != null) {
      final probe = fence.context == MarkdownCodeFenceContext.blockquote
          ? (quotePrefix.isEmpty ? line : line.substring(quotePrefix.length))
          : line;
      final close = fence.context == MarkdownCodeFenceContext.blockquote
          ? (quotePrefix.isEmpty
                ? null
                : _fenceMarkOf(line.substring(quotePrefix.length)))
          : _fenceMarkOf(line);
      final closed =
          close != null &&
          close.marker == fence.mark!.marker &&
          close.length >= fence.mark!.length &&
          close.canClose;
      final inlineCloseRun = markdownCodeInlineClosingFence(
        probe,
        fence.mark!.length,
      );
      final inlineClosed =
          inlineCloseRun != null &&
          (fence.context != MarkdownCodeFenceContext.blockquote ||
              quotePrefix.isNotEmpty);
      if (closed || inlineClosed) {
        if (inlineCloseRun != null) {
          fence.contentLines.add(probe.substring(0, inlineCloseRun));
        }
        segments.add(
          MarkdownCodeSegment(
            start: fence.lineStart,
            end: span.end,
            kind: MarkdownCodeSegmentKind.codeBlock,
            content: fence.contentLines.join('\n'),
            identifier: fence.identifier,
            closed: true,
            context: fence.context,
            contextPrefix: fence.prefix,
            marker: fence.mark!.marker,
          ),
        );
        fence = null;
        continue;
      }
      fence.contentLines.add(_interiorLine(line, fence.context));
      continue;
    }

    if (quotePrefix.isNotEmpty) {
      final inner = line.substring(quotePrefix.length);
      final m = _fenceMarkOf(inner);
      if (m != null && complete) {
        fence = _OpenFence()
          ..lineStart = span.start
          ..prefix = quotePrefix
          ..context = MarkdownCodeFenceContext.blockquote
          ..mark = m
          ..identifier = inner.substring(m.start + m.length).trim();
        continue;
      }
    } else {
      final listPrefix = _listFencePrefix(line);
      if (listPrefix != null) {
        final inner = line.substring(listPrefix.length);
        final m = _fenceMarkOf(inner);
        if (m != null &&
            complete &&
            m.marker == MarkdownCodeFenceMarker.backtick &&
            _listFenceInfoOk(inner, m.start + m.length)) {
          fence = _OpenFence()
            ..lineStart = span.start
            ..prefix = listPrefix
            ..context = MarkdownCodeFenceContext.list
            ..mark = m
            ..identifier = inner.substring(m.start + m.length).trim();
          continue;
        }
      }
      final m = _fenceMarkOf(line);
      if (m != null && complete) {
        fence = _OpenFence()
          ..lineStart = span.start
          ..context = MarkdownCodeFenceContext.none
          ..mark = m
          ..identifier = line.substring(m.start + m.length).trim();
        continue;
      }
    }

    for (final pair in markdownCodePairInline(line)) {
      segments.add(
        MarkdownCodeSegment(
          start: span.start + pair.openStart,
          end: span.start + pair.closeEnd,
          kind: MarkdownCodeSegmentKind.inlineCode,
          content: markdownCodeSpanNormalize(
            line.substring(pair.openEnd, pair.closeStart),
          ),
        ),
      );
    }
  }

  if (fence != null) {
    segments.add(
      MarkdownCodeSegment(
        start: fence.lineStart,
        end: text.length,
        kind: MarkdownCodeSegmentKind.codeBlock,
        content: fence.contentLines.join('\n'),
        identifier: fence.identifier,
        closed: false,
        context: fence.context,
        contextPrefix: fence.prefix,
        marker: fence.mark!.marker,
      ),
    );
  }

  return MarkdownCodeScanResult(segments);
}

/// Returns [text] with every code region replaced by a single space,
/// preserving the surrounding line structure.
///
/// Fence segments span opener-line start to closer-line end, so the line
/// breaks before the opener and after the closer stay intact and adjacent
/// lines are never joined. Inline spans are paired per line, so unmatched
/// backtick runs never swallow prose.
String markdownRemoveCode(String text) {
  final segments = markdownCodeScan(text).segments;
  if (segments.isEmpty) return text;
  final buffer = StringBuffer();
  var cursor = 0;
  for (final segment in segments) {
    buffer
      ..write(text.substring(cursor, segment.start))
      ..write(' ');
    cursor = segment.end;
  }
  buffer.write(text.substring(cursor));
  return buffer.toString();
}

String _interiorLine(String line, MarkdownCodeFenceContext context) {
  if (context == MarkdownCodeFenceContext.blockquote) {
    final prefix = markdownCodeQuotePrefix(line);
    if (prefix.isNotEmpty) return line.substring(prefix.length);
  }
  return line;
}

String? _listFencePrefix(String line) {
  var i = 0;
  while (i < line.length &&
      (line.codeUnitAt(i) == 0x20 || line.codeUnitAt(i) == 0x09)) {
    i++;
  }
  if (i >= line.length) return null;
  final u = line.codeUnitAt(i);
  final isMarker = u == 0x2A || u == 0x2B || u == 0x2D;
  if (!isMarker) {
    if (u < 0x30 || u > 0x39) return null;
    i++;
    while (i < line.length &&
        line.codeUnitAt(i) >= 0x30 &&
        line.codeUnitAt(i) <= 0x39) {
      i++;
    }
    if (i >= line.length || line.codeUnitAt(i) != 0x2E) return null;
    i++;
  } else {
    i++;
  }
  if (i >= line.length) return null;
  var sawSpace = false;
  while (i < line.length) {
    final s = line.codeUnitAt(i);
    if (s != 0x20 && s != 0x09) break;
    i++;
    sawSpace = true;
  }
  if (!sawSpace || i >= line.length) return null;
  if (line.codeUnitAt(i) != 0x60) return null;
  return line.substring(0, i);
}
