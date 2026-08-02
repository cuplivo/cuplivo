import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/markdown_with_highlight.dart';
import '../../../shared/widgets/snackbar.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import '../utils/message_visual_content.dart';

/// Full-screen reading view for a single (long) assistant message.
///
/// Renders the same visual content as the chat bubble (think-stripped, visual
/// regex transforms applied via the speaker/conversation assistant) with its
/// own absolute font size (14-24, step 2, persisted via
/// `reader_font_size_v1`), independent of the chat font scale.
class ReadingModePage extends StatefulWidget {
  const ReadingModePage({super.key, required this.message, this.assistantName});

  final ChatMessage message;

  /// Toolbar title; speaker name for group chats, owner name otherwise.
  final String? assistantName;

  static const int minFontSize = 14;
  static const int maxFontSize = 24;
  static const int fontSizeStep = 2;
  static const double defaultFontSize = 18;
  static const double maxContentWidth = 720;

  @override
  State<ReadingModePage> createState() => _ReadingModePageState();
}

class _ReadingModePageState extends State<ReadingModePage> {
  Assistant? _resolvedAssistant;
  String? _visualContent;
  bool _contentReady = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_contentReady) return;
    _contentReady = true;
    _resolvedAssistant = assistantForMessage(context, widget.message);
    _visualContent = messageVisualContent(
      widget.message,
      assistant: _resolvedAssistant,
    );
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: _visualContent ?? ''));
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    showAppSnackBar(
      context,
      message: l10n.chatMessageWidgetCopiedToClipboard,
      type: NotificationType.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsProvider>();
    final fontSize = settings.readerFontSize;

    // Scale the whole content area (including code blocks) like the chat list
    // does, multiplying the system text scale on top of the reader size.
    final baseMediaQuery = context.getInheritedWidgetOfExactType<MediaQuery>();
    final data = baseMediaQuery?.data ?? MediaQuery.of(context);
    final textScale = data.textScaler.scale(1);
    final effectiveScale =
        textScale * fontSize / ReadingModePage.defaultFontSize;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        leading: IosIconButton(
          icon: Lucide.ArrowLeft,
          color: cs.onSurface,
          size: 22,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          widget.assistantName ??
              _resolvedAssistant?.name ??
              l10n.readingModeAssistantFallback,
        ),
        actions: [
          Tooltip(
            message: l10n.readingModePageCopyAll,
            child: IosIconButton(
              icon: Lucide.Copy,
              color: cs.onSurface,
              size: 20,
              onTap: _copyAll,
            ),
          ),
          Tooltip(
            message: l10n.readingModeFontDecrease,
            child: IosIconButton(
              icon: Lucide.Minus,
              color: cs.onSurface,
              size: 20,
              enabled: fontSize > ReadingModePage.minFontSize,
              onTap: () => settings.setReaderFontSize(
                fontSize - ReadingModePage.fontSizeStep,
              ),
            ),
          ),
          SizedBox(
            width: 28,
            child: Center(
              child: Text(
                '$fontSize',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: AppFontWeights.medium,
                  color: cs.onSurface,
                ),
              ),
            ),
          ),
          Tooltip(
            message: l10n.readingModeFontIncrease,
            child: IosIconButton(
              icon: Lucide.Plus,
              color: cs.onSurface,
              size: 20,
              enabled: fontSize < ReadingModePage.maxFontSize,
              onTap: () => settings.setReaderFontSize(
                fontSize + ReadingModePage.fontSizeStep,
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: MediaQuery(
        data: data.copyWith(textScaler: TextScaler.linear(effectiveScale)),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: ReadingModePage.maxContentWidth,
              ),
              child: MarkdownWithCodeHighlight(
                text: _visualContent ?? '',
                baseStyle: TextStyle(
                  fontSize: ReadingModePage.defaultFontSize,
                  height: 1.75,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
