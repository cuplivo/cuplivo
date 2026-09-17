import 'markdown_subsequence_match.dart';

/// The single canonical markdown→plain extraction shared by ALL message-quote
/// consumers (draft preview row, bubble quote block, `<reply-to>` API
/// injection). See docs/adr/0046-message-reply-quote.md.
///
/// Keep the output pure extraction: no clipping, no whitespace flattening —
/// presentation transforms (`\n`→space, ellipsis, budget clip) live in
/// [quoteFlatten] / [quoteClipText] / [quoteWindowText] so the API never
/// receives a chat-UI-truncated citation.
///
/// Strips (deliberately conservative):
/// - fenced code markers (``` / ~~~) — code bodies stay
/// - leading blockquote `>` and heading `#` markers per line
/// - images `![alt](url)` → alt; links `[label](url)` → label
/// - inline code `` `x` `` → x
/// - emphasis `**`/`__`/`~~`/single `*`
/// - backslash escapes
///
/// Deliberately NOT stripped: `_` (snake_case / prose underscores), `$` math
/// delimiters (`$`doubles as a literal currency char), HTML tags, and inline
/// math — quote text keeps them verbatim rather than risking a mangled
/// boundary.
String quotePlainText(String markdown) {
  if (markdown.isEmpty) return '';

  // 1. Fenced code blocks (either fence flavor): markers removed, body kept.
  var text = _stripFences(markdown);

  // 2. Backslash escapes first: `\*` is a literal asterisk — unwrap before
  // emphasis sees the marker. Restricted to markdown-special ASCII
  // punctuation so plain prose like `C:\temp` is never mangled.
  text = text.replaceAllMapped(
    RegExp(r'\\([\`\*_\[\]{}()#+\-.!><~])'),
    (m) => m.group(1) ?? '',
  );

  // 3. Line-marker prefixes: blockquote >, headings #, horizontal rules.
  text = _stripLineMarkers(text);

  // 4. Images before links (image alt also matches the link regex otherwise).
  text = text.replaceAllMapped(
    RegExp(r'!\[([^\]]*)\]\([^)]*\)'),
    (m) => m.group(1) ?? '',
  );
  text = text.replaceAllMapped(
    RegExp(r'\[([^\]]+)\]\([^)]*\)'),
    (m) => m.group(1) ?? '',
  );

  // 5. Inline code (backticks, non-greedy, no newline).
  text = text.replaceAllMapped(RegExp(r'`([^`\n]*)`'), (m) => m.group(1) ?? '');

  // 6. Emphasis: double markers before single so **bold** does not become
  // two half-emphasized fragments; `_` is deliberately kept.
  text = text.replaceAllMapped(
    RegExp(r'\*\*(.+?)\*\*'),
    (m) => m.group(1) ?? '',
  );
  text = text.replaceAllMapped(RegExp(r'__(.+?)__'), (m) => m.group(1) ?? '');
  text = text.replaceAllMapped(RegExp(r'~~(.+?)~~'), (m) => m.group(1) ?? '');
  text = text.replaceAllMapped(
    RegExp(r'\*([^*\n]+)\*'),
    (m) => m.group(1) ?? '',
  );

  // The line/paragraph rebuild appends a newline per source line; trim the
  // artifact so the extraction is exactly what the API carries. Internal
  // blank lines (genuine paragraph breaks) are preserved.
  return text.trim();
}

/// `\n` → space + whitespace-run collapse (the one-line presentation of a
/// quote block / draft row).
String quoteFlatten(String plain) {
  return plain.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Leading-characters clip for id-only quotes (no range): [budget] code
/// units, trailing ellipsis when truncated.
String quoteClipText(String plain, {int budget = quoteClipBudget}) {
  final flat = quoteFlatten(plain);
  if (flat.length <= budget) return flat;
  return '${flat.substring(0, budget)}…';
}

/// Center-window for ranged quotes: the span is always fully visible, pre/post
/// context shrinks to fit [budget], ellipses only at the cut boundaries.
/// Returns the window text plus the highlight span (positions in the returned
/// text), or `null` when the span cannot be located inside [fullPlain]
/// (target content changed after the reply was created — display degrades
/// span-only outside this function).
typedef QuoteWindow = ({String text, int spanStart, int spanEnd});

QuoteWindow? quoteWindowText({
  required String fullPlain,
  required String spanPlain,
  int budget = quoteClipBudget,
}) {
  final flat = quoteFlatten(fullPlain);
  final flatSpan = quoteFlatten(spanPlain);
  if (flatSpan.isEmpty) return null;
  final located = subsequenceRange(flat, flatSpan);
  if (located == null) return null;
  final span = located;
  final spanLen = span.end - span.start;
  if (spanLen >= budget) {
    return (
      text: flat.substring(span.start, span.end),
      spanStart: 0,
      spanEnd: spanLen,
    );
  }
  final sideBudget = (budget - spanLen) ~/ 2;
  final preLen = span.start < sideBudget ? span.start : sideBudget;
  final postLen = (flat.length - span.end) < sideBudget
      ? (flat.length - span.end)
      : sideBudget;
  final pre = flat.substring(span.start - preLen, span.start);
  final post = flat.substring(span.end, span.end + postLen);
  final text =
      '${preLen < span.start ? '…' : ''}$pre'
      '${flat.substring(span.start, span.end)}'
      '$post${postLen < flat.length - span.end ? '…' : ''}';
  final spanStart = pre.length + (preLen < span.start ? 1 : 0);
  return (text: text, spanStart: spanStart, spanEnd: spanStart + spanLen);
}

const int quoteClipBudget = 80;

String _stripFences(String markdown) {
  final buf = StringBuffer();
  bool inFence = false;
  for (final line in markdown.split('\n')) {
    if (RegExp(r'^\s*(```|~~~)').hasMatch(line)) {
      inFence = !inFence;
      continue;
    }
    buf.write(line);
    buf.write('\n');
  }
  return buf.toString();
}

String _stripLineMarkers(String text) {
  final lines = text.split('\n');
  final buf = StringBuffer();
  for (final line in lines) {
    var l = line;
    // Repeated blockquote markers, optionally space-separated.
    l = l.replaceFirst(RegExp(r'^\s*(>\s*)+'), '');
    // Heading prefix (#–######).
    l = l.replaceFirst(RegExp(r'^\s*#{1,6}\s+'), '');
    // Horizontal rules.
    if (RegExp(r'^\s*([-*_])\1{2,}\s*$').hasMatch(l)) l = '';
    // List markers at line start (`-`, `*`, `+`, `1.`).
    l = l.replaceFirst(RegExp(r'^\s*([-*+]|\d+[.)])\s+'), '');
    buf.write(l);
    buf.write('\n');
  }
  return buf.toString();
}
