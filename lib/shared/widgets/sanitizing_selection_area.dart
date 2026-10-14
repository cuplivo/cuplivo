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
/// The copy-intent override captures Ctrl+C for the whole subtree, so do
/// not nest editable widgets ([TextField], [SelectableText],
/// [EditableText]) inside [child] — their copy shortcut would be
/// redirected to the sanitized selection copy.
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
    _lastSelectionText = selection?.plainText;
    widget.onSelectionChanged?.call(selection);
  }

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
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
