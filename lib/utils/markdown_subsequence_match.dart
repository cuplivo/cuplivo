/// Half-open subsequence span of [query] in [source].
typedef SubsequenceRange = ({int start, int end});

/// Finds the tightest subsequence match of [query] in [source].
///
/// Walks [source] left-to-right for each candidate start position, greedily
/// matching [query] characters in order. Returns the span with the smallest
/// width (end - start) that contains all query characters as a
/// subsequence. Wrapper around [subsequenceRange]: returns the source
/// fragment with that smallest span.
///
/// [query] is normalized before matching:
/// - `\r\n` → `\n`, consecutive newlines folded into one
/// - Zero-width / invisible characters stripped (\u200b–\u200f, \ufeff,
///   \u00ad, \u2060–\u2064)
/// - Bullet character `•` (U+2022) stripped
///
/// Returns `null` if [query] is empty, [source] is empty, or [query] is not a
/// subsequence of [source].
String? subsequenceMatch(String source, String query) {
  final span = subsequenceRange(source, query);
  return span == null ? null : source.substring(span.start, span.end);
}

/// Same algorithm as [subsequenceMatch] but returns the half-open
/// `{start, end}` span (indices in [source]) instead of the matched text —
/// the index variant is required when the match must be highlighted inside
/// the source (message reply quote display).
SubsequenceRange? subsequenceRange(String source, String query) {
  if (query.isEmpty || source.isEmpty) return null;

  final normalized = _normalizeQuery(query);
  if (normalized.isEmpty) return null;
  if (normalized.length > source.length) return null;

  final srcLen = source.length;
  final qryLen = normalized.length;

  int? bestStart;
  int? bestEnd;
  int bestSpan = srcLen + 1;

  for (int i = 0; i <= srcLen - qryLen; i++) {
    if (qryLen >= bestSpan) break;

    int qi = 0;
    int si = i;
    while (si < srcLen && qi < qryLen) {
      if (source[si] == normalized[qi]) qi++;
      si++;
    }

    if (qi == qryLen) {
      final span = si - i;
      if (span < bestSpan) {
        bestSpan = span;
        bestStart = i;
        bestEnd = si;
        if (span == qryLen) break;
      }
    }
  }

  if (bestStart == null || bestEnd == null) return null;

  return (start: bestStart, end: bestEnd);
}

String _normalizeQuery(String raw) {
  final buf = StringBuffer();
  bool prevNewline = false;
  for (int i = 0; i < raw.length; i++) {
    var c = raw[i];
    if (c == '\r') {
      if (i + 1 < raw.length && raw[i + 1] == '\n') {
        i++;
      }
      c = '\n';
    }
    if (c == '\n') {
      if (!prevNewline) {
        buf.write(c);
        prevNewline = true;
      }
      continue;
    }
    prevNewline = false;
    if (_isStripped(c)) continue;
    buf.write(c);
  }
  return buf.toString();
}

bool _isStripped(String c) {
  final cp = c.codeUnitAt(0);
  return cp == 0x2022 || // bullet •
      cp == 0x200b || // ZWSP
      cp == 0x200c || // ZWNJ
      cp == 0x200d || // ZWJ
      cp == 0x200e || // LRM
      cp == 0x200f || // RLM
      cp == 0xfeff || // BOM
      cp == 0x00ad || // soft hyphen
      (cp >= 0x2060 && cp <= 0x2064); // invisible operators
}

/// Removes the invisible characters the markdown renderer inserts into
/// rendered text — zero-width space soft breaks (long inline-code and
/// table-cell tokens, empty table cells) and zero-width non-joiners
/// (enumerated ATX headings) — so text copied out of the rendered widgets
/// matches the underlying content (cuplivo issue #738).
///
/// Deliberately narrow: other invisible characters are not stripped
/// because they can be part of legitimate content — e.g. U+200D joins
/// emoji ZWJ sequences (👩‍💻, 🏳️‍🌈), and stripping it would split them.
/// Lossy stripping of the full invisible range stays in [_normalizeQuery],
/// where matching rendered content back to markdown source tolerates it.
String stripRendererInsertedCharacters(String input) {
  return input.replaceAll('\u200B', '').replaceAll('\u200C', '');
}
