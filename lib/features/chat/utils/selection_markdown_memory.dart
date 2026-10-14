import 'package:gpt_markdown/gpt_markdown.dart'
    show MdDocument, stripRendererInsertedCharacters;

/// The most recent assistant text selection, kept so the desktop
/// copy-selection-as-markdown hotkey can act on it without opening the
/// context menu (a workaround for the framework-level instability where a
/// right-click can clear a long backward selection).
///
/// Written by the assistant content selection area on every selection
/// change; read by the hotkey handler. Selections made in other markdown
/// surfaces (user message, translation, reasoning) do not record here —
/// the hotkey is only about restoring the markdown source.
class SelectionMarkdownMemory {
  SelectionMarkdownMemory._();

  /// The app-wide holder. A plain singleton: at most one text selection is
  /// active at a time.
  static final SelectionMarkdownMemory instance = SelectionMarkdownMemory._();

  MdDocument Function()? _document;
  String? _selectedText;

  /// Records a selection made inside an assistant message.
  ///
  /// [document] rebuilds the IR of the bubble's own rendered source — one walk
  /// per copy rather than one document kept per rendered widget — and the
  /// caller captures the source by value, so streaming growth cannot shift a
  /// selection that already happened. [selectedText] is the selection exactly
  /// as the framework reported it: the display-space mapping normalizes both
  /// sides itself, and stripping is the clipboard's business.
  void capture({
    required MdDocument Function() document,
    required String selectedText,
  }) {
    _document = document;
    _selectedText = selectedText;
  }

  /// Forgets the recorded selection (the selection was cleared or emptied).
  void clear() {
    _document = null;
    _selectedText = null;
  }

  /// What the `Markdown` menu item and the hotkey copy for the recorded
  /// selection: the markdown the IR re-emits for it, or — when the selection
  /// cannot be mapped, which is why a miss is never worse than a copy — the
  /// sanitized plain text. `null` when nothing is recorded.
  String? markdownForSelection() {
    final selected = _selectedText;
    if (selected == null || selected.trim().isEmpty) return null;
    return _document?.call().emitSelectionMarkdown(selected) ??
        stripRendererInsertedCharacters(selected);
  }
}
