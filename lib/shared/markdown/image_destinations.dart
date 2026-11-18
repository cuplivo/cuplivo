import 'package:markstream/markstream.dart';

/// Every image destination the Markdown renderer will actually hand to its
/// `ImageBuilder` for [source].
///
/// This exists because "the reply mentions this uri" and "the reply draws this
/// uri as a picture" are different questions, and the answer to the second one
/// decides whether an image-job part still needs to project a block of its own.
/// Asking the renderer's own parser is the only way to keep the two in step: a
/// uri inside a fenced block, inside inline code, or sitting in a link label is
/// text, not a picture, and a substring test cannot tell that apart.
///
/// `CodeBlockNode` keeps its contents as raw text rather than image nodes, so a
/// destination written inside a fence never appears here — which is exactly the
/// distinction the caller needs and cannot get from `String.contains`.
Set<String> markdownImageDestinations(String source) {
  if (source.isEmpty) return const <String>{};
  final document = const MarkdownParser().parse(source, streaming: false);
  final out = <String>{};
  void walk(MarkdownNode node) {
    if (node is ImageNode) out.add(node.destination);
    for (final child in node.children) {
      walk(child);
    }
  }

  walk(document);
  return out;
}
