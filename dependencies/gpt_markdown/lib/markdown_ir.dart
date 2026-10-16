/// Widget-agnostic Markdown IR: the node tree a renderer walk produces, the
/// item table a text selection is mapped onto, and the re-emitter that turns a
/// covered range back into Markdown source.
///
/// This library imports nothing. It describes structure only — kinds, source
/// ranges, display text and the markers a node re-emits — so a Flutter widget
/// builder and a future PDF emitter can consume the same tree.
///
/// ## Display space
///
/// A selection is captured as flat text, so mapping it back means reproducing
/// the space that text lives in. `SelectableRegion` concatenates, in tree
/// order, one contribution per selectable: a `RichText` contributes the runs
/// between its `WidgetSpan`s — the placeholders themselves are never copied,
/// because `RenderParagraph` splits on them and skips them — and a
/// `SelectableAdapter` contributes the `selectedText` it declares. An item
/// with empty display text and a source range (an image, a horizontal rule, a
/// disabled display-math block) occupies no display space yet rides along when
/// a selection spans across it.
library;

/// A half-open range `[start, end)` in some source string.
///
/// The source is carried with the range because not every node addresses the
/// same string: a rewritten document (a `<details>` block replaced by a
/// placeholder) is walked in rewritten space while the block's own children
/// address the original text.
final class MdRange {
  const MdRange(this.source, this.start, this.end);

  final String source;
  final int start;
  final int end;

  /// The substring this range addresses.
  String get text => source.substring(start, end);

  /// A range covering all of [text].
  static MdRange all(String text) => MdRange(text, 0, text.length);
}

/// What a node is, for consumers that re-emit or draw it.
///
/// The set is the vocabulary the renderer already matches: a kind is the
/// component that claimed the text, never a syntax pattern guessed later.
enum MdNodeKind {
  /// A structural container with no markers of its own.
  group,

  /// Content text: display text is the source text.
  text,

  /// Text the renderer shows that the source does not contain (list bullets
  /// and numbers, enumerated heading numbers, table separators). It occupies
  /// display space but emits nothing.
  decoration,

  bold,
  italic,
  strike,
  underline,

  /// Inline code.
  inlineCode,

  link,
  image,
  math,
  codeBlock,
  heading,
  listItem,
  quote,
  table,
  details,
}

/// One structural step of the IR tree.
///
/// A node either has [children] — structure, where [open] and [close] are
/// re-emitted around the covered children — or is a leaf carrying [display]
/// or [range].
final class MdNode {
  const MdNode({
    required this.kind,
    this.range,
    this.children = const [],
    this.display,
    this.open = '',
    this.close = '',
  });

  /// Content leaf: display text is the source text at [range].
  const MdNode.text(MdRange range) : this(kind: MdNodeKind.text, range: range);

  /// Display-only leaf: occupies display space, emits nothing.
  const MdNode.decoration(String display)
    : this(kind: MdNodeKind.decoration, display: display);

  /// A leaf that occupies no display space but re-emits [range] when a
  /// selection spans across it.
  const MdNode.gap(MdNodeKind kind, MdRange range)
    : this(kind: kind, range: range, display: '');

  /// A leaf whose display text is [display] while its markdown is [range]:
  /// a selection may only cover it whole, because the cut cannot be resolved
  /// between two different texts.
  const MdNode.opaque(MdNodeKind kind, MdRange range, String display)
    : this(kind: kind, range: range, display: display);

  final MdNodeKind kind;

  /// The source this node came from, or `null` for a decoration.
  final MdRange? range;

  /// Explicit display text for leaves; `null` for structure, which takes the
  /// concatenation of its children.
  final String? display;

  final List<MdNode> children;

  /// Marker re-emitted before the covered children.
  final String open;

  /// Marker re-emitted after the covered children.
  final String close;
}

/// One entry of the ordered display space.
final class MdItem {
  const MdItem({
    required this.node,
    required this.ancestors,
    required this.display,
    required this.sourceText,
  });

  final MdNode node;

  /// Enclosing nodes, outermost first: the stack whose markers are re-emitted
  /// around this item.
  final List<MdNode> ancestors;

  /// The text this item contributes to the display space.
  final String display;

  /// The markdown this item re-emits when covered, or `''` for a decoration.
  final String sourceText;

  bool get isDecoration => node.kind == MdNodeKind.decoration;

  /// Display text and markdown differ, so a cut inside this item cannot be
  /// resolved: covering it at all means covering it whole.
  bool get isOpaqueSource => sourceText != display;

  bool get contributesSource => sourceText.isNotEmpty;
}

/// A document: the blocks a walk produced, plus the tables derived from them.
final class MdDocument {
  MdDocument(this.blocks);

  final List<MdNode> blocks;

  List<MdItem>? _items;
  _MdIndex? _index;

  /// The ordered display space, built once.
  List<MdItem> get items => _items ??= _flatten();

  _MdIndex get _normalized => _index ??= _MdIndex.build(items);

  /// The concatenation of every item's display text: exactly what a selection
  /// over the rendered document copies.
  String get displayText => _normalized.text;

  List<MdItem> _flatten() {
    final out = <MdItem>[];
    void visit(MdNode node, List<MdNode> ancestors) {
      if (node.children.isNotEmpty) {
        final inner = [...ancestors, node];
        for (final child in node.children) {
          visit(child, inner);
        }
        return;
      }
      final explicit = node.display;
      final range = node.range;
      if (explicit != null) {
        out.add(
          MdItem(
            node: node,
            ancestors: ancestors,
            display: explicit,
            sourceText: range?.text ?? '',
          ),
        );
        return;
      }
      if (range == null) return;
      out.add(
        MdItem(
          node: node,
          ancestors: ancestors,
          display: range.text,
          sourceText: range.text,
        ),
      );
    }

    for (final block in blocks) {
      visit(block, const []);
    }
    return out;
  }

  /// Locates [query] in the display space, returning what it covers.
  ///
  /// Both sides are normalized the same way, so characters the renderer
  /// inserts are ignored rather than breaking the match. Returns `null` when
  /// the query is empty or is not a substring — the caller falls back to plain
  /// text, which is why a miss is never worse than a copy.
  MdSelection? matchDisplay(String query) {
    final needle = normalizeDisplayText(query);
    if (needle.isEmpty) return null;
    final index = _normalized;
    final at = index.text.indexOf(needle);
    if (at < 0) return null;
    return MdSelection._(this, index, at, at + needle.length - 1);
  }

  /// The markdown for a selection over this document, or `null` when the
  /// selection cannot be mapped.
  String? emitSelectionMarkdown(String query) => matchDisplay(query)?.emit();
}

/// The normalized display space: `text` plus the maps that tie every
/// normalized offset back to the item it came from.
final class _MdIndex {
  _MdIndex._(this.text, this.owner, this.starts, this.ends);

  final String text;

  /// Normalized offset → item index.
  final List<int> owner;

  /// Item index → first normalized offset, or -1 when it contributes none.
  final List<int> starts;

  /// Item index → last normalized offset, or -1 when it contributes none.
  final List<int> ends;

  static _MdIndex build(List<MdItem> items) {
    final buffer = StringBuffer();
    final owner = <int>[];
    final starts = List<int>.filled(items.length, -1);
    final ends = List<int>.filled(items.length, -1);
    // Normalization runs over the concatenation, never item by item: a run of
    // newlines split across two items folds to one newline in the text the
    // framework copies, so it has to fold here too.
    var previousWasNewline = false;
    for (var i = 0; i < items.length; i++) {
      final raw = items[i].display;
      if (raw.isEmpty) continue;
      final start = buffer.length;
      var k = 0;
      while (k < raw.length) {
        var char = raw[k];
        if (char == '\r') {
          if (k + 1 < raw.length && raw[k + 1] == '\n') k++;
          char = '\n';
        }
        k++;
        if (char == '\n') {
          if (previousWasNewline) continue;
          previousWasNewline = true;
        } else {
          previousWasNewline = false;
          if (isStrippedDisplayCharacter(char)) continue;
        }
        buffer.write(char);
        owner.add(i);
      }
      if (buffer.length > start) {
        starts[i] = start;
        ends[i] = buffer.length - 1;
      }
    }
    return _MdIndex._(buffer.toString(), owner, starts, ends);
  }

  int? itemAt(int normalizedOffset) {
    if (normalizedOffset < 0 || normalizedOffset >= owner.length) return null;
    return owner[normalizedOffset];
  }
}

/// A contiguous cover of the display space.
final class MdSelection {
  MdSelection._(this.document, this._index, this.startOffset, this.endOffset);

  final MdDocument document;
  final _MdIndex _index;

  /// Normalized display offsets, inclusive.
  final int startOffset;
  final int endOffset;

  /// Re-emits the covered items as Markdown, completing the markers of every
  /// node the selection cut.
  ///
  /// Separators need no synthesis: the newlines between two blocks are source
  /// text like any other, so they are covered items that emit themselves.
  String emit() {
    final items = document.items;
    final first = _index.itemAt(startOffset)!;
    final last = _index.itemAt(endOffset)!;
    final buffer = StringBuffer();
    var stack = <MdNode>[];

    void closeTo(int common) {
      for (var k = stack.length - 1; k >= common; k--) {
        buffer.write(stack[k].close);
      }
      stack = stack.sublist(0, common);
    }

    for (var i = first; i <= last; i++) {
      final item = items[i];
      final chain = item.ancestors;
      var common = 0;
      while (common < chain.length &&
          common < stack.length &&
          identical(chain[common], stack[common])) {
        common++;
      }
      closeTo(common);
      for (var k = common; k < chain.length; k++) {
        buffer.write(chain[k].open);
        stack = [...stack, chain[k]];
      }
      if (item.isDecoration || !item.contributesSource) continue;
      buffer.write(_coveredSource(item, i, i == first, i == last));
    }
    closeTo(0);
    return buffer.toString();
  }

  /// The source to emit for the item at [itemIndex], clipped to the selection
  /// when the selection starts or ends inside it.
  String _coveredSource(MdItem item, int itemIndex, bool isFirst, bool isLast) {
    var start = 0;
    var end = item.sourceText.length;
    final itemStart = _index.starts[itemIndex];
    final itemEnd = _index.ends[itemIndex];
    if (isFirst && itemStart >= 0 && startOffset > itemStart) {
      if (!item.isOpaqueSource) {
        start = rawOffsetForNormalizedPrefix(
          item.display,
          startOffset - itemStart,
        );
      }
    }
    if (isLast && itemEnd >= 0 && endOffset < itemEnd) {
      if (!item.isOpaqueSource) {
        end = rawOffsetForNormalizedPrefix(
          item.display,
          endOffset - itemStart + 1,
        );
      }
    }
    if (start >= end) return '';
    return item.sourceText.substring(start, end);
  }

  /// How much of [raw] the first [normalizedCount] normalized characters
  /// occupy, in raw characters.
  static int rawOffsetForNormalizedPrefix(String raw, int normalizedCount) {
    if (normalizedCount <= 0) return 0;
    var consumed = 0;
    var index = 0;
    var previousWasNewline = false;
    while (index < raw.length && consumed < normalizedCount) {
      var char = raw[index];
      var step = 1;
      if (char == '\r') {
        if (index + 1 < raw.length && raw[index + 1] == '\n') step = 2;
        char = '\n';
      }
      if (char == '\n') {
        if (previousWasNewline) {
          index += step;
          continue;
        }
        previousWasNewline = true;
        consumed++;
        index += step;
        continue;
      }
      previousWasNewline = false;
      if (isStrippedDisplayCharacter(char)) {
        index += step;
        continue;
      }
      consumed++;
      index += step;
    }
    return index;
  }
}

/// Characters that occupy no display width, or that the renderer inserts, and
/// are therefore ignored when a copied selection is matched back to source.
///
/// Deliberately broader than the sanitizer that cleans copied text: matching
/// may be lossy because a miss only falls back to plain text, while the
/// clipboard must keep what it cannot prove was inserted.
bool isStrippedDisplayCharacter(String char) {
  final unit = char.codeUnitAt(0);
  return unit == 0x2022 || // bullet •
      unit == 0x200b || // zero-width space
      unit == 0x200c || // zero-width non-joiner
      unit == 0x200d || // zero-width joiner
      unit == 0x200e || // left-to-right mark
      unit == 0x200f || // right-to-left mark
      unit == 0xfeff || // byte-order mark
      unit == 0x00ad || // soft hyphen
      unit == 0xfffc || // widget placeholder, which is never copied
      (unit >= 0x2060 && unit <= 0x2064); // invisible operators
}

/// Folds text into the canonical form both sides of a match are compared in:
/// `\r\n`/`\r` become `\n`, runs of newlines fold to one, and every
/// [isStrippedDisplayCharacter] is dropped.
String normalizeDisplayText(String input) {
  final buffer = StringBuffer();
  var previousWasNewline = false;
  for (var i = 0; i < input.length; i++) {
    var char = input[i];
    if (char == '\r') {
      if (i + 1 < input.length && input[i + 1] == '\n') i++;
      char = '\n';
    }
    if (char == '\n') {
      if (previousWasNewline) continue;
      previousWasNewline = true;
      buffer.write(char);
      continue;
    }
    previousWasNewline = false;
    if (isStrippedDisplayCharacter(char)) continue;
    buffer.write(char);
  }
  return buffer.toString();
}

/// Removes exactly the characters the Markdown renderer inserts into rendered
/// text — the zero-width spaces it writes to make an over-long token breakable
/// — so text copied out of the rendered widgets matches the underlying
/// content.
///
/// Deliberately narrow: other invisible characters can be legitimate content,
/// so the lossy set is confined to matching (see [normalizeDisplayText]). That
/// is why U+200C is *not* here any more: it used to be the enumerated ATX
/// heading's disambiguator, and a heading body is now walked with the inline
/// components, so nothing inserts it — while a ZWNJ in copied text is
/// orthography (Persian, Arabic, Urdu) that a clipboard must keep.
String stripRendererInsertedCharacters(String input) {
  return input.replaceAll('\u200B', '');
}

/// The display text a list of nodes contributes: the concatenation of their
/// leaves, with structure ignored.
///
/// Used by components that re-emit a whole region while their rendered text is
/// the parsed content of that region (a table's cells, a quote's body).
String mdDisplayOf(List<MdNode> nodes) => MdDocument(nodes).displayText;
