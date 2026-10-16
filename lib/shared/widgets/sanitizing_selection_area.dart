import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/services.dart';

import 'package:gpt_markdown/gpt_markdown.dart'
    show stripRendererInsertedCharacters;

/// A [SelectionArea] that sanitizes text before it reaches the clipboard.
///
/// The markdown renderer inserts invisible characters into rendered text
/// (zero-width spaces to wrap long inline-code and table-cell tokens, etc.).
/// Copying a selection straight out of the rendered widgets would otherwise
/// leak them (cuplivo issue #738). This wrapper strips those characters on
/// both copy paths:
///
/// * Keyboard copy (Ctrl+C / Cmd+C / Ctrl+Insert): the framework registers
///   its [CopySelectionTextIntent] action as overridable, so an ancestor
///   [Actions] entry takes precedence.
/// * The default context-menu Copy / Share buttons: their `onPressed` is
///   patched to copy the sanitized text, mirroring the framework's
///   post-action behavior per platform.
///
/// A caller-supplied [contextMenuBuilder] is used as-is (it owns its own
/// copy actions — build its default items with
/// [SanitizingSelectionArea.patchedDefaultItems] so Copy/Share stay
/// sanitized).
///
/// The copy-intent override is registered only while this surface owns a
/// selection. The markdown renderer nests selectables inside it — a code
/// block's [SelectableText], a table cell, a nested [SelectionArea] for code
/// past 2048 chars — and those own their selections outright. Leaving the
/// intent to the framework while there is nothing of ours to sanitize is what
/// keeps Ctrl+C inside a code block copying its text instead of nothing.
class SanitizingSelectionArea extends StatefulWidget {
  const SanitizingSelectionArea({
    super.key,
    required this.child,
    this.onSelectionChanged,
    this.contextMenuBuilder,
  });

  /// The child the selection area applies to.
  final Widget child;

  /// Called when the selected content changes, with the raw (unsanitized)
  /// plain text of the current selection, or `null` when the selection is
  /// cleared.
  final ValueChanged<SelectedContent?>? onSelectionChanged;

  /// Builds the context menu. When omitted, the default adaptive toolbar is
  /// shown with its Copy / Share actions sanitized.
  final SelectableRegionContextMenuBuilder? contextMenuBuilder;

  /// The framework's default toolbar items with Copy / Share patched to use
  /// [sanitizedText] (mirroring the per-platform post-action behavior), and
  /// [insertedAfterCopy] spliced in right after the Copy button.
  ///
  /// Custom context-menu builders on markdown surfaces use this so the
  /// platform Copy stays sanitized while their own items join the toolbar.
  static List<ContextMenuButtonItem> patchedDefaultItems(
    SelectableRegionState state, {
    required String? sanitizedText,
    List<ContextMenuButtonItem> insertedAfterCopy = const [],
  }) {
    final text = sanitizedText ?? '';
    final items = state.contextMenuButtonItems.map((item) {
      switch (item.type) {
        case ContextMenuButtonType.copy:
          return item.copyWith(onPressed: () => _copyText(text, state));
        case ContextMenuButtonType.share:
          return item.copyWith(onPressed: () => _shareText(text, state));
        default:
          return item;
      }
    }).toList();
    if (insertedAfterCopy.isEmpty) return items;
    final copyIndex = items.indexWhere(
      (item) => item.type == ContextMenuButtonType.copy,
    );
    if (copyIndex < 0) return items;
    items.insertAll(copyIndex + 1, insertedAfterCopy);
    return items;
  }

  static Future<void> _copyText(
    String text,
    SelectableRegionState state,
  ) async {
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    _finishToolbarAction(state);
  }

  static Future<void> _shareText(
    String text,
    SelectableRegionState state,
  ) async {
    if (text.isEmpty) return;
    await SystemChannels.platform.invokeMethod<String>('Share.invoke', text);
    _finishToolbarAction(state);
  }

  /// Mirrors the framework's per-platform post-action behavior for the
  /// default toolbar Copy / Share buttons (see
  /// `SelectableRegionState.contextMenuButtonItems`). The accessibility
  /// selection-status update the framework performs alongside
  /// [SelectableRegionState.clearSelection] is not public and is skipped.
  static void _finishToolbarAction(SelectableRegionState state) {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
        state.clearSelection();
      case TargetPlatform.iOS:
        state.hideToolbar(false);
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        state.hideToolbar();
    }
  }

  @override
  State<SanitizingSelectionArea> createState() =>
      _SanitizingSelectionAreaState();
}

class _SanitizingSelectionAreaState extends State<SanitizingSelectionArea> {
  String? _lastSelectionText;

  String get _sanitizedSelection {
    final raw = _lastSelectionText;
    if (raw == null || raw.isEmpty) return '';
    return stripRendererInsertedCharacters(raw);
  }

  /// Writes the sanitized selection. The override that calls this is registered
  /// only while there is one, so this never runs on an empty selection.
  Future<void> _copyToClipboard() async {
    final text = _sanitizedSelection;
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
  }

  Widget _defaultContextMenu(
    BuildContext context,
    SelectableRegionState state,
  ) {
    return AdaptiveTextSelectionToolbar.buttonItems(
      buttonItems: SanitizingSelectionArea.patchedDefaultItems(
        state,
        sanitizedText: _sanitizedSelection,
      ),
      anchors: state.contextMenuAnchors,
    );
  }

  void _handleSelectionChanged(SelectedContent? selection) {
    final text = selection?.plainText;
    final hadSelection = _lastSelectionText?.isNotEmpty ?? false;
    final hasSelection = text?.isNotEmpty ?? false;
    _lastSelectionText = text;
    // The copy override's registration follows the emptiness, and `Actions`
    // reads its map from the current widget, so the flip needs a rebuild. It
    // happens once per selection, not once per drag frame.
    if (hadSelection != hasSelection) setState(() {});
    widget.onSelectionChanged?.call(selection);
  }

  @override
  Widget build(BuildContext context) {
    // Registered only while this surface owns a selection. The override covers
    // the whole subtree, and the renderer nests selectables inside it — a code
    // block's SelectableText, a table cell, a nested SelectionArea for code
    // past 2048 chars — whose selections never reach our own
    // [SelectionArea.onSelectionChanged]. With the entry always present, Ctrl+C
    // inside one of those reached this action with an empty cache and copied
    // nothing at all; leaving the intent to the framework while we have nothing
    // to sanitize is what keeps them working.
    return Actions(
      actions: <Type, Action<Intent>>{
        if (_sanitizedSelection.isNotEmpty)
          CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
            onInvoke: (intent) {
              unawaited(_copyToClipboard());
              return null;
            },
          ),
      },
      child: SelectionArea(
        onSelectionChanged: _handleSelectionChanged,
        contextMenuBuilder: widget.contextMenuBuilder ?? _defaultContextMenu,
        child: widget.child,
      ),
    );
  }
}
