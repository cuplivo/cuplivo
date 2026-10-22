import 'package:markstream/markstream.dart' show DocumentNode, toMarkdown;

/// The most recent chat-surface text selection, kept so a toolbar item or a
/// desktop hotkey can act on it after the framework has taken the selection
/// away.
///
/// The live selection is Flutter's: every access to markstream's
/// `MarkstreamSelectionController.selection` re-reads the range from the
/// `SelectionContainer` delegates, and keeps nothing. So a secondary tap, a tap
/// elsewhere, or a streaming re-parse that replaces the document makes the
/// selected markdown disappear — including between the gesture that opens the
/// context menu and the menu being built.
///
/// What is recorded is the **pruned AST** of the selection
/// (`MarkstreamSelection.content`), not a rendered string: recording is then a
/// reference copy, and `toMarkdown` runs only when an action asks for the text.
/// Serializing on every selection change would re-emit the whole selection on
/// every drag frame.
///
/// Only chat surfaces record here (they know the message a reply cites); a
/// selection in a markdown preview has no message to cite.
class SelectionMarkdownMemory {
  SelectionMarkdownMemory._();

  /// The app-wide holder. A plain singleton: at most one text selection is
  /// active at a time, and a global hotkey has no surface to ask.
  static final SelectionMarkdownMemory instance = SelectionMarkdownMemory._();

  /// The surface that recorded the selection, so a surface that goes away
  /// retires what it recorded instead of leaving a hotkey a selection nobody
  /// can see. Compared by identity: a surface passes its own `State`.
  Object? _owner;

  /// The message the recorded selection was made in: what a reply cites.
  String? _messageId;

  /// The recorded selection as a tree, already clipped to the selected text.
  List<DocumentNode> _content = const [];

  /// Records a selection made by [owner]'s surface in [messageId].
  ///
  /// [content] is `MarkstreamSelectionController.selections`' `content`
  /// snippets, captured by reference: a streaming re-parse builds a new tree
  /// instead of mutating this one, so what was selected stays what was
  /// selected.
  void capture({
    required Object owner,
    required String messageId,
    required List<DocumentNode> content,
  }) {
    _owner = owner;
    _messageId = messageId;
    _content = List<DocumentNode>.unmodifiable(content);
  }

  /// Forgets the recorded selection (the selection was cleared or emptied).
  void clear() {
    _owner = null;
    _messageId = null;
    _content = const [];
  }

  /// Forgets the recorded selection when [owner]'s surface recorded it.
  void clearIfOwner(Object owner) {
    if (identical(_owner, owner)) clear();
  }

  /// What the desktop hotkey copies for the recorded selection, or `null` when
  /// nothing is recorded.
  String? markdownForSelection() {
    final content = _content;
    if (content.isEmpty) return null;
    final text = content.map(toMarkdown).join('\n\n');
    return text.isEmpty ? null : text;
  }

  /// [markdownForSelection] restricted to [owner]'s own recording, so a menu
  /// built by one surface is never answered by a sibling's selection.
  String? markdownIfOwner(Object owner) =>
      identical(_owner, owner) ? markdownForSelection() : null;

  /// What the desktop hotkey replies with for the recorded selection: the
  /// markdown plus the message it came from, or `null` when nothing is
  /// recorded.
  ///
  /// Same serialization as [markdownForSelection], so "copy as Markdown" and
  /// "reply with this" can never disagree about what was selected.
  ({String messageId, String markdown})? replySourceForSelection() {
    final messageId = _messageId;
    if (messageId == null || messageId.isEmpty) return null;
    final markdown = markdownForSelection();
    if (markdown == null || markdown.trim().isEmpty) return null;
    return (messageId: messageId, markdown: markdown);
  }
}
