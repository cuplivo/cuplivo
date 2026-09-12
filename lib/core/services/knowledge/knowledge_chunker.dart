/// Pure character-based chunker for knowledge documents (issue #389).
///
/// Chunk boundaries snap backwards to the nearest newline in the second half of
/// the window, so a paragraph is not split mid-sentence when a nearby break
/// point exists. Adjacent chunks share [chunkOverlap] trailing characters of
/// context. The algorithm makes no whitespace/tokenizer assumptions, so it also
/// handles CJK text that has no spaces between words.
library;

class KnowledgeChunker {
  const KnowledgeChunker._();

  /// Splits [text] into chunks of at most [chunkSize] characters with
  /// [chunkOverlap] characters of trailing context. Returns an empty list for
  /// empty or whitespace-only input.
  static List<String> chunk(
    String text, {
    required int chunkSize,
    required int chunkOverlap,
  }) {
    final source = text.trim();
    if (source.isEmpty) return const <String>[];

    final size = chunkSize < 1 ? 1 : chunkSize;
    var overlap = chunkOverlap < 0 ? 0 : chunkOverlap;
    if (overlap >= size) overlap = size - 1;

    if (source.length <= size) return <String>[source];

    final chunks = <String>[];
    final minSnap = size ~/ 2;
    var start = 0;
    while (start < source.length) {
      var end = start + size;
      if (end >= source.length) {
        end = source.length;
      } else {
        final boundary = source.lastIndexOf('\n', end - 1);
        if (boundary > start + minSnap) end = boundary + 1;
      }
      final piece = source.substring(start, end).trim();
      if (piece.isNotEmpty) chunks.add(piece);
      if (end >= source.length) break;
      var next = end - overlap;
      if (next <= start) next = start + 1;
      start = next;
    }
    return chunks;
  }
}
