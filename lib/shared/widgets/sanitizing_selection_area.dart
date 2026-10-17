import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/services.dart';

import 'package:gpt_markdown/gpt_markdown.dart'
    show stripRendererInsertedCharacters;

import 'selection_ownership.dart';

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
/// selection. A code body and a table cell are paragraphs of this owner, but the
/// markdown renderer still nests selectables where it cannot reach the text — a
/// diagram's code view, a code viewport past the line threshold — and those own
/// their selections outright. Two things follow, and both have to hold:
///
/// * The override covers the whole subtree and the framework's own copy
///   actions forward to it, so while it is registered it wins inside those
///   owners too. It therefore has to *retire* when one of them claims the
///   selection, which is what [NestedSelectionClaimedNotification] reports;
///   otherwise Ctrl+C inside a nested owner writes this area's stale text.
/// * With it retired, the framework copies what the focused owner owns —
///   un-sanitized, since that text is not readable from here. In the shapes this
///   line nests that text is code or diagram source, which carries no
///   renderer-inserted character to strip.
///
/// The report is the whole of the signal: the region's own `onSelectionChanged`
/// keeps reporting the selection it had, so a nested owner that stays silent
/// leaves this area copying its stale text. A caller that nests a selectable of
/// its own inside this widget owes [reportNestedSelectionClaimed] too.
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
    finishToolbarAction(state);
  }

  static Future<void> _shareText(
    String text,
    SelectableRegionState state,
  ) async {
    if (text.isEmpty) return;
    await SystemChannels.platform.invokeMethod<String>('Share.invoke', text);
    finishToolbarAction(state);
  }

  /// Mirrors the framework's per-platform post-action behavior for the
  /// default toolbar Copy / Share buttons (see
  /// `SelectableRegionState.contextMenuButtonItems`). The accessibility
  /// selection-status update the framework performs alongside
  /// [SelectableRegionState.clearSelection] is not public and is skipped.
  ///
  /// Public because a surface that adds its own copy-like item — the
  /// assistant bubble's `Markdown` item — should finish the same way the
  /// platform's Copy does: keep the selection on iOS and desktop, clear it on
  /// Android, rather than clearing it everywhere.
  static void finishToolbarAction(SelectableRegionState state) {
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

  /// A nested owner claimed the selection, so this area no longer has one: drop
  /// the cache (which retires the copy override) and tell the surface, so what
  /// it remembers is not a selection the user cannot see any more.
  void _handleNestedSelectionClaimed() {
    if ((_lastSelectionText ?? '').isEmpty) return;
    setState(() => _lastSelectionText = null);
    widget.onSelectionChanged?.call(null);
  }

  @override
  Widget build(BuildContext context) {
    // Registered only while this surface owns a selection. The override covers
    // the whole subtree, and the framework's own copy actions forward to it, so
    // a nested owner's selection would reach this action with our *stale* text
    // — a diagram's code view and a lazy code viewport each report their claim
    // ([NestedSelectionClaimedNotification]) and retire it.
    return NotificationListener<NestedSelectionClaimedNotification>(
      onNotification: (notification) {
        _handleNestedSelectionClaimed();
        // Keep bubbling: an area nested inside another area is still the one
        // that owns its subtree, and both may need to stand down.
        return false;
      },
      child: Actions(
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
      ),
    );
  }
}
