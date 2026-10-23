import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:super_clipboard/super_clipboard.dart' show ClipboardWriter;
import '../markdown/rich_clipboard.dart';
import 'snackbar.dart';
import 'selection_scroll_container.dart';

import 'package:markstream/markstream.dart'
    show MarkstreamSelectionController, MarkstreamSelectionScope;
import '../../features/chat/utils/selection_markdown_memory.dart';
import '../../l10n/app_localizations.dart';

/// App-owned selection actions shared by messages and Markdown previews.
class AppSelectionArea extends StatefulWidget {
  const AppSelectionArea({
    super.key,
    required this.child,
    this.clipboardWriter,
    this.messageId,
    this.onReplySelection,
  });

  final Widget child;
  final ClipboardWriter? clipboardWriter;

  /// The message this surface renders, when it renders one.
  ///
  /// Recorded with every selection so a reply can cite the message the
  /// selection came from, and so the hotkey knows what to reply to. Surfaces
  /// that render text outside a message (a preview, an export sheet) leave it
  /// `null` and record nothing.
  final String? messageId;

  /// Offers "Reply" beside the platform Copy, receiving the selection as
  /// markdown. Only a chat bubble passes one.
  final ValueChanged<String>? onReplySelection;

  @override
  State<AppSelectionArea> createState() => _AppSelectionAreaState();
}

class _AppSelectionAreaState extends State<AppSelectionArea> {
  static const _translation = MethodChannel('app.ios_translation');
  bool _translationAvailable = false;
  String _selectedText = '';
  final _ownedMarkdownSelection = MarkstreamSelectionController();
  late MarkstreamSelectionController _markdownSelection;

  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      unawaited(_loadTranslationAvailability());
    }
  }

  Future<void> _loadTranslationAvailability() async {
    try {
      final available =
          await _translation.invokeMethod<bool>('isAvailable') ?? false;
      if (mounted && available != _translationAvailable) {
        setState(() => _translationAvailable = available);
      }
    } on MissingPluginException {
      // Native translation is not available in this host.
    } on PlatformException {
      // Selection remains usable if the native availability query fails.
    }
  }

  Future<void> _presentTranslation(String text, Offset anchor) async {
    try {
      await _translation.invokeMethod<void>('present', {
        'text': text,
        'anchorX': anchor.dx,
        'anchorY': anchor.dy,
      });
    } on MissingPluginException {
      // The toolbar already closed; there is no native view to present.
    } on PlatformException {
      // A native presentation error must not break the message selection.
    }
  }

  Future<void> _copyRichText(SelectableRegionState region) async {
    final pending = copyRichMarkdownSelection(
      _markdownSelection,
      writer: widget.clipboardWriter,
    );
    region.hideToolbar();
    try {
      await pending;
    } catch (_) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: AppLocalizations.of(context)!.markdownCopySelectionFailed,
        type: NotificationType.error,
      );
    }
  }

  Widget _buildMenu(BuildContext context, SelectableRegionState region) {
    final text = _selectedText;
    final anchors = region.contextMenuAnchors;
    // Read the recording, not the live controller: by the time the menu is
    // built the framework may already have collapsed the selection.
    final replyMarkdown = widget.onReplySelection == null
        ? null
        : SelectionMarkdownMemory.instance.markdownIfOwner(this);
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: anchors,
      buttonItems: [
        ...region.contextMenuButtonItems,
        if (_markdownSelection.hasSelection)
          ContextMenuButtonItem(
            label: AppLocalizations.of(context)!.markdownCopyMarkdownAction,
            onPressed: () {
              final markdown = _markdownSelection.selectedMarkdown;
              region.hideToolbar();
              if (markdown.isNotEmpty) {
                unawaited(Clipboard.setData(ClipboardData(text: markdown)));
              }
            },
          ),
        if (replyMarkdown != null && replyMarkdown.trim().isNotEmpty)
          ContextMenuButtonItem(
            label: AppLocalizations.of(
              context,
            )!.chatMessageWidgetReplySelection,
            onPressed: () {
              region.hideToolbar();
              widget.onReplySelection!(replyMarkdown);
            },
          ),
        if (_markdownSelection.hasSelection)
          ContextMenuButtonItem(
            label: AppLocalizations.of(context)!.markdownCopyRichTextAction,
            onPressed: () => unawaited(_copyRichText(region)),
          ),
        if (_translationAvailable && text.trim().isNotEmpty)
          ContextMenuButtonItem(
            label: AppLocalizations.of(
              context,
            )!.chatMessageWidgetTranslateTooltip,
            onPressed: () {
              region.hideToolbar();
              unawaited(_presentTranslation(text, anchors.primaryAnchor));
            },
          ),
      ],
    );
  }

  /// Keeps the selection as plain text for the Translate item, and — on a
  /// surface that renders a message — records it, so "Reply" and the desktop
  /// hotkeys can still act on it after the framework drops the live selection.
  void _recordSelection() {
    final messageId = widget.messageId;
    if (messageId == null) return;
    final selections = _markdownSelection.selections;
    if (selections.isEmpty) {
      SelectionMarkdownMemory.instance.clearIfOwner(this);
      return;
    }
    SelectionMarkdownMemory.instance.capture(
      owner: this,
      messageId: messageId,
      content: [for (final selection in selections) selection.content],
    );
  }

  @override
  void dispose() {
    SelectionMarkdownMemory.instance.clearIfOwner(this);
    _ownedMarkdownSelection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _markdownSelection =
        MarkstreamSelectionScope.maybeOf(context) ?? _ownedMarkdownSelection;
    return MarkstreamSelectionScope(
      controller: _markdownSelection,
      child: SelectionArea(
        onSelectionChanged: (content) {
          _selectedText = content?.plainText ?? '';
          _recordSelection();
        },
        contextMenuBuilder: _buildMenu,
        child: SelectionScrollContainer(child: widget.child),
      ),
    );
  }
}
