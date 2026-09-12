/// Query normalization for the knowledge base lexical retrieval channel.
///
/// The v1 backend is FTS5 with the `trigram` tokenizer, which cannot tokenize
/// terms shorter than 3 characters (common for CJK, e.g. 2-character words).
/// This helper keeps that concern inside the lexical channel: callers build a
/// safe `MATCH` expression here and fall back to a `LIKE` scan when no term is
/// indexable. v2 hybrid retrieval / the offline fallback reuse the same path
/// (see ADR-0064).
///
/// CJK text has no spaces, so a whole sentence would otherwise become ONE
/// quoted phrase and require the document to contain that exact sentence.
/// Instead each CJK run is expanded into sliding 3-character trigram windows
/// (sampled when long) and OR-joined, which for a trigram index means "any
/// 3-char slice matches" — bm25 then ranks chunks matching more slices higher.
library;

class KnowledgeQuery {
  const KnowledgeQuery._();

  /// Minimum term length the `trigram` tokenizer can index.
  static const int minTermLength = 3;

  /// Upper bound on sliding windows generated per CJK run (long sentences are
  /// evenly sampled); keeps the MATCH expression bounded.
  static const int maxWindowsPerRun = 12;

  static final RegExp _imageMarker = RegExp(r'\[image:[^\]]+\]');
  static final RegExp _fileMarker = RegExp(r'\[file:[^\]]+\]');
  static final RegExp _whitespace = RegExp(r'\s+');

  /// Strips `[image:…]` / `[file:…]` attachment markers from a user message so
  /// the query is plain text. Returns an empty string for attachment-only input.
  static String stripAttachmentMarkers(String text) => text
      .replaceAll(_imageMarker, ' ')
      .replaceAll(_fileMarker, ' ')
      .replaceAll(_whitespace, ' ')
      .trim();

  /// Builds a safe FTS5 `MATCH` expression from [query], or null when no term is
  /// indexable (the caller must fall back to [likePattern]).
  ///
  /// Whitespace-separated tokens are AND-joined. Inside a token, CJK runs are
  /// OR-expanded into trigram windows (a question sentence still matches a
  /// document that contains only part of it); ASCII runs of >= 3 characters
  /// stay exact phrases.
  static String? buildFtsMatch(String query) {
    final tokens = query
        .trim()
        .split(_whitespace)
        .where((token) => token.isNotEmpty);
    final clauses = <String>[];
    for (final token in tokens) {
      final clause = _clauseForToken(token);
      if (clause != null) clauses.add(clause);
    }
    if (clauses.isEmpty) return null;
    return clauses.join(' AND ');
  }

  static String? _clauseForToken(String token) {
    final runs = _splitScriptRuns(token);
    final hasCjk = runs.any((run) => run.isCjk);
    final terms = <String>[];
    for (final run in runs) {
      if (run.isCjk) {
        terms.addAll(_trigramWindows(run.text));
      } else if (run.text.length >= minTermLength) {
        terms.add(_quote(run.text));
      }
    }
    if (terms.isEmpty) return null;
    final unique = terms.toSet().toList(growable: false);
    if (!hasCjk) return unique.join(' AND ');
    // A CJK question's windows include question words; OR keeps recall while
    // bm25 ranks the chunks that match the topical slices higher.
    return unique.length == 1 ? unique.first : '(${unique.join(' OR ')})';
  }

  static List<String> _trigramWindows(String run) {
    final windows = <String>[];
    final total = run.length - minTermLength + 1;
    if (total <= 0) return windows;
    final step = total <= maxWindowsPerRun
        ? 1
        : (total / maxWindowsPerRun).ceil();
    for (var i = 0; i + minTermLength <= run.length; i += step) {
      windows.add(_quote(run.substring(i, i + minTermLength)));
    }
    // Even sampling can skip the tail; always represent the final slice.
    final last = _quote(run.substring(run.length - minTermLength));
    if (windows.isEmpty || windows.last != last) windows.add(last);
    return windows;
  }

  static String _quote(String term) => '"${term.replaceAll('"', '""')}"';

  static List<({bool isCjk, String text})> _splitScriptRuns(String token) {
    final runs = <({bool isCjk, String text})>[];
    final buffer = StringBuffer();
    bool? currentIsCjk;
    void flush() {
      if (buffer.isEmpty) return;
      runs.add((isCjk: currentIsCjk ?? false, text: buffer.toString()));
      buffer.clear();
    }

    for (final rune in token.runes) {
      final isCjk = _isCjkRune(rune);
      if (currentIsCjk != null && isCjk != currentIsCjk) flush();
      currentIsCjk = isCjk;
      buffer.writeCharCode(rune);
    }
    flush();
    return runs;
  }

  /// Han / Kana / Hangul ranges the trigram expansion applies to.
  static bool _isCjkRune(int rune) =>
      (rune >= 0x3400 && rune <= 0x4DBF) || // CJK Ext A
      (rune >= 0x4E00 && rune <= 0x9FFF) || // CJK Unified Ideographs
      (rune >= 0xF900 && rune <= 0xFAFF) || // CJK Compatibility Ideographs
      (rune >= 0x3040 && rune <= 0x30FF) || // Hiragana / Katakana
      (rune >= 0xAC00 && rune <= 0xD7AF); // Hangul Syllables

  /// `LIKE` pattern for the short-query fallback, escaping `%`, `_` and `\`.
  static String likePattern(String query) {
    final escaped = query
        .trim()
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    return '%$escaped%';
  }
}
