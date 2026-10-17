part of 'gpt_markdown.dart';

/// Renders IR nodes back into the inline spans a text widget lays out.
///
/// The structure comes from the nodes, so a component that renders through the
/// emitter cannot disagree with what it reported to the IR: the styling and
/// widget choices for the kinds below live here, once, instead of being
/// restated in each component's `span`.
///
/// A node the emitter does not describe is handed back to the component set
/// ([MarkdownComponent.generate]) with the element's own source, which is what
/// re-rendering that element on its own does. That is why the kinds handled
/// here and the components that render through [MarkdownComponent.nodeOfElement]
/// are the same set: a node whose component renders itself would reach
/// [emitNode] again and never return.
final class MdSpanEmitter {
  MdSpanEmitter(this.context, this.config, {this.includeGlobal = false})
    : emphasisWeight = _emphasisWeightOf(config);

  MdSpanEmitter._(
    this.context,
    this.config,
    this.includeGlobal,
    this.emphasisWeight,
  );

  /// The surface's ink for emphasis, read from the bold component the walk
  /// renders with: a theme that draws emphasis differently from the framework
  /// default replaces that component, and a node only records that its text is
  /// emphasised.
  static FontWeight _emphasisWeightOf(GptMarkdownConfig config) {
    for (final component
        in config.inlineComponents ?? MarkdownComponent.inlineComponents) {
      if (component is BoldMd) return component.emphasisWeight;
    }
    return FontWeight.bold;
  }

  final BuildContext context;
  final GptMarkdownConfig config;

  /// The walk the nodes handed to this emitter were reached from: a document
  /// walk ([MarkdownComponent.generate] with `includeGlobalComponents: true`)
  /// or an inline one.
  ///
  /// Only [node]s the emitter has to hand back to the component set read it,
  /// because a component's `span` is what renders an element on its own.
  final bool includeGlobal;

  final FontWeight emphasisWeight;

  MdSpanEmitter _child(GptMarkdownConfig config) =>
      MdSpanEmitter._(context, config, includeGlobal, emphasisWeight);

  /// The spans for [nodes] as one run: a group is flattened into its parent.
  List<InlineSpan> emit(List<MdNode> nodes) {
    final out = <InlineSpan>[];
    for (final node in nodes) {
      if (node.kind == MdNodeKind.group && node.children.isNotEmpty) {
        out.addAll(emit(node.children));
      } else {
        out.add(emitNode(node));
      }
    }
    return out;
  }

  /// The span for one [node].
  InlineSpan emitNode(MdNode node) {
    switch (node.kind) {
      case MdNodeKind.text:
        return TextSpan(text: node.range!.text, style: config.style);
      case MdNodeKind.decoration:
        // Text the renderer shows but the source does not contain, drawn as
        // text because a selection copies it.
        return TextSpan(text: node.display ?? '', style: config.style);
      case MdNodeKind.bold:
        return _styled(
          node,
          config.style?.copyWith(fontWeight: emphasisWeight) ??
              TextStyle(fontWeight: emphasisWeight),
        );
      case MdNodeKind.italic:
        return _styled(
          node,
          (config.style ?? const TextStyle()).copyWith(
            fontStyle: FontStyle.italic,
          ),
        );
      case MdNodeKind.strike:
        return _styled(
          node,
          config.style?.copyWith(
                decoration: TextDecoration.lineThrough,
                decorationColor: config.style?.color,
              ) ??
              const TextStyle(decoration: TextDecoration.lineThrough),
        );
      case MdNodeKind.underline:
        return _styled(
          node,
          (config.style ?? const TextStyle()).copyWith(
            decoration: TextDecoration.underline,
            decorationColor: config.style?.color,
          ),
        );
      case MdNodeKind.inlineCode:
        return _inlineCode(node);
      case MdNodeKind.link:
        // Another component's `link` kind — an HTML anchor — describes the text
        // it shows without being a `[label](url)` element, so it has no scan.
        return _link(node) ?? _fromComponent(node);
      case MdNodeKind.image:
        return _image(node);
      case MdNodeKind.group:
        if (node.children.isEmpty) return _fromComponent(node);
        return TextSpan(children: _child(config).emit(node.children));
      default:
        return _fromComponent(node);
    }
  }

  /// A structural node: its own style, its children rendered with it.
  InlineSpan _styled(MdNode node, TextStyle style) => TextSpan(
    style: style,
    children: _child(config.copyWith(style: style)).emit(node.children),
  );

  /// Inline code, rendered as either the highlight widget or a styled run.
  InlineSpan _inlineCode(MdNode node) {
    final inner = _leafText(node.children);
    final builder = config.highlightBuilder;
    if (builder != null) {
      return WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: builder(context, inner, config.style ?? const TextStyle()),
      );
    }
    final background =
        Paint()
          ..color = GptMarkdownTheme.of(context).highlightColor
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
    final style =
        config.style?.copyWith(
          fontWeight: FontWeight.bold,
          background: background,
        ) ??
        TextStyle(fontWeight: FontWeight.bold, background: background);
    return TextSpan(text: inner, style: style);
  }

  /// The span for a `[label](url)` element, or `null` when [node] is not one.
  InlineSpan? _link(MdNode node) {
    final range = node.range;
    if (range == null) return null;
    final link = _parseLinkElement(range.text);
    if (link == null) return null;
    final linkText = link.label;
    final url = link.url;
    final theme = GptMarkdownTheme.of(context);
    final linkStyle = (config.style ?? const TextStyle()).copyWith(
      color: theme.linkColor,
      decorationColor: theme.linkColor,
      decoration: TextDecoration.underline,
    );
    final builder = config.linkBuilder;
    if (builder != null) {
      return WidgetSpan(
        baseline: TextBaseline.alphabetic,
        alignment: PlaceholderAlignment.baseline,
        child: GestureDetector(
          onTap: () => config.onLinkTap?.call(url, linkText),
          child: builder(
            context,
            _linkLabel(node, linkStyle),
            url,
            config.style ?? const TextStyle(),
          ),
        ),
      );
    }
    // Default rendering — LinkButton rebuilds the span on every hover change
    // so bold/italic text inside a link also picks up the hover colour.
    return WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: LinkButton(
        hoverColor: theme.linkHoverColor,
        color: theme.linkColor,
        onPressed: () {
          config.onLinkTap?.call(url, linkText);
        },
        text: linkText,
        config: config,
        spanBuilder: (color) {
          final spanStyle = (config.style ?? const TextStyle()).copyWith(
            color: color,
            decorationColor: color,
            decoration: TextDecoration.underline,
          );
          return _linkLabel(node, spanStyle);
        },
      ),
    );
  }

  InlineSpan _linkLabel(MdNode node, TextStyle style) => TextSpan(
    style: style,
    children: _child(config.copyWith(style: style)).emit(node.children),
  );

  /// An image element, drawn by the surface's builder or the default loading
  /// `Image`. An image shows no text, so an element the scan cannot read draws
  /// nothing — which is what its node claims.
  InlineSpan _image(MdNode node) {
    final element = node.range?.text;
    final parsed = element == null ? null : parseMarkdownImageElement(element);
    if (parsed == null) return const TextSpan();
    final Widget image;
    final builder = config.imageBuilder;
    if (builder != null) {
      image = builder(context, parsed.url, parsed.width, parsed.height);
    } else {
      image = SizedBox(
        width: parsed.width,
        height: parsed.height,
        child: Image(
          image: NetworkImage(parsed.url),
          loadingBuilder: (
            BuildContext context,
            Widget child,
            ImageChunkEvent? loadingProgress,
          ) {
            if (loadingProgress == null) {
              return child;
            }
            return CustomImageLoading(
              progress:
                  loadingProgress.expectedTotalBytes != null
                      ? loadingProgress.cumulativeBytesLoaded /
                          loadingProgress.expectedTotalBytes!
                      : 1,
            );
          },
          fit: BoxFit.fill,
          errorBuilder: (context, error, stackTrace) {
            return const CustomImageError();
          },
        ),
      );
    }
    return WidgetSpan(alignment: PlaceholderAlignment.bottom, child: image);
  }

  /// Hands [node] back to the component that claimed it.
  ///
  /// The element is rendered from its own source with this emitter's walk mode,
  /// which is what a component that does not build its span from a node does
  /// for itself: a formula, a citation chip, a table, a block container.
  InlineSpan _fromComponent(MdNode node) {
    final range = node.range;
    if (range == null) return const TextSpan();
    final spans = MarkdownComponent.generate(
      context,
      range.text,
      config,
      includeGlobal,
    );
    // One element renders as the one span its component builds; only a
    // component that produced several is wrapped.
    return spans.length == 1 ? spans.first : TextSpan(children: spans);
  }

  /// The text of a node's content, which inline code holds as one leaf.
  static String _leafText(List<MdNode> children) {
    if (children.isEmpty) return '';
    final leaf = children.first;
    return leaf.range?.text ?? leaf.display ?? '';
  }
}
