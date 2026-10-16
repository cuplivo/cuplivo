import 'package:gpt_markdown/gpt_markdown.dart'
    show MdDocument, stripRendererInsertedCharacters;

/// The markdown [document]'s re-emitter answers for [selectedText], or the
/// sanitized plain text when the selection cannot be mapped — a miss is never
/// worse than a copy, and an empty selection is nothing at all.
///
/// One function for the toolbar item and for the hotkey, so the two cannot
/// drift apart. [document] is a thunk because the walk is rebuilt per copy
/// rather than kept per rendered widget.
String? selectionMarkdownFrom(
  MdDocument Function() document,
  String selectedText,
) {
  if (selectedText.trim().isEmpty) return null;
  return document().emitSelectionMarkdown(selectedText) ??
      stripRendererInsertedCharacters(selectedText);
}

/// The most recent assistant text selection, kept so the desktop
/// copy-selection-as-markdown hotkey can act on it without opening the context
/// menu (a workaround for the framework-level instability where a right-click
/// can clear a long backward selection).
///
/// Written by every assistant content selection area on each selection change;
/// read by the hotkey handler. The toolbar item does **not** read it — it maps
/// the selection of the surface that built the menu, so two replies with live
/// selections cannot answer for each other.
///
/// Selections made in other markdown surfaces (user message, translation,
/// reasoning) do not record here — the hotkey is only about restoring the
/// markdown source of an assistant reply.
class SelectionMarkdownMemory {
  SelectionMarkdownMemory._();

  /// The app-wide holder. A plain singleton: at most one text selection is
  /// active at a time, and a global hotkey has no surface to ask.
  static final SelectionMarkdownMemory instance = SelectionMarkdownMemory._();

  /// The token of the surface that recorded the selection, so a surface that
  /// goes away retires what it recorded instead of leaving the hotkey a
  /// selection nobody can see. Compared by value: a surface builds its token.
  Object? _owner;

  /// Rebuilds the IR of the source the recording surface rendered, with the
  /// records the renderer itself read. The source is captured by value, so
  /// streaming growth cannot shift a selection that already happened.
  MdDocument Function()? _document;
  String? _selectedText;

  /// Records a selection made by [owner]'s surface.
  ///
  /// [selectedText] is the selection exactly as the framework reported it: the
  /// display-space mapping normalizes both sides itself, and stripping is the
  /// clipboard's business.
  void capture({
    required Object owner,
    required MdDocument Function() document,
    required String selectedText,
  }) {
    _owner = owner;
    _document = document;
    _selectedText = selectedText;
  }

  /// Forgets the recorded selection (the selection was cleared or emptied).
  void clear() {
    _owner = null;
    _document = null;
    _selectedText = null;
  }

  /// Forgets the recorded selection when [owner]'s surface recorded it.
  void clearIfOwner(Object owner) {
    if (_owner == owner) clear();
  }

  /// What the desktop hotkey copies for the recorded selection, or `null` when
  /// nothing is recorded.
  String? markdownForSelection() {
    final document = _document;
    final selectedText = _selectedText;
    if (document == null || selectedText == null) return null;
    return selectionMarkdownFrom(document, selectedText);
  }
}
