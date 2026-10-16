part of 'gpt_markdown.dart';

/// Markdown components
abstract class MarkdownComponent {
  static final _patterns = <String, _MarkdownPatterns>{};
  static List<MarkdownComponent> get globalComponents => [
    CodeBlockMd(),
    LatexMathMultiLine(),
    NewLines(),
    BlockQuote(),
    TableMd(),
    HTag(),
    UnOrderedList(),
    OrderedList(),
    RadioButtonMd(),
    CheckBoxMd(),
    HrLine(),
    IndentMd(),
  ];

  static final List<MarkdownComponent> inlineComponents = [
    ATagMd(),
    ImageMd(),
    TableMd(),
    StrikeMd(),
    BoldMd(),
    ItalicMd(),
    UnderLineMd(),
    LatexMath(),
    LatexMathMultiLine(),
    HighlightedText(),
    SourceTag(),
  ];

  /// Generate widget for markdown widget
  static List<InlineSpan> generate(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
    bool includeGlobalComponents, {
    void Function(
      InlineSpan span,
      int start,
      int end,
      MarkdownComponent? component,
      bool block,
    )?
    onSpan,
  }) {
    if (includeGlobalComponents) {
      final preprocess = config.preprocessBlocks;
      if (preprocess != null) {
        final rewritten = preprocess(text);
        // Rewritten offsets belong to another source, so cannot be retained by
        // the append parser. Normal rendering still uses the rewritten text.
        if (rewritten != text) onSpan = null;
        text = rewritten;
      }
    }
    final spans = <InlineSpan>[];
    _walk(
      text,
      spans,
      _MdSpanSink(context, config, onSpan),
      config: config,
      includeGlobal: includeGlobalComponents,
      source: text,
      start: 0,
    );
    return spans;
  }

  /// Describes the element this component matched as an IR node.
  ///
  /// [text] is exactly the matched element and the node's source range starts
  /// at [MdNodeContext.start]. The default is a content leaf: the element
  /// re-emits the source it claimed. A component whose rendering shows
  /// something other than that source — a math widget showing its TeX body, a
  /// list item dropping its marker, an image showing nothing — overrides this,
  /// which is what keeps the IR and the rendered widgets from drifting apart.
  MdNode node(MdNodeContext ctx, String text) =>
      MdNode.text(MdRange(ctx.source, ctx.start, ctx.start + text.length));

  /// The node for one matched [element], as this component's own [span] sees it.
  ///
  /// A component is handed the element it matched, never the document it came
  /// from, so the element is its own source and starts at 0; the walk mode is
  /// the one [inline] implies. A component that renders through [MdSpanEmitter]
  /// builds its node this way instead of waiting for a walk to build it.
  MdNode nodeOfElement(GptMarkdownConfig config, String element) => node(
    MdNodeContext(
      source: element,
      start: 0,
      includeGlobal: !inline,
      config: config,
    ),
    element,
  );

  /// Builds the IR for [text] with the same component rules [generate] uses.
  ///
  /// The rules live in the components, so this walk shares the grammar rather
  /// than restating it: a component's [exp] claims the same text here as it
  /// does for rendering, and both entry points run the one traversal in
  /// [_walk]. [source] and [offset] let a recursion keep addressing the
  /// document it started from.
  ///
  /// [onNode] reports each element with the component that claimed it, the way
  /// [generate] reports a span. A consumer that has to know which rule matched
  /// — rather than what the match says — uses it. A component's own content is
  /// walked on its own, so an element nested in a list item, quote or details
  /// body is reported too, against the content string that walk addressed.
  static List<MdNode> walkNodes(
    String text, {
    required GptMarkdownConfig config,
    bool includeGlobal = true,
    String? source,
    int offset = 0,
    MdNodeCallback? onNode,
  }) {
    if (includeGlobal) {
      final preprocess = config.preprocessBlocks;
      if (preprocess != null) {
        final rewritten = preprocess(text);
        // Rewritten offsets belong to another source, so the IR is built for
        // the text the renderer actually consumed.
        if (rewritten != text) {
          return walkNodes(
            rewritten,
            config: config,
            includeGlobal: true,
            onNode: onNode,
          );
        }
      }
    }
    final root = source ?? text;
    final start = source == null ? 0 : offset;
    final nodes = <MdNode>[];
    _walk(
      text,
      nodes,
      _MdNodeSink(root, config, onNode),
      config: config,
      includeGlobal: includeGlobal,
      source: root,
      start: start,
    );
    return nodes;
  }

  /// The one traversal both entry points run.
  ///
  /// It owns the grammar the components declare — the `exp` patterns, the
  /// component set for this walk, the pattern cache and where a walk recurses —
  /// and the offsets; [sink] owns what an element becomes. [source] is the
  /// document the walk addresses and [start] where [text] begins in it, so a
  /// recursion keeps naming the document it started from and every offset the
  /// sink reports is absolute in that document.
  static void _walk<R>(
    String text,
    List<R> out,
    _MdWalkSink<R> sink, {
    required GptMarkdownConfig config,
    required bool includeGlobal,
    required String source,
    required int start,
  }) {
    final components =
        includeGlobal
            ? config.components ?? MarkdownComponent.globalComponents
            : config.inlineComponents ?? MarkdownComponent.inlineComponents;
    final expressions = [for (final component in components) component.exp];
    final patternKey =
        expressions
            .map(
              (exp) =>
                  '${exp.isMultiLine}:${exp.isDotAll}:${exp.pattern.length}:${exp.pattern}',
            )
            .join();
    final patterns = _patterns.putIfAbsent(
      patternKey,
      () => _MarkdownPatterns(expressions),
    );
    if (_patterns.length > 64) _patterns.remove(_patterns.keys.first);
    var cursor = 0;
    text.splitMapJoin(
      patterns.combined,
      onMatch: (p0) {
        final element = p0[0] ?? "";
        final index = patterns.componentIndex(element);
        if (index >= 0) {
          sink.component(
            out,
            components[index],
            element,
            start + p0.start,
            start + p0.end,
            includeGlobal,
          );
        }
        cursor = p0.end;
        return "";
      },
      onNonMatch: (p0) {
        final chunkStart = start + cursor;
        cursor += p0.length;
        if (p0.isEmpty) return "";
        if (includeGlobal) {
          _walk(
            p0,
            out,
            sink,
            config: config,
            includeGlobal: false,
            source: source,
            start: chunkStart,
          );
        } else {
          sink.leaf(out, p0, chunkStart, chunkStart + p0.length);
        }
        return "";
      },
    );
  }

  /// The IR for a whole document, ready for selection mapping.
  ///
  /// [MdDocument.source] records the text the walk addressed, which is the
  /// rewritten text when the renderer rewrote one.
  static MdDocument walkDocument(
    String text, {
    required GptMarkdownConfig config,
  }) {
    final rewritten = config.preprocessBlocks?.call(text) ?? text;
    return MdDocument(walkNodes(rewritten, config: config));
  }

  InlineSpan span(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  );

  RegExp get exp;
  bool get inline;
}

/// What one element of the shared traversal becomes.
///
/// The traversal ([MarkdownComponent._walk]) owns the grammar and the offsets;
/// a sink decides whether an element is a span a renderer lays out or a node the
/// IR describes. [includeGlobal] is the walk that produced the element, which is
/// the `block` flag the element callbacks report.
abstract interface class _MdWalkSink<R> {
  /// The element [component] claimed, at `[start, end)` in the walk's source.
  void component(
    List<R> out,
    MarkdownComponent component,
    String element,
    int start,
    int end,
    bool includeGlobal,
  );

  /// Text no component claimed, in an inline walk.
  void leaf(List<R> out, String text, int start, int end);
}

/// The render sink: each element becomes the span its component builds.
final class _MdSpanSink implements _MdWalkSink<InlineSpan> {
  _MdSpanSink(this.context, this.config, this.onSpan);

  final BuildContext context;
  final GptMarkdownConfig config;
  final void Function(
    InlineSpan span,
    int start,
    int end,
    MarkdownComponent? component,
    bool block,
  )?
  onSpan;

  @override
  void component(
    List<InlineSpan> out,
    MarkdownComponent component,
    String element,
    int start,
    int end,
    bool includeGlobal,
  ) {
    final span = component.span(context, element, config);
    out.add(span);
    onSpan?.call(span, start, end, component, includeGlobal);
  }

  @override
  void leaf(List<InlineSpan> out, String text, int start, int end) {
    final span = TextSpan(text: text, style: config.style);
    out.add(span);
    onSpan?.call(span, start, end, null, false);
  }
}

/// The IR sink: each element becomes the node its component describes.
final class _MdNodeSink implements _MdWalkSink<MdNode> {
  _MdNodeSink(this.source, this.config, this.onNode);

  /// The document every node built here addresses.
  final String source;
  final GptMarkdownConfig config;
  final MdNodeCallback? onNode;

  @override
  void component(
    List<MdNode> out,
    MarkdownComponent component,
    String element,
    int start,
    int end,
    bool includeGlobal,
  ) {
    final node = component.node(
      MdNodeContext(
        source: source,
        start: start,
        includeGlobal: includeGlobal,
        config: config,
        onNode: onNode,
      ),
      element,
    );
    out.add(node);
    onNode?.call(node, start, end, component, includeGlobal);
  }

  @override
  void leaf(List<MdNode> out, String text, int start, int end) =>
      out.add(MdNode.text(MdRange(source, start, end)));
}

/// Reports one element a walk matched, with the rule that claimed it.
///
/// [start] and [end] address the source the walk that reported the element was
/// given: the document, or the content string a component re-derived and walked
/// itself. Set [block] when that walk was a document walk rather than an inline
/// one.
typedef MdNodeCallback =
    void Function(
      MdNode node,
      int start,
      int end,
      MarkdownComponent component,
      bool block,
    );

/// What a component needs to describe one matched element as an IR node.
final class MdNodeContext {
  const MdNodeContext({
    required this.source,
    required this.start,
    required this.includeGlobal,
    required this.config,
    this.onNode,
  });

  /// The document the walk is addressing.
  final String source;

  /// Offset of the matched element in [source].
  final int start;

  /// Whether the walk that produced this element was a document walk (blocks)
  /// or an inline walk.
  final bool includeGlobal;

  final GptMarkdownConfig config;

  /// The callback the walk that produced this element was given, forwarded so a
  /// nested walk reports the elements inside a component's own content too.
  final MdNodeCallback? onNode;

  /// Walks [inner] with the rule set a component's own content uses.
  ///
  /// [inner] becomes the source its nodes address: a component's content is a
  /// rewritten string (a list item drops its marker, a quote drops its `>`),
  /// so its offsets belong to that string rather than to the document. Nothing
  /// needs the absolute position — an item re-emits its own source text.
  ///
  /// Component content is inline by default, because that is what the
  /// rendering path recurses with ([MarkdownComponent.generate] with
  /// `includeGlobalComponents: false`).
  List<MdNode> walk(String inner, {bool includeGlobal = false}) =>
      MarkdownComponent.walkNodes(
        inner,
        config: config,
        includeGlobal: includeGlobal,
        onNode: onNode,
      );

  /// The range of the element [text] that starts at [start].
  MdRange rangeOf(String text) => MdRange(source, start, start + text.length);
}

// Matching depends on the patterns and source alone, not on widget state or
// theme. Cache only classification; builders still run with the current config.
class _MarkdownPatterns {
  _MarkdownPatterns(List<RegExp> expressions)
    : combined = RegExp(
        expressions.map((e) => e.pattern).join('|'),
        multiLine: true,
        dotAll: true,
      ),
      anchored = [
        for (final exp in expressions)
          RegExp(
            '^${exp.pattern}\$',
            multiLine: exp.isMultiLine,
            dotAll: exp.isDotAll,
          ),
      ];

  final RegExp combined;
  final List<RegExp> anchored;
  final _indices = <String, int>{};

  int componentIndex(String source) {
    if (source.length <= 512) {
      final cached = _indices[source];
      if (cached != null) return cached;
    }
    final index = anchored.indexWhere((exp) => exp.hasMatch(source));
    if (source.length <= 512) {
      if (_indices.length >= 128) _indices.remove(_indices.keys.first);
      _indices[source] = index;
    }
    return index;
  }
}

/// Inline component
abstract class InlineMd extends MarkdownComponent {
  @override
  bool get inline => true;

  /// Renders this element from its own node, which is what keeps what the
  /// component shows and what it reported to the IR from drifting apart.
  ///
  /// A component whose [node] describes something the emitter does not render
  /// (a formula widget, a citation chip, an HTML tag) overrides this with its
  /// own span: the emitter hands such a node back to the component set, so
  /// rendering from the node there would never return.
  @override
  InlineSpan span(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) => MdSpanEmitter(context, config).emitNode(nodeOfElement(config, text));
}

/// Block component
abstract class BlockMd extends MarkdownComponent {
  @override
  bool get inline => false;

  @override
  RegExp get exp =>
      RegExp(r'^\ *?' + expString + r"$", dotAll: true, multiLine: true);

  String get expString;

  @override
  InlineSpan span(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    var matches = RegExp(r'^(?<spaces>\ \ +).*').firstMatch(text);
    var spaces = matches?.namedGroup('spaces');
    var length = spaces?.length ?? 0;
    var child = build(context, text, config);
    length = min(length, 4);
    if (length > 0) {
      child = UnorderedListView(
        spacing: length * 1.0,
        textDirection: config.textDirection,
        child: child,
      );
    }
    child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [Flexible(child: child)],
    );
    return WidgetSpan(
      child: child,
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
    );
  }

  Widget build(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  );
}

/// Indent component
class IndentMd extends BlockMd {
  @override
  String get expString => (r"^(\ \ +)([^\n]+)$");
  @override
  Widget build(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    var match = this.exp.firstMatch(text);
    var conf = config.copyWith();
    return Directionality(
      textDirection: config.textDirection,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: config.getRich(
              TextSpan(
                children: MarkdownComponent.generate(
                  context,
                  match?[2]?.trim() ?? "",
                  conf,
                  false,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  MdNode node(MdNodeContext ctx, String text) {
    final m = this.exp.firstMatch(text);
    final content = (m?.group(2) ?? '').trim();
    return MdNode(
      kind: MdNodeKind.group,
      range: ctx.rangeOf(text),
      open: m?.group(1) ?? '',
      children: content.isEmpty ? const [] : ctx.walk(content),
    );
  }
}

/// Heading component
class HTag extends BlockMd {
  @override
  String get expString => (r"(?<hash>#{1,6})\ (?<data>[^\n]+?)$");
  @override
  Widget build(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    var theme = GptMarkdownTheme.of(context);
    var match = this.exp.firstMatch(text.trim());
    var conf = config.copyWith(
      style:
          [
            theme.h1,
            theme.h2,
            theme.h3,
            theme.h4,
            theme.h5,
            theme.h6,
          ][match![1]!.length - 1],
    );
    return config.getRich(
      TextSpan(
        children: [
          ...(MarkdownComponent.generate(
            context,
            "${match.namedGroup('data')}",
            conf,
            false,
          )),
          if (match.namedGroup('hash')!.length == 1 &&
              theme.autoAddDividerLineAfterH1) ...[
            const TextSpan(
              text: "\n ",
              style: TextStyle(fontSize: 0, height: 0),
            ),
            WidgetSpan(
              child: CustomDivider(
                height: theme.hrLineThickness,
                color: theme.hrLineColor,
                padding: theme.hrLinePadding,
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  MdNode node(MdNodeContext ctx, String text) {
    final m = this.exp.firstMatch(text.trim());
    final data = m?.group(2);
    // The optional divider a level-1 heading may draw is a widget, so it never
    // reaches a copied selection and needs no item.
    return MdNode(
      kind: MdNodeKind.heading,
      range: ctx.rangeOf(text),
      open: '${m?.group(1) ?? '#'} ',
      children: data == null ? const [] : ctx.walk(data),
    );
  }
}

class NewLines extends InlineMd {
  @override
  RegExp get exp => RegExp(r"\n\n+");
  @override
  InlineSpan span(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    return TextSpan(
      text: "\n\n",
      style: TextStyle(
        fontSize: config.style?.fontSize ?? 14,
        height: 1.15,
        color: config.style?.color,
      ),
    );
  }
}

/// Horizontal line component
class HrLine extends BlockMd {
  @override
  String get expString => (r"⸻|((--)[-]+)$");
  @override
  Widget build(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    final gptTheme = GptMarkdownTheme.of(context);
    return CustomDivider(
      height: gptTheme.hrLineThickness,
      color: gptTheme.hrLineColor,
      padding: gptTheme.hrLinePadding,
    );
  }

  @override
  MdNode node(MdNodeContext ctx, String text) =>
      MdNode.gap(MdNodeKind.group, ctx.rangeOf(text));
}

/// Checkbox component
class CheckBoxMd extends BlockMd {
  @override
  String get expString => (r"\[((?:\x|\ ))\]\ (\S[^\n]*?)$");

  @override
  Widget build(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    var match = this.exp.firstMatch(text.trim());
    return CustomCb(
      value: ("${match?[1]}" == "x"),
      textDirection: config.textDirection,
      child: MdWidget(context, "${match?[2]}", false, config: config),
    );
  }

  @override
  MdNode node(MdNodeContext ctx, String text) {
    final m = this.exp.firstMatch(text.trim());
    final item = m?.group(2);
    final checked = m?.group(1) == 'x';
    return MdNode(
      kind: MdNodeKind.listItem,
      range: ctx.rangeOf(text),
      open: '${checked ? '[x]' : '[ ]'} ',
      children: item == null ? const [] : ctx.walk(item),
    );
  }
}

/// Radio Button component
class RadioButtonMd extends BlockMd {
  @override
  String get expString => (r"\(((?:\x|\ ))\)\ (\S[^\n]*)$");

  @override
  Widget build(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    var match = this.exp.firstMatch(text.trim());
    return CustomRb(
      value: ("${match?[1]}" == "x"),
      textDirection: config.textDirection,
      child: MdWidget(context, "${match?[2]}", false, config: config),
    );
  }

  @override
  MdNode node(MdNodeContext ctx, String text) {
    final m = this.exp.firstMatch(text.trim());
    final item = m?.group(2);
    return MdNode(
      kind: MdNodeKind.listItem,
      range: ctx.rangeOf(text),
      open: '(${m?.group(1) == 'x' ? 'x' : ' '}) ',
      children: item == null ? const [] : ctx.walk(item),
    );
  }
}

/// Block quote component
class BlockQuote extends InlineMd {
  @override
  bool get inline => false;
  @override
  RegExp get exp =>
  // RegExp(r"(?<=\n\n)(\ +)(.+?)(?=\n\n)", dotAll: true, multiLine: true);
  RegExp(
    r"(?:(?:^)\ *>[^\n]+)(?:(?:\n)\ *>[^\n]+)*",
    dotAll: true,
    multiLine: true,
  );

  @override
  InlineSpan span(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    var match = exp.firstMatch(text);
    var data = markdownQuoteText(match?[0] ?? '');
    var child = TextSpan(
      children: MarkdownComponent.generate(context, data, config, true),
    );
    return TextSpan(
      children: [
        WidgetSpan(
          child: Directionality(
            textDirection: config.textDirection,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: BlockQuoteWidget(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                direction: config.textDirection,
                width: 3,
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(start: 8.0),
                  child: config.getRich(child),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  MdNode node(MdNodeContext ctx, String text) {
    final data = markdownQuoteText(exp.firstMatch(text)?[0] ?? text);
    // A quote re-emits whole: its rendered text drops one `>` per line, so a
    // partial re-emission could not put the markers back where they were.
    return MdNode.opaque(
      MdNodeKind.quote,
      ctx.rangeOf(text),
      mdDisplayOf(ctx.walk(data, includeGlobal: true)),
    );
  }
}

/// The content of a block quote: one leading `>` and one optional space are
/// dropped per line, then the whole is trimmed.
///
/// Shared by the rendered spans and the IR so the two cannot disagree about
/// what a quote says. Leading blanks are spaces or tabs, the two a quote may
/// be indented with.
String markdownQuoteText(String matched) {
  final builder = StringBuffer();
  for (var each in matched.split('\n')) {
    if (each.startsWith(RegExp(r'[ \t]*>'))) {
      var subString = each.trimLeft().substring(1);
      if (subString.startsWith(' ')) {
        subString = subString.substring(1);
      }
      builder.writeln(subString);
    } else {
      builder.writeln(each);
    }
  }
  return builder.toString().trim();
}

/// Unordered list component
class UnOrderedList extends BlockMd {
  @override
  String get expString => (r"(?:\-|\*)\ ([^\n]+)$");

  @override
  Widget build(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    var match = this.exp.firstMatch(text);

    var child = MdWidget(context, "${match?[1]?.trim()}", true, config: config);

    return config.unOrderedListBuilder?.call(
          context,
          child,
          config.copyWith(),
        ) ??
        UnorderedListView(
          bulletColor:
              (config.style?.color ?? DefaultTextStyle.of(context).style.color),
          padding: 7,
          spacing: 10,
          bulletSize:
              0.3 *
              (config.style?.fontSize ??
                  DefaultTextStyle.of(context).style.fontSize ??
                  kDefaultFontSize),
          textDirection: config.textDirection,
          child: child,
        );
  }

  @override
  MdNode node(MdNodeContext ctx, String text) {
    final m = this.exp.firstMatch(text);
    final item = (m?.group(1) ?? '').trim();
    return MdNode(
      kind: MdNodeKind.listItem,
      range: ctx.rangeOf(text),
      open: '- ',
      children: item.isEmpty ? const [] : ctx.walk(item, includeGlobal: true),
    );
  }
}

/// Ordered list component
class OrderedList extends BlockMd {
  @override
  String get expString => (r"([0-9]+)\.\ ([^\n]+)$");

  @override
  Widget build(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    var match = this.exp.firstMatch(text);

    var no = "${match?[1]}".trim();

    var child = MdWidget(context, "${match?[2]}".trim(), true, config: config);
    return config.orderedListBuilder?.call(
          context,
          no,
          child,
          config.copyWith(),
        ) ??
        OrderedListView(
          no: "$no.",
          textDirection: config.textDirection,
          style: (config.style ?? const TextStyle()).copyWith(
            fontWeight: FontWeight.w100,
          ),
          child: child,
        );
  }

  @override
  MdNode node(MdNodeContext ctx, String text) {
    final m = this.exp.firstMatch(text);
    final item = (m?.group(2) ?? '').trim();
    final number = (m?.group(1) ?? '').trim();
    return MdNode(
      kind: MdNodeKind.listItem,
      range: ctx.rangeOf(text),
      open: '$number. ',
      children: [
        // The renderer draws the number as its own text, so a selection
        // includes it; the marker re-emitted above carries it as well.
        if (number.isNotEmpty) MdNode.decoration('$number.'),
        if (item.isNotEmpty) ...ctx.walk(item, includeGlobal: true),
      ],
    );
  }
}

class HighlightedText extends InlineMd {
  @override
  RegExp get exp => RegExp(r"`(?!`)(.+?)(?<!`)`(?!`)");

  @override
  MdNode node(MdNodeContext ctx, String text) {
    final m = exp.firstMatch(text.trim());
    final inner = m?.group(1);
    if (inner == null) return MdNode.text(ctx.rangeOf(text));
    // Inline code is rendered as plain text with a highlight style, so its
    // content is never parsed again.
    return MdNode(
      kind: MdNodeKind.inlineCode,
      range: ctx.rangeOf(text),
      open: '`',
      close: '`',
      children: [MdNode.text(MdRange.all(inner))],
    );
  }
}

/// Bold text component
class BoldMd extends InlineMd {
  @override
  RegExp get exp =>
      RegExp(r"(?<!\*)\*\*(?<!\s)(.+?)(?<!\s)\*\*(?!\*)", dotAll: true);

  /// The weight this surface draws emphasis with.
  ///
  /// [MdSpanEmitter] reads it from the bold component the configuration
  /// renders with, so a theme that renders emphasis differently only has to
  /// replace the component.
  FontWeight get emphasisWeight => FontWeight.bold;

  @override
  MdNode node(MdNodeContext ctx, String text) {
    final m = exp.firstMatch(text.trim());
    final inner = m?.group(1);
    return MdNode(
      kind: MdNodeKind.bold,
      range: ctx.rangeOf(text),
      open: '**',
      close: '**',
      children: inner == null ? const [] : ctx.walk(inner),
    );
  }
}

class StrikeMd extends InlineMd {
  @override
  RegExp get exp => RegExp(r"(?<!\*)\~\~(?<!\s)(.+?)(?<!\s)\~\~(?!\*)");

  @override
  MdNode node(MdNodeContext ctx, String text) {
    final m = exp.firstMatch(text.trim());
    final inner = m?.group(1);
    return MdNode(
      kind: MdNodeKind.strike,
      range: ctx.rangeOf(text),
      open: '~~',
      close: '~~',
      children: inner == null ? const [] : ctx.walk(inner),
    );
  }
}

/// Italic text component
class ItalicMd extends InlineMd {
  @override
  RegExp get exp =>
      RegExp(r"(?:(?<!\*)\*(?<!\s)(.+?)(?<!\s)\*(?!\*))", dotAll: true);

  @override
  MdNode node(MdNodeContext ctx, String text) {
    final m = exp.firstMatch(text.trim());
    final inner = m?.group(1) ?? m?.group(2);
    return MdNode(
      kind: MdNodeKind.italic,
      range: ctx.rangeOf(text),
      open: '*',
      close: '*',
      children: inner == null ? const [] : ctx.walk(inner),
    );
  }
}

class LatexMathMultiLine extends BlockMd {
  @override
  String get expString => (r"\ *\\\[((?:.)*?)\\\]");
  // (r"\ *\\\[((?:(?!\n\n\n).)*?)\\\]|(\\begin.*?\\end{.*?})");
  @override
  RegExp get exp => RegExp(expString, dotAll: true, multiLine: true);

  @override
  Widget build(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    var p0 = exp.firstMatch(text.trim());
    String mathText = p0?[1] ?? p0?[2] ?? '';
    var workaround = config.latexWorkaround ?? (String tex) => tex;

    var builder =
        config.latexBuilder ??
        (BuildContext context, String tex, TextStyle textStyle, bool inline) =>
            SelectableAdapter(
              selectedText: tex,
              child: Math.tex(
                tex,
                textStyle: textStyle,
                mathStyle: MathStyle.display,
                textScaleFactor: 1,
                settings: const TexParserSettings(strict: Strict.ignore),
                options: MathOptions(
                  sizeUnderTextStyle: MathSize.large,
                  color:
                      config.style?.color ??
                      DefaultTextStyle.of(context).style.color ??
                      Theme.of(context).colorScheme.onSurface,
                  fontSize:
                      config.style?.fontSize ??
                      Theme.of(context).textTheme.bodyMedium?.fontSize,
                  mathFontOptions: FontOptions(
                    fontFamily: "Main",
                    fontWeight: config.style?.fontWeight ?? FontWeight.normal,
                    fontShape: FontStyle.normal,
                  ),
                  textFontOptions: FontOptions(
                    fontFamily: "Main",
                    fontWeight: config.style?.fontWeight ?? FontWeight.normal,
                    fontShape: FontStyle.normal,
                  ),
                  style: MathStyle.display,
                ),
                onErrorFallback: (err) {
                  return Text(
                    workaround(mathText),
                    textDirection: config.textDirection,
                    style: textStyle.copyWith(
                      color:
                          (!kDebugMode)
                              ? null
                              : Theme.of(context).colorScheme.error,
                    ),
                  );
                },
              ),
            );
    return builder(
      context,
      workaround(mathText),
      config.style ?? const TextStyle(),
      false,
    );
  }

  @override
  MdNode node(MdNodeContext ctx, String text) {
    final m = exp.firstMatch(text.trim());
    final body = m?.group(1) ?? m?.group(2) ?? '';
    final workaround = ctx.config.latexWorkaround ?? (String tex) => tex;
    // The default rendering wraps the formula in a SelectableAdapter that
    // declares exactly this text, so a selection sees the TeX source.
    return MdNode.opaque(MdNodeKind.math, ctx.rangeOf(text), workaround(body));
  }
}

/// Italic text component
class LatexMath extends InlineMd {
  @override
  RegExp get exp => RegExp(
    [
      r"\\\((.*?)\\\)",
      // r"(?<!\\)\$((?:\\.|[^$])*?)\$(?!\\)",
    ].join("|"),
    dotAll: true,
  );

  @override
  InlineSpan span(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    var p0 = exp.firstMatch(text.trim());
    p0?.group(0);
    String mathText = p0?[1]?.toString() ?? "";
    var workaround = config.latexWorkaround ?? (String tex) => tex;
    var builder =
        config.latexBuilder ??
        (BuildContext context, String tex, TextStyle textStyle, bool inline) =>
            SelectableAdapter(
              selectedText: tex,
              child: Math.tex(
                tex,
                textStyle: textStyle,
                mathStyle: MathStyle.display,
                textScaleFactor: 1,
                settings: const TexParserSettings(strict: Strict.ignore),
                options: MathOptions(
                  sizeUnderTextStyle: MathSize.large,
                  color:
                      config.style?.color ??
                      DefaultTextStyle.of(context).style.color ??
                      Theme.of(context).colorScheme.onSurface,
                  fontSize:
                      config.style?.fontSize ??
                      Theme.of(context).textTheme.bodyMedium?.fontSize,
                  mathFontOptions: FontOptions(
                    fontFamily: "Main",
                    fontWeight: config.style?.fontWeight ?? FontWeight.normal,
                    fontShape: FontStyle.normal,
                  ),
                  textFontOptions: FontOptions(
                    fontFamily: "Main",
                    fontWeight: config.style?.fontWeight ?? FontWeight.normal,
                    fontShape: FontStyle.normal,
                  ),
                  style: MathStyle.display,
                ),
                onErrorFallback: (err) {
                  return Text(
                    workaround(mathText),
                    textDirection: config.textDirection,
                    style: textStyle.copyWith(
                      color:
                          (!kDebugMode)
                              ? null
                              : Theme.of(context).colorScheme.error,
                    ),
                  );
                },
              ),
            );
    return WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: builder(
        context,
        workaround(mathText),
        config.style ?? const TextStyle(),
        true,
      ),
    );
  }

  @override
  MdNode node(MdNodeContext ctx, String text) {
    final m = exp.firstMatch(text.trim());
    final workaround = ctx.config.latexWorkaround ?? (String tex) => tex;
    // The widget declares this exact text through its SelectableAdapter.
    return MdNode.opaque(
      MdNodeKind.math,
      ctx.rangeOf(text),
      workaround(m?.group(1) ?? ''),
    );
  }
}

/// source text component
class SourceTag extends InlineMd {
  @override
  RegExp get exp => RegExp(r"(?:【.*?)?\[(\d+?)\]");

  @override
  InlineSpan span(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    final content = _contentOf(text);
    if (content == null) {
      return const TextSpan();
    }
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child:
            config.sourceTagBuilder?.call(
              context,
              content,
              const TextStyle(),
            ) ??
            SizedBox(
              width: 20,
              height: 20,
              child: Material(
                color: Theme.of(context).colorScheme.onInverseSurface,
                shape: const OvalBorder(),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    content,
                    // style: (style ?? const TextStyle()).copyWith(),
                    textDirection: config.textDirection,
                  ),
                ),
              ),
            ),
      ),
    );
  }

  @override
  MdNode node(MdNodeContext ctx, String text) {
    final content = _contentOf(text);
    if (content == null) return MdNode.text(ctx.rangeOf(text));
    // A citation chip shows its number in its own text widget, so the source
    // that carries the chip is re-emitted whole.
    return MdNode.opaque(MdNodeKind.group, ctx.rangeOf(text), content);
  }

  /// The number a citation chip shows, or `null` when the element is not one.
  ///
  /// Shared by the chip and the IR node, so the two cannot disagree about what
  /// the chip says.
  String? _contentOf(String text) => exp.firstMatch(text.trim())?.group(1);
}

/// Link text component
class ATagMd extends InlineMd {
  @override
  RegExp get exp => RegExp(r"(?<!\!)\[.*\]\([^\s]*\)");

  @override
  MdNode node(MdNodeContext ctx, String text) {
    final link = _parseLinkElement(text);
    if (link == null) return MdNode.text(ctx.rangeOf(text));
    final children = <MdNode>[
      MdNode(
        kind: MdNodeKind.link,
        range: MdRange(text, 0, link.closingParen + 1),
        open: '[',
        close: '](${link.url})',
        children: ctx.walk(link.label),
      ),
    ];
    if (link.ending.isNotEmpty) {
      children.addAll(ctx.walk(link.ending));
    }
    return MdNode(
      kind: MdNodeKind.group,
      range: ctx.rangeOf(text),
      children: children,
    );
  }
}

/// The parts of a link element `[label](url)` and whatever follows it.
final class _LinkElement {
  const _LinkElement({
    required this.label,
    required this.url,
    required this.closingParen,
    required this.ending,
  });

  final String label;
  final String url;

  /// Offset of the `)` that closes the target.
  final int closingParen;

  /// Text after the link, which the component renders as its own content.
  final String ending;
}

/// Scans one link element.
///
/// Shared by the rendered span and the IR node so the two cannot disagree
/// about where a label ends and a target begins.
_LinkElement? _parseLinkElement(String text) {
  var bracketCount = 0;
  const start = 1;
  var end = 0;
  for (var i = 0; i < text.length; i++) {
    if (text[i] == '[') {
      bracketCount++;
    } else if (text[i] == ']') {
      bracketCount--;
      if (bracketCount == 0) {
        end = i;
        break;
      }
    }
  }

  if (end + 1 >= text.length || text[end + 1] != '(') return null;

  final label = text.substring(start, end);
  final urlStart = end + 2;

  // Find the balanced closing parenthesis.
  var parenCount = 0;
  var urlEnd = urlStart;
  for (var i = urlStart; i < text.length; i++) {
    final char = text[i];
    if (char == '(') {
      parenCount++;
    } else if (char == ')') {
      if (parenCount == 0) {
        urlEnd = i;
        break;
      }
      parenCount--;
    }
  }

  if (urlEnd == urlStart) return null;

  return _LinkElement(
    label: label,
    url: text.substring(urlStart, urlEnd).trim(),
    closingParen: urlEnd,
    ending: text.substring(urlEnd + 1),
  );
}

/// Image component
class ImageMd extends InlineMd {
  @override
  RegExp get exp => RegExp(r"\!\[[^\[\]]*\]\([^\s]*\)");

  @override
  MdNode node(MdNodeContext ctx, String text) =>
  // An image is a widget: it contributes no text to a selection, and it
  // re-emits whole whenever a selection spans across it.
  MdNode.gap(MdNodeKind.image, ctx.rangeOf(text));
}

/// The parts of an image element `![alt](url)`.
final class _ImageElement {
  const _ImageElement({
    required this.url,
    required this.width,
    required this.height,
  });

  final String url;
  final double? width;
  final double? height;
}

/// Scans one image element, including the size `alt` spells as `WxH`.
///
/// The source is scanned rather than matched again, because an image target may
/// contain balanced parentheses that a pattern would cut short.
_ImageElement? _parseImageElement(String text) {
  final basicMatch = RegExp(r'\!\[([^\[\]]*)\]\(').firstMatch(text.trim());
  if (basicMatch == null) return null;

  final altText = basicMatch.group(1) ?? '';
  final urlStart = basicMatch.end;

  var parenCount = 0;
  var urlEnd = urlStart;
  for (var i = urlStart; i < text.length; i++) {
    final char = text[i];
    if (char == '(') {
      parenCount++;
    } else if (char == ')') {
      if (parenCount == 0) {
        urlEnd = i;
        break;
      }
      parenCount--;
    }
  }
  if (urlEnd == urlStart) return null;

  double? height;
  double? width;
  if (altText.isNotEmpty) {
    final size = RegExp(r"^([0-9]+)?x?([0-9]+)?").firstMatch(altText.trim());
    width = double.tryParse(size?[1]?.toString().trim() ?? 'a');
    height = double.tryParse(size?[2]?.toString().trim() ?? 'a');
  }
  return _ImageElement(
    url: text.substring(urlStart, urlEnd).trim(),
    width: width,
    height: height,
  );
}

/// Splits a table into rows of cells: rows on newlines, cells on the pipes
/// between them, empty cells dropped.
///
/// Shared by the rendered table and the IR node so the two cannot disagree
/// about which cell holds which text.
List<List<String>> _markdownTableRows(String text) =>
    text
        .split('\n')
        .map(
          (e) =>
              e
                  .trim()
                  .split('|')
                  .where((element) => element.isNotEmpty)
                  .toList(),
        )
        .toList();

/// Table component
class TableMd extends BlockMd {
  @override
  String get expString =>
      (r"(((\|[^\n\|]+\|)((([^\n\|]+\|)+)?)\ *)(\n\ *(((\|[^\n\|]+\|)(([^\n\|]+\|)+)?))\ *)+)$");
  @override
  Widget build(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    final List<Map<int, String>> value =
        _markdownTableRows(text).map((row) => row.asMap()).toList();

    // Check if table has a header and separator row
    bool hasHeader = value.length >= 2;
    List<TextAlign> columnAlignments = [];

    if (hasHeader) {
      // Parse alignment from the separator row (second row)
      var separatorRow = value[1];
      columnAlignments = List.generate(separatorRow.length, (index) {
        String separator = separatorRow[index] ?? "";
        separator = separator.trim();

        // Check for alignment indicators
        bool hasLeftColon = separator.startsWith(':');
        bool hasRightColon = separator.endsWith(':');

        if (hasLeftColon && hasRightColon) {
          return TextAlign.center;
        } else if (hasRightColon) {
          return TextAlign.right;
        } else if (hasLeftColon) {
          return TextAlign.left;
        } else {
          return TextAlign.left; // Default alignment
        }
      });
    }

    int maxCol = 0;
    for (final each in value) {
      if (maxCol < each.keys.length) {
        maxCol = each.keys.length;
      }
    }

    if (maxCol == 0) {
      return Text("", style: config.style);
    }

    // Ensure we have alignment for all columns
    while (columnAlignments.length < maxCol) {
      columnAlignments.add(TextAlign.left);
    }

    var tableBuilder = config.tableBuilder;

    if (tableBuilder != null) {
      var customTable =
          List<CustomTableRow?>.generate(value.length, (index) {
            var isHeader = index == 0;
            var row = value[index];
            if (row.isEmpty) {
              return null;
            }
            if (index == 1) {
              return null;
            }
            var fields = List<CustomTableField>.generate(maxCol, (index) {
              var field = row[index];
              return CustomTableField(
                data: field ?? "",
                alignment: columnAlignments[index],
              );
            });
            return CustomTableRow(isHeader: isHeader, fields: fields);
          }).nonNulls.toList();
      return tableBuilder(
        context,
        customTable,
        config.style ?? const TextStyle(),
        config,
      );
    }

    final controller = ScrollController();
    return Scrollbar(
      controller: controller,
      child: SingleChildScrollView(
        controller: controller,
        scrollDirection: Axis.horizontal,
        child: Table(
          textDirection: config.textDirection,
          defaultColumnWidth: CustomTableColumnWidth(),
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          border: TableBorder.all(
            width: 1,
            color: Theme.of(context).colorScheme.onSurface,
          ),
          children:
              value
                  .asMap()
                  .entries
                  .where((entry) {
                    // Skip the separator row (second row) from rendering
                    if (hasHeader && entry.key == 1) {
                      return false;
                    }
                    return true;
                  })
                  .map<TableRow>(
                    (entry) => TableRow(
                      decoration:
                          (hasHeader && entry.key == 0)
                              ? BoxDecoration(
                                color:
                                    Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainerHighest,
                              )
                              : null,
                      children: List.generate(maxCol, (index) {
                        var e = entry.value;
                        String data = e[index] ?? "";
                        if (RegExp(r"^:?--+:?$").hasMatch(data.trim()) ||
                            data.trim().isEmpty) {
                          return const SizedBox();
                        }

                        // Apply alignment based on column alignment
                        Widget content = Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          child: MdWidget(
                            context,
                            (e[index] ?? "").trim(),
                            false,
                            config: config,
                          ),
                        );

                        // Wrap with alignment widget
                        switch (columnAlignments[index]) {
                          case TextAlign.center:
                            content = Center(child: content);
                            break;
                          case TextAlign.right:
                            content = Align(
                              alignment: Alignment.centerRight,
                              child: content,
                            );
                            break;
                          case TextAlign.left:
                          default:
                            content = Align(
                              alignment: Alignment.centerLeft,
                              child: content,
                            );
                            break;
                        }

                        return content;
                      }),
                    ),
                  )
                  .toList(),
        ),
      ),
    );
  }

  @override
  MdNode node(MdNodeContext ctx, String text) {
    // Mirror how the table is split for rendering: rows on newlines, cells on
    // unescaped pipes, the alignment row skipped, empty cells showing nothing.
    final rows = _markdownTableRows(text);
    final hasHeader = rows.length >= 2;
    final buffer = StringBuffer();
    for (var row = 0; row < rows.length; row++) {
      if (hasHeader && row == 1) continue;
      for (final cell in rows[row]) {
        final data = cell.trim();
        if (data.isEmpty || RegExp(r'^:?--+:?$').hasMatch(data)) continue;
        buffer.write(mdDisplayOf(ctx.walk(data)));
      }
    }
    // A table re-emits whole: a partly covered row would have to invent its own
    // pipes and alignment, which is a different table.
    return MdNode.opaque(
      MdNodeKind.table,
      ctx.rangeOf(text),
      buffer.toString(),
    );
  }
}

class CodeBlockMd extends BlockMd {
  @override
  String get expString => r"```(.*?)\n((.*?)(:?\n\s*?```)|(.*)(:?\n```)?)$";
  @override
  Widget build(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    String codes = this.exp.firstMatch(text)?[2] ?? "";
    String name = this.exp.firstMatch(text)?[1] ?? "";
    codes = codes.replaceAll(r"```", "");
    bool closed = text.endsWith("```");

    return config.codeBuilder?.call(context, name, codes, closed) ??
        CodeField(name: name, codes: codes);
  }

  @override
  MdNode node(MdNodeContext ctx, String text) {
    final codes = (this.exp.firstMatch(text)?[2] ?? '').replaceAll(r'```', '');
    return MdNode.opaque(MdNodeKind.codeBlock, ctx.rangeOf(text), codes);
  }
}

class UnderLineMd extends InlineMd {
  @override
  RegExp get exp =>
      RegExp(r"<u>(.*?)(?:</u>|$)", multiLine: true, dotAll: true);

  @override
  MdNode node(MdNodeContext ctx, String text) {
    final m = exp.firstMatch(text.trim());
    final inner = m?.group(1);
    return MdNode(
      kind: MdNodeKind.underline,
      range: ctx.rangeOf(text),
      open: '<u>',
      close: '</u>',
      children: inner == null ? const [] : ctx.walk(inner),
    );
  }
}

class CustomTableField {
  final String data;
  final TextAlign alignment;

  CustomTableField({required this.data, this.alignment = TextAlign.left});
}

class CustomTableRow {
  final bool isHeader;
  final List<CustomTableField> fields;

  CustomTableRow({this.isHeader = false, required this.fields});
}
