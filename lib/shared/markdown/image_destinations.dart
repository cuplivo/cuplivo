import 'package:markstream/markstream.dart';

/// Every image destination the Markdown renderer will actually hand to its
/// `ImageBuilder` for [source], with the source offset of its **first**
/// occurrence.
///
/// This exists because "the reply mentions this uri" and "the reply draws this
/// uri as a picture" are different questions, and the answer to the second one
/// decides whether an image-job part still needs to project a block of its own.
/// Asking the renderer's own parser is the only way to keep the two in step: a
/// uri inside a fenced block, inside inline code, or sitting in a link label is
/// text, not a picture, and a substring test cannot tell that apart.
///
/// The offset is what tells two mentions of the same uri apart. A reply that
/// writes the placeholder twice must draw one illustration, not two, and
/// document order is the only reliable answer: the node the builder receives
/// carries its own span, so the first one can own the card. `CodeBlockNode`
/// keeps its contents as raw text rather than image nodes, so a destination
/// written inside a fence never appears here.
Map<String, int> markdownImageFirstOffsets(String source) {
  if (source.isEmpty) return const <String, int>{};
  final document = const MarkdownParser().parse(source, streaming: false);
  final out = <String, int>{};
  void walk(MarkdownNode node) {
    if (node is ImageNode) {
      out.putIfAbsent(node.destination, () => node.span.start);
    }
    for (final child in node.children) {
      walk(child);
    }
  }

  walk(document);
  return out;
}
