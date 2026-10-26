import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image_lib;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:pdf/pdf.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'pdf_export_dialog.dart';
import 'image_preview_sheet.dart';
import 'export_image_capture.dart';
import '../utils/export_image_processor.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/message_part.dart';
import '../../../core/models/conversation.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/model_spec/model_spec_resolver.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/models/assistant.dart';
import '../../../core/services/fonts/google_fonts_service.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../../../shared/markdown/kelivo_markdown_extensions.dart';
import '../../../shared/markdown/markdown_with_code_highlight.dart';
import 'package:Cuplivo/shared/widgets/app_selection_area.dart';
import '../../../shared/widgets/export_capture_scope.dart';
import '../../../shared/widgets/diagram_exporter.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../l10n/app_localizations.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/custom_theme.dart';
import '../../../theme/palettes.dart';
import '../../../theme/theme_factory.dart';
import '../../home/widgets/model_icon.dart';
import '../utils/citation_index.dart';
import '../utils/export_document.dart';
import '../../intelligent_ui/host/ui_export_capture.dart';
import '../../intelligent_ui/host/ui_presented_fences.dart';
import '../../intelligent_ui/host/ui_source_selection.dart';
import '../../intelligent_ui/text/ui_message_text.dart';
import '../utils/markdown_pdf_emitter.dart';
import '../utils/pdf_export_fonts.dart';
import '../utils/pdf_export_options.dart';
import '../utils/pdf_export_rasters.dart';
import '../utils/thinking_tag_parser.dart';
import '../utils/message_reasoning_source.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';
import '../../../core/models/context_operation.dart';
import 'chat_message_widget.dart'
    show ChatMessageWidget, ToolUIPart, ReasoningSegment;

// Shared helpers
String? _modelDisplayNameFromSettings(
  SettingsProvider settings,
  ChatMessage msg,
) {
  if (msg.role != 'assistant') return null;
  final modelId = msg.modelId;
  if (modelId == null || modelId.isEmpty) return null;
  final providerId = msg.providerId;
  if (providerId != null && providerId.isNotEmpty) {
    try {
      final cfg = settings.getProviderConfig(providerId);
      final resolved = ModelSpecResolver.instance.resolve(cfg, modelId);
      return resolved.override.displayName ?? resolved.spec.upstreamId;
    } catch (_) {
      // ignore lookup issues; fall back to the logical model id.
    }
  }
  return modelId;
}

String _getRoleNameFromDependencies({
  required AppLocalizations l10n,
  required SettingsProvider settings,
  required UserProvider userProvider,
  required Assistant? assistant,
  required ChatMessage msg,
}) {
  if (msg.role == 'user') {
    return userProvider.name;
  }
  if (msg.role == 'assistant') {
    if (assistant != null &&
        assistant.useAssistantName == true &&
        assistant.name.trim().isNotEmpty) {
      return assistant.name.trim();
    }
    final modelName = _modelDisplayNameFromSettings(settings, msg);
    if (modelName != null && modelName.isNotEmpty) {
      return modelName;
    }
    return l10n.messageExportSheetAssistant;
  }
  return msg.role;
}

/// Build export payload from structured [MessagePart]s.
///
/// Text comes from [textOverride] (e.g. thinking-stripped assistant body) or
/// [ChatMessage.content] (TextPart join). Attachments are taken from ImagePart /
/// FilePart only — never reconstructed as legacy marker strings.
_Parsed _exportPartsFromMessage(ChatMessage message, {String? textOverride}) {
  final images = <String>[];
  final docs = <_DocRef>[];
  for (final part in message.parts) {
    if (part is ImagePart) {
      final uri = part.uri.trim();
      if (uri.isNotEmpty) images.add(uri);
    } else if (part is FilePart) {
      docs.add(
        _DocRef(
          path: part.uri,
          fileName: part.name,
          mime: part.mime ?? 'application/octet-stream',
        ),
      );
    }
  }
  final text = (textOverride ?? message.content).trim();
  return _Parsed(text, images, docs);
}

/// The blocks [message] exports, laid out the way the plain-text export lays
/// them out, with a picture named rather than embedded.
@visibleForTesting
Future<String> exportMessageBlocksForTesting(
  ChatMessage message, {
  required bool showThinkingAndToolCards,
  UiMessageText? uiText,
  bool markdown = false,
}) async {
  final blocks = await exportBlocksOf(
    message,
    includeThinking: showThinkingAndToolCards,
    includeTools: showThinkingAndToolCards,
    uiText: uiText,
    markdown: markdown,
  );
  return renderExportBlocks(
    blocks,
    markdown: markdown,
    thinkingLabel: 'Thinking',
    imageLine: (image) => '![image](${image.uri})',
  );
}

String _softBreakMd(String input) {
  // Insert zero-width break in very long tokens outside fenced code blocks.
  final lines = input.split('\n');
  final out = StringBuffer();
  bool inFence = false;
  for (final line in lines) {
    String l = line;
    final trimmed = l.trimLeft();
    if (trimmed.startsWith('```')) {
      inFence = !inFence; // toggle on fence lines
      out.writeln(l);
      continue;
    }
    if (!inFence) {
      l = l.replaceAllMapped(RegExp(r'(\S{60,})'), (m) {
        final s = m.group(1)!;
        final buf = StringBuffer();
        for (int i = 0; i < s.length; i++) {
          buf.write(s[i]);
          if ((i + 1) % 20 == 0) buf.write('\u200B');
        }
        return buf.toString();
      });
    }
    out.writeln(l);
  }
  return out.toString();
}

/// Prepare a message for image export.
///
/// Inline `<think>` spans are sliced out of each [TextPart] so the widget
/// body does not repeat text that [exportReasoningPayload] already renders
/// as a thinking card. [ReasoningPart] / [ToolCallPart] stay when the
/// toggle is on and are dropped when it is off.
@visibleForTesting
ChatMessage messageForThinkingExport(
  ChatMessage message, {
  required bool showThinkingAndToolCards,
}) {
  if (message.role != 'assistant' || uiDisplayFences(message).isNotEmpty) {
    return message;
  }
  final hasReasoningPart = message.parts.any((part) => part is ReasoningPart);
  final kept = [
    for (final part in message.parts)
      if (showThinkingAndToolCards ||
          (part is! ReasoningPart && part is! ToolCallPart))
        part,
  ];
  if (hasReasoningPart) {
    return showThinkingAndToolCards ? message : message.copyWith(parts: kept);
  }
  final joined = message.content;
  final ranges = ThinkingTagParser.parseWithRanges(joined);
  if (ranges.hiddenRanges.isEmpty) {
    return showThinkingAndToolCards ? message : message.copyWith(parts: kept);
  }
  return message.copyWith(
    parts: _partsWithVisibleThinkSlices(
      kept,
      joined,
      ranges,
      insertReasoningParts: showThinkingAndToolCards,
    ),
  );
}

List<MessagePart> _partsWithVisibleThinkSlices(
  List<MessagePart> parts,
  String joined,
  ThinkingTagParseRanges ranges, {
  required bool insertReasoningParts,
}) {
  final next = <MessagePart>[];
  ThinkingTagParser.walkSlices(
    parts,
    joined,
    ranges,
    onVisible: (text, _, _) => next.add(TextPart(text)),
    onThinking: (_, text) {
      if (insertReasoningParts && text.isNotEmpty) {
        next.add(ReasoningPart(text));
      }
    },
    onOther: next.add,
  );
  return next;
}

class _ExportReasoningPayload {
  const _ExportReasoningPayload({
    required this.segments,
    this.fromInlineThinking = false,
    this.contentSplitOffsets,
    this.reasoningCountAtSplit,
    this.toolCountAtSplit,
  });

  final List<ReasoningSegment> segments;
  final bool fromInlineThinking;
  final List<int>? contentSplitOffsets;
  final List<int>? reasoningCountAtSplit;
  final List<int>? toolCountAtSplit;
}

List<ToolUIPart> _exportToolPartsForMessage(
  BuildContext context,
  ChatMessage message,
) {
  if (uiDisplayFences(message).isNotEmpty) {
    return [
      for (final tool in uiMessageTimeline(message).tools)
        ToolUIPart(
          id: tool.providerId,
          toolName: tool.toolName,
          arguments: tool.arguments,
          content: tool.content,
          metadata: tool.metadata,
          loading: tool.loading,
        ),
    ];
  }
  try {
    final chatService = context.read<ChatService>();
    final events = chatService.getToolEventsForMessage(message);
    if (events.isEmpty) return const <ToolUIPart>[];
    return events
        .map(
          (e) => ToolUIPart(
            id: (e['id'] ?? '').toString(),
            toolName: (e['name'] ?? '').toString(),
            arguments:
                (e['arguments'] as Map?)?.cast<String, dynamic>() ??
                const <String, dynamic>{},
            content: (e['content']?.toString().isNotEmpty == true)
                ? e['content'].toString()
                : null,
            metadata: e['metadata'] is Map
                ? Map<String, dynamic>.from(e['metadata'] as Map)
                : null,
            loading: !(e['content']?.toString().isNotEmpty == true),
          ),
        )
        .toList();
  } catch (_) {
    return const <ToolUIPart>[];
  }
}

_ExportReasoningPayload _exportReasoningPayloadForMessage(
  ChatMessage message, {
  required bool expandThinkingContent,
}) {
  if (uiDisplayFences(message).isNotEmpty) {
    final timeline = uiMessageTimeline(message);
    return _ExportReasoningPayload(
      segments: [
        for (final segment in timeline.segments)
          ReasoningSegment(
            text: segment.text,
            expanded: expandThinkingContent,
            loading: false,
            startAt: segment.startAt,
            finishedAt: segment.finishedAt,
            toolStartIndex: segment.toolStartIndex,
          ),
      ],
      fromInlineThinking: timeline.inlineThinking,
      contentSplitOffsets: timeline.splits?.offsets,
      reasoningCountAtSplit: timeline.splits?.reasoningCounts,
      toolCountAtSplit: timeline.splits?.toolCounts,
    );
  }
  final segJson = (message.reasoningSegmentsJson ?? '').trim();
  var segments = <ReasoningSegment>[];
  var fromInlineThinking = false;
  List<int>? offsets;
  List<int>? reasoningCounts;
  List<int>? toolCounts;

  if (segJson.isNotEmpty && messageHasProviderReasoning(message)) {
    try {
      final decoded = jsonDecode(segJson);
      if (decoded is Map<String, dynamic>) {
        final rawSegments = (decoded['segments'] as List? ?? const <dynamic>[]);
        final parsedSplits = tryParseContentSplits(decoded['contentSplits']);
        if (parsedSplits != null) {
          offsets = parsedSplits.offsets;
          reasoningCounts = parsedSplits.reasoningCounts;
          toolCounts = parsedSplits.toolCounts;
        }
        for (final item in rawSegments) {
          if (item is! Map) continue;
          final map = item.cast<String, dynamic>();
          final text = (map['text']?.toString() ?? '').trim();
          if (text.isEmpty) continue;
          segments.add(
            ReasoningSegment(
              text: text,
              expanded: expandThinkingContent,
              loading: false,
              startAt: DateTime.tryParse(map['startAt']?.toString() ?? ''),
              finishedAt: DateTime.tryParse(
                map['finishedAt']?.toString() ?? '',
              ),
              toolStartIndex: (map['toolStartIndex'] as int?) ?? 0,
            ),
          );
        }
      } else if (decoded is List) {
        for (final item in decoded) {
          if (item is! Map) continue;
          final map = item.cast<String, dynamic>();
          final text = (map['text']?.toString() ?? '').trim();
          if (text.isEmpty) continue;
          segments.add(
            ReasoningSegment(
              text: text,
              expanded: expandThinkingContent,
              loading: false,
              startAt: DateTime.tryParse(map['startAt']?.toString() ?? ''),
              finishedAt: DateTime.tryParse(
                map['finishedAt']?.toString() ?? '',
              ),
              toolStartIndex: (map['toolStartIndex'] as int?) ?? 0,
            ),
          );
        }
      }
    } catch (_) {}
  }

  if (segments.isEmpty) {
    final thinkingData = thinkingExportDataForMessage(message);
    fromInlineThinking = thinkingData.fromInlineThinking;
    if (thinkingData.thinkingTexts.isNotEmpty) {
      segments.addAll(
        thinkingData.thinkingTexts.map(
          (text) => ReasoningSegment(
            text: text,
            expanded: expandThinkingContent,
            loading: false,
            toolStartIndex: 0,
          ),
        ),
      );
    }
  }

  // Non-UI image preparation still converts inline spans to ordered
  // ReasoningParts. Its timing overlays must match those split fragments.
  // Native UI and Web cards retain original parts and provider source authority.
  final hasStructuredReasoning = message.parts.any(
    (part) => part is ReasoningPart,
  );
  if (fromInlineThinking ||
      (!hasStructuredReasoning && uiDisplayFences(message).isEmpty)) {
    segments = _expandSegmentsByLegacyThinkFragments(
      message,
      segments,
      expandThinkingContent: expandThinkingContent,
    );
  } else if (hasStructuredReasoning) {
    segments = _alignStructuredReasoningSegments(
      message,
      segments,
      expandThinkingContent: expandThinkingContent,
    );
  }

  return _ExportReasoningPayload(
    segments: segments,
    fromInlineThinking: fromInlineThinking,
    contentSplitOffsets: offsets,
    reasoningCountAtSplit: reasoningCounts,
    toolCountAtSplit: toolCounts,
  );
}

List<ReasoningSegment> _alignStructuredReasoningSegments(
  ChatMessage message,
  List<ReasoningSegment> source, {
  required bool expandThinkingContent,
}) {
  final texts = [
    for (final part in message.parts)
      if (part is ReasoningPart && part.text.isNotEmpty) part.text,
  ];
  if (texts.isEmpty) return source;
  return [
    for (var i = 0; i < texts.length; i++)
      ReasoningSegment(
        text: texts[i],
        expanded: i < source.length
            ? source[i].expanded
            : expandThinkingContent,
        loading: false,
        startAt: i < source.length ? source[i].startAt : null,
        finishedAt: i < source.length ? source[i].finishedAt : null,
        toolStartIndex: i < source.length ? source[i].toolStartIndex : 0,
      ),
  ];
}

List<ReasoningSegment> _expandSegmentsByLegacyThinkFragments(
  ChatMessage message,
  List<ReasoningSegment> source, {
  required bool expandThinkingContent,
}) {
  final ranges = ThinkingTagParser.parseWithRanges(message.content);
  if (ranges.hiddenRanges.isEmpty) return source;

  final fragments = <(int, String)>[];
  ThinkingTagParser.walkSlices(
    message.parts,
    message.content,
    ranges,
    onVisible: (_, _, _) {},
    onThinking: (rangeIndex, text) {
      if (text.isNotEmpty) fragments.add((rangeIndex, text));
    },
    onOther: (_) {},
  );
  if (fragments.isEmpty) return source;

  final byRange = <int, ReasoningSegment>{};
  var sourceIndex = 0;
  for (var i = 0; i < ranges.hiddenRanges.length; i++) {
    final range = ranges.hiddenRanges[i];
    if (range.bodyEnd <= range.bodyStart) continue;
    if (sourceIndex < source.length) {
      byRange[i] = source[sourceIndex++];
    }
  }

  return [
    for (final fragment in fragments)
      _reasoningSegmentFromSource(
        byRange[fragment.$1],
        text: fragment.$2,
        expandThinkingContent: expandThinkingContent,
      ),
  ];
}

ReasoningSegment _reasoningSegmentFromSource(
  ReasoningSegment? source, {
  required String text,
  required bool expandThinkingContent,
}) {
  return ReasoningSegment(
    text: text,
    expanded: source?.expanded ?? expandThinkingContent,
    loading: false,
    startAt: source?.startAt,
    finishedAt: source?.finishedAt,
    toolStartIndex: source?.toolStartIndex ?? 0,
  );
}

@visibleForTesting
List<({bool expanded, DateTime? startAt, DateTime? finishedAt})>
exportReasoningMetadataForTesting(
  ChatMessage message, {
  required bool expandThinkingContent,
}) {
  return [
    for (final segment in _exportReasoningPayloadForMessage(
      message,
      expandThinkingContent: expandThinkingContent,
    ).segments)
      (
        expanded: segment.expanded,
        startAt: segment.startAt,
        finishedAt: segment.finishedAt,
      ),
  ];
}

@visibleForTesting
({List<int>? offsets, List<int>? reasoningCounts, List<int>? toolCounts})
exportContentSplitsForTesting(
  ChatMessage message, {
  bool expandThinkingContent = true,
}) {
  final payload = _exportReasoningPayloadForMessage(
    message,
    expandThinkingContent: expandThinkingContent,
  );
  return (
    offsets: payload.contentSplitOffsets,
    reasoningCounts: payload.reasoningCountAtSplit,
    toolCounts: payload.toolCountAtSplit,
  );
}

@visibleForTesting
List<bool> exportReasoningExpandedFlagsForTesting(
  ChatMessage message, {
  required bool expandThinkingContent,
}) {
  return [
    for (final item in exportReasoningMetadataForTesting(
      message,
      expandThinkingContent: expandThinkingContent,
    ))
      item.expanded,
  ];
}

Future<void> saveExportTextWithPicker(
  BuildContext context, {
  required String filename,
  required String content,
  required List<String> allowedExtensions,
}) async {
  final l10n = AppLocalizations.of(context)!;

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    final String? savePath = await FilePicker.platform.saveFile(
      dialogTitle: l10n.backupPageExportToFile,
      fileName: filename,
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
    );
    if (savePath == null) return; // user cancelled

    try {
      await File(savePath).parent.create(recursive: true);
      await File(savePath).writeAsString(content);
    } catch (e) {
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        message: l10n.messageExportSheetExportFailed('$e'),
        type: NotificationType.error,
      );
      return;
    }

    if (!context.mounted) return;
    showAppSnackBar(
      context,
      message: l10n.messageExportSheetExportedAs(p.basename(savePath)),
      type: NotificationType.success,
    );
    return;
  }

  // Mobile: use FilePicker with bytes parameter (required on Android & iOS).
  final contentBytes = utf8.encode(content);
  final String? savePath = await FilePicker.platform.saveFile(
    dialogTitle: l10n.backupPageExportToFile,
    fileName: filename,
    type: FileType.custom,
    allowedExtensions: allowedExtensions,
    bytes: Uint8List.fromList(contentBytes),
  );
  if (savePath == null) return;
  if (!context.mounted) return;
  showAppSnackBar(
    context,
    message: l10n.messageExportSheetExportedAs(p.basename(savePath)),
    type: NotificationType.success,
  );
}

/// Writes [bytes] where the user says, answering whether they were written.
///
/// [announce] false leaves the confirmation to the caller, because an export that
/// opens a result dialog of its own would otherwise report itself twice.
Future<bool> _saveExportBytesWithPicker(
  BuildContext context, {
  required String filename,
  required Uint8List bytes,
  required List<String> allowedExtensions,
  bool announce = true,
}) async {
  final l10n = AppLocalizations.of(context)!;

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    final String? savePath = await FilePicker.platform.saveFile(
      dialogTitle: l10n.backupPageExportToFile,
      fileName: filename,
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
    );
    if (savePath == null) return false; // user cancelled

    try {
      await File(savePath).parent.create(recursive: true);
      await File(savePath).writeAsBytes(bytes, flush: true);
    } catch (e) {
      if (!context.mounted) return false;
      showAppSnackBar(
        context,
        message: l10n.messageExportSheetExportFailed('$e'),
        type: NotificationType.error,
      );
      return false;
    }

    if (!context.mounted || !announce) return true;
    showAppSnackBar(
      context,
      message: l10n.messageExportSheetExportedAs(p.basename(savePath)),
      type: NotificationType.success,
    );
    return true;
  }

  // Mobile: hand the bytes to the picker, which writes them itself.
  final String? savePath = await FilePicker.platform.saveFile(
    dialogTitle: l10n.backupPageExportToFile,
    fileName: filename,
    type: FileType.custom,
    allowedExtensions: allowedExtensions,
    bytes: bytes,
  );
  if (savePath == null) return false;
  if (!context.mounted || !announce) return true;
  showAppSnackBar(
    context,
    message: l10n.messageExportSheetExportedAs(p.basename(savePath)),
    type: NotificationType.success,
  );
  return true;
}

Future<void> exportChatMessagesMarkdown(
  BuildContext context, {
  required Conversation conversation,
  required List<ChatMessage> messages,
  UiExportCapture? uiCaptures,
  bool showThinkingAndToolCards = false,
  bool expandThinkingContent = false,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final settings = context.read<SettingsProvider>();
  final userProvider = context.read<UserProvider>();
  final assistant = context.read<AssistantProvider>().currentAssistant;
  final thinkingLabel = l10n.messageExportThinkingContentLabel;
  final timeFormatter = DateFormat(
    l10n.messageExportSheetDateTimeWithSecondsPattern,
  );
  try {
    showAppSnackBar(
      context,
      message: l10n.messageExportSheetExporting,
      type: NotificationType.info,
    );

    final title = (conversation.title.trim().isNotEmpty)
        ? conversation.title
        : l10n.messageExportSheetDefaultTitle;
    // Resolve the service before the first await: the operations belong to the
    // conversation, not the widget tree, and reading them later would take the
    // context across an async gap.
    final chat = context.read<ChatService>();
    final captures =
        uiCaptures ?? await captureUiExportMessages(context, messages);
    final operations = await chat.loadContextOperations(conversation.id);
    final document = await buildExportDocument(
      title: title,
      messages: captures.messages,
      uiTextByMessage: captures.projections,
      markdown: true,
      operations: operations,
      contextLabelOf: (op, {required hidden}) => _exportContextNodeText(
        op,
        l10n,
        hidden: hidden,
        operations: operations,
      ),
      roleNameOf: (msg) => _getRoleNameFromDependencies(
        l10n: l10n,
        settings: settings,
        userProvider: userProvider,
        assistant: assistant,
        msg: msg,
      ),
      formatTime: timeFormatter.format,
      includeThinking: showThinkingAndToolCards && expandThinkingContent,
      includeTools: showThinkingAndToolCards,
      readImageBytes: readExportImageBytes,
    );

    final filename = 'chat-export-${DateTime.now().millisecondsSinceEpoch}.md';
    if (!context.mounted) return;
    await saveExportTextWithPicker(
      context,
      filename: filename,
      content: renderExportDocument(
        document,
        markdown: true,
        thinkingLabel: thinkingLabel,
        imageLine: exportImageMarkdownLine,
      ),
      allowedExtensions: const ['md'],
    );
  } catch (e) {
    if (!context.mounted) return;
    showAppSnackBar(
      context,
      message: l10n.messageExportSheetExportFailed('$e'),
      type: NotificationType.error,
    );
  }
}

/// The light scheme the exported page is drawn for.
///
/// A PDF is a light page whatever theme the app is in, and a dark theme's
/// primary is a pale tint that would vanish into the paper — so when the app is
/// dark the light scheme is derived the way `main.dart` derives the app's two
/// themes (minus the dynamic scheme a phone contributes, which this has no way
/// to reach).
ColorScheme _pdfPageScheme(BuildContext context, SettingsProvider settings) {
  final current = Theme.of(context).colorScheme;
  if (current.brightness == Brightness.light) return current;
  final custom = settings.selectedCustomTheme;
  final palette =
      settings.themePaletteId == ThemePalettes.customPaletteId && custom != null
      ? buildCustomThemePalette(custom)
      : ThemePalettes.byId(settings.themePaletteId);
  return buildLightThemeForScheme(
    palette.light,
    pureBackground: settings.usePureBackground,
    layeredSurfaces: settings.useLayeredSurfaces,
  ).colorScheme;
}

/// The ink that scheme contributes to the page, guarded for paper.
///
/// A colour too pale to read on white, which a custom theme may choose, becomes
/// the page's own default: an unreadable link is worse than a differently
/// coloured one.
({PdfColor accent, PdfColor muted}) _pdfPageInk(ColorScheme light) => (
  accent: _readableOnPaper(light.primary, kPdfPageAccent),
  muted: _readableOnPaper(light.onSurfaceVariant, kPdfPageMuted),
);

/// [colour] as an opaque page ink when it can be read on white, else [fallback].
PdfColor _readableOnPaper(Color colour, PdfColor fallback) =>
    colour.computeLuminance() > 0.6
    ? fallback
    : PdfColor.fromInt(colour.toARGB32() | 0xFF000000);

/// The icon face a speaker's avatar disc is drawn with, read once per run.
///
/// The app draws its icons from a font it ships rather than from bitmaps, which is
/// exactly what a page needs: the disc beside a message's name can carry the same
/// glyph the screen puts in it, at vector quality, without capturing anything. The
/// read is remembered because the file is most of a megabyte and an export is not
/// the only thing that will ask for it.
Uint8List? _iconFontBytes;
bool _iconFontRead = false;

Future<Uint8List?> _pdfIconFont() async {
  if (_iconFontRead) return _iconFontBytes;
  _iconFontRead = true;
  try {
    final data = await rootBundle.load(kLucideFontAsset);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    // The writer opens single-face `glyf` fonts; anything else would embed a face
    // with no glyphs rather than fail, so the check is what keeps a disc empty
    // instead of drawing a box where the icon should be.
    if (isPdfEmbeddableFont(bytes)) _iconFontBytes = bytes;
  } catch (_) {
    // A build without the icon asset simply draws the disc and nothing in it.
  }
  return _iconFontBytes;
}

/// Where the icon face lives in the bundle, as the icons package registers it.
const String kLucideFontAsset =
    'packages/lucide_icons_flutter/assets/lucide.ttf';

/// Writes a PDF of [messages] where the user asks for it.
///
/// The layout runs off the UI isolate — a hundred-message conversation is not a
/// frame's worth of work — so only plain data crosses: the fonts and the picture
/// bytes are resolved here, where the settings, the filesystem and the widget tree
/// are. The whole export runs behind the progress overlay, and the answer is what
/// the layout produced: null when the user closed the save dialog, which is a
/// cancellation rather than a failure.
Future<PdfExportResult?> exportChatMessagesPdf(
  BuildContext context, {
  required Conversation conversation,
  required List<ChatMessage> messages,
  UiExportCapture? uiCaptures,
  PdfExportOptions? options,
  GoogleFontsService? googleFonts,
  PdfFontResolver? resolver,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final settings = context.read<SettingsProvider>();
  final userProvider = context.read<UserProvider>();
  final assistant = context.read<AssistantProvider>().currentAssistant;
  final thinkingLabel = l10n.messageExportThinkingContentLabel;
  final timeFormatter = DateFormat(
    l10n.messageExportSheetDateTimeWithSecondsPattern,
  );
  final choice = options ?? pdfExportSessionOptions;
  final pageScheme = _pdfPageScheme(context, settings);
  final pageInk = _pdfPageInk(pageScheme);
  PdfExportResult? result;
  try {
    await _runWithExportingOverlay(context, (progress) async {
      final title = (conversation.title.trim().isNotEmpty)
          ? conversation.title
          : l10n.messageExportSheetDefaultTitle;

      final chat = context.read<ChatService>();
      final captures =
          uiCaptures ?? await captureUiExportMessages(context, messages);
      final operations = await chat.loadContextOperations(conversation.id);
      final document = await buildExportDocument(
        title: title,
        messages: captures.messages,
        uiTextByMessage: captures.projections,
        markdown: true,
        operations: operations,
        contextLabelOf: (op, {required hidden}) => _exportContextNodeText(
          op,
          l10n,
          hidden: hidden,
          operations: operations,
        ),
        roleNameOf: (msg) => _getRoleNameFromDependencies(
          l10n: l10n,
          settings: settings,
          userProvider: userProvider,
          assistant: assistant,
          msg: msg,
        ),
        formatTime: timeFormatter.format,
        citationIndexOf: (msg) => citationIndexLookupOf(
          searchCitationItemsOf(
            _exportToolPartsForMessage(
              context,
              msg,
            ).map((part) => (name: part.toolName, content: part.content)),
          ),
        ),
        includeThinking:
            choice.showThinkingAndToolCards && choice.expandThinkingContent,
        includeTools: choice.showThinkingAndToolCards,
        readImageBytes: readExportImageBytes,
      );
      final fonts =
          await (resolver ?? PdfFontResolver(googleFonts: googleFonts)).resolve(
            body: choice.body,
            mono: choice.mono,
            emoji: choice.emoji,
            appFontPath: settings.appFontLocalPath,
            codeFontPath: settings.codeFontLocalPath,
          );
      final iconFont = await _pdfIconFont();

      // Formulas and diagrams are drawn here, where a widget tree exists, and the
      // layout then runs off-thread with the bitmaps in hand. A drawing that does
      // not come back is not a failure: the layout falls back to the formula's TeX
      // and the diagram's code, and reports both.
      if (!context.mounted) return;
      final rasters = await rasterizePdfExportKeys(context, <PdfRasterKey>[
        for (final message in document.messages)
          for (final block in message.blocks)
            if (block is ExportText)
              ...pdfRasterKeysIn(
                block.text,
                enableMathRendering: settings.enableMathRendering,
                enableDollarLatex: settings.enableDollarLatex,
              )
            else if (block is ExportReasoning)
              ...pdfRasterKeysIn(
                block.text,
                enableMathRendering: settings.enableMathRendering,
                enableDollarLatex: settings.enableDollarLatex,
              ),
      ], pagePalette: pageScheme);

      final layout = await compute(
        buildConversationPdf,
        PdfExportRequest(
          title: document.title,
          subtitle: timeFormatter.format(DateTime.now()),
          messages: document.messages,
          thinkingLabel: thinkingLabel,
          accent: pageInk.accent,
          muted: pageInk.muted,
          userLabel: l10n.messageExportSheetUser,
          alertLabels: markdownAlertLabels(l10n),
          bodyFont: fonts.body,
          monoFont: fonts.mono,
          emojiFont: fonts.emoji,
          iconFont: iconFont,
          assistantIcon: Lucide.Bot.codePoint,
          rasters: rasters,
          enableMathRendering: settings.enableMathRendering,
          enableDollarLatex: settings.enableDollarLatex,
        ),
      );

      final filename =
          'chat-export-${DateTime.now().millisecondsSinceEpoch}.pdf';
      if (!context.mounted) return;
      progress.value = const ExportImageProgress(ExportImageStage.saving);
      final saved = await _saveExportBytesWithPicker(
        context,
        filename: filename,
        bytes: layout.bytes,
        allowedExtensions: const ['pdf'],
        announce: false,
      );
      if (saved) result = layout;
    });
  } catch (e) {
    if (!context.mounted) return null;
    showAppSnackBar(
      context,
      message: l10n.messageExportSheetExportFailed('$e'),
      type: NotificationType.error,
    );
    return null;
  }
  return result;
}

Future<void> exportChatMessagesTxt(
  BuildContext context, {
  required Conversation conversation,
  required List<ChatMessage> messages,
  UiExportCapture? uiCaptures,
  bool showThinkingAndToolCards = false,
  bool expandThinkingContent = false,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final settings = context.read<SettingsProvider>();
  final userProvider = context.read<UserProvider>();
  final assistant = context.read<AssistantProvider>().currentAssistant;
  final thinkingLabel = l10n.messageExportThinkingContentLabel;
  final timeFormatter = DateFormat(
    l10n.messageExportSheetDateTimeWithSecondsPattern,
  );
  try {
    showAppSnackBar(
      context,
      message: l10n.messageExportSheetExporting,
      type: NotificationType.info,
    );

    final title = (conversation.title.trim().isNotEmpty)
        ? conversation.title
        : l10n.messageExportSheetDefaultTitle;
    // Resolve the service before the first await: the operations belong to the
    // conversation, not the widget tree, and reading them later would take the
    // context across an async gap.
    final chat = context.read<ChatService>();
    final captures =
        uiCaptures ?? await captureUiExportMessages(context, messages);
    final operations = await chat.loadContextOperations(conversation.id);
    final document = await buildExportDocument(
      title: title,
      messages: captures.messages,
      uiTextByMessage: captures.projections,
      markdown: false,
      operations: operations,
      contextLabelOf: (op, {required hidden}) => _exportContextNodeText(
        op,
        l10n,
        hidden: hidden,
        operations: operations,
      ),
      roleNameOf: (msg) => _getRoleNameFromDependencies(
        l10n: l10n,
        settings: settings,
        userProvider: userProvider,
        assistant: assistant,
        msg: msg,
      ),
      formatTime: timeFormatter.format,
      includeThinking: showThinkingAndToolCards && expandThinkingContent,
      includeTools: showThinkingAndToolCards,
    );

    final filename = 'chat-export-${DateTime.now().millisecondsSinceEpoch}.txt';
    if (!context.mounted) return;
    await saveExportTextWithPicker(
      context,
      filename: filename,
      content: renderExportDocument(
        document,
        markdown: false,
        thinkingLabel: thinkingLabel,
        imageLine: (image) => image.uri,
      ),
      allowedExtensions: const ['txt'],
    );
  } catch (e) {
    if (!context.mounted) return;
    showAppSnackBar(
      context,
      message: l10n.messageExportSheetExportFailed('$e'),
      type: NotificationType.error,
    );
  }
}

Future<void> exportChatMessagesImage(
  BuildContext context, {
  required Conversation conversation,
  required List<ChatMessage> messages,
  bool showThinkingAndToolCards = false,
  bool expandThinkingContent = false,
}) async {
  try {
    _ExportedImageResult? file;
    await _runWithExportingOverlay(context, (progress) async {
      file = await _renderAndSaveChatImage(
        context,
        conversation,
        messages,
        progress: progress,
        showThinkingAndToolCards: showThinkingAndToolCards,
        expandThinkingContent: expandThinkingContent,
      );
    });
    if (file == null) throw 'render error';
    if (!context.mounted) return;
    await showImagePreviewSheet(
      context,
      file: file!.file,
      preparedPreview: file!.preview,
    );
  } catch (e) {
    if (!context.mounted) return;
    final l10n = AppLocalizations.of(context)!;
    showAppSnackBar(
      context,
      message: l10n.messageExportSheetExportFailed('$e'),
      type: NotificationType.error,
    );
  }
}

Future<_ExportedImageResult?> _renderAndSaveMessageImage(
  BuildContext context,
  ChatMessage message, {
  required ValueNotifier<ExportImageProgress> progress,
  bool showThinkingAndToolCards = false,
  bool expandThinkingContent = false,
}) async {
  final theme = Theme.of(context);
  final cs = theme.colorScheme;
  final settings = context.read<SettingsProvider>();
  final l10n = AppLocalizations.of(context)!;
  final chatService = context.read<ChatService>();
  final title =
      chatService.getConversation(message.conversationId)?.title ??
      l10n.messageExportSheetDefaultTitle;
  // Pre-render Mermaid and SVG diagrams to images for export
  try {
    final codes = extractDiagramCodes(message.content);
    await preRenderDiagramCodesForExport(
      context,
      codes,
      onProgress: (completed, total) {
        progress.value = ExportImageProgress(
          ExportImageStage.diagrams,
          completed: completed,
          total: total,
        );
      },
    );
  } catch (_) {}

  final bool isDesktop =
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  final exportConfig = _exportImageRenderConfig(isDesktop: isDesktop);

  Widget buildContent() => ExportCaptureScope(
    enabled: true,
    child: _ExportedMessageCard(
      message: message,
      title: title,
      cs: cs,
      chatFontScale: settings.chatFontScale,
      showThinkingAndToolCards: showThinkingAndToolCards,
      expandThinkingContent: expandThinkingContent,
      isDesktop: isDesktop,
    ),
  );
  if (!context.mounted) return null;
  return _renderWidgetDirectly(
    context,
    buildContent,
    theme: theme,
    progress: progress,
    width: exportConfig.width,
    pixelRatio: exportConfig.pixelRatio,
  );
}

Future<_ExportedImageResult?> _renderAndSaveChatImage(
  BuildContext context,
  Conversation conversation,
  List<ChatMessage> messages, {
  required ValueNotifier<ExportImageProgress> progress,
  bool showThinkingAndToolCards = false,
  bool expandThinkingContent = false,
}) async {
  final theme = Theme.of(context);
  final cs = theme.colorScheme;
  final settings = context.read<SettingsProvider>();
  final l10n = AppLocalizations.of(context)!;
  // Pre-render all Mermaid and SVG diagrams found in selected messages
  try {
    final codes = messages
        .map((m) => extractDiagramCodes(m.content))
        .expand((e) => e)
        .toList();
    await preRenderDiagramCodesForExport(
      context,
      codes,
      onProgress: (completed, total) {
        progress.value = ExportImageProgress(
          ExportImageStage.diagrams,
          completed: completed,
          total: total,
        );
      },
    );
  } catch (_) {}

  final bool isDesktop =
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  final exportConfig = _exportImageRenderConfig(isDesktop: isDesktop);

  Widget buildContent() => ExportCaptureScope(
    enabled: true,
    child: _ExportedChatImage(
      conversationTitle: (conversation.title.trim().isNotEmpty)
          ? conversation.title
          : l10n.messageExportSheetDefaultTitle,
      cs: cs,
      chatFontScale: settings.chatFontScale,
      messages: messages,
      timestamp: conversation.updatedAt,
      showThinkingAndToolCards: showThinkingAndToolCards,
      expandThinkingContent: expandThinkingContent,
      isDesktop: isDesktop,
    ),
  );
  if (!context.mounted) return null;
  return _renderWidgetDirectly(
    context,
    buildContent,
    theme: theme,
    progress: progress,
    width: exportConfig.width,
    pixelRatio: exportConfig.pixelRatio,
  );
}

const double _desktopExportLogicalWidth = 720.0;
const double _mobileExportLogicalWidth = 480.0;
const double _exportImagePixelRatio = 3.0;

({double width, double pixelRatio}) _exportImageRenderConfig({
  required bool isDesktop,
}) {
  return (
    width: isDesktop ? _desktopExportLogicalWidth : _mobileExportLogicalWidth,
    pixelRatio: _exportImagePixelRatio,
  );
}

@visibleForTesting
({double width, double pixelRatio}) exportImageRenderConfigForTesting({
  required bool isDesktop,
}) {
  return _exportImageRenderConfig(isDesktop: isDesktop);
}

class _ExportedImageResult {
  const _ExportedImageResult(this.file, this.preview);
  final File file;
  final ExportImagePreview? preview;
}

Future<_ExportedImageResult> _renderWidgetDirectly(
  BuildContext context,
  Widget Function() buildContent, {
  required ThemeData theme,
  required ValueNotifier<ExportImageProgress> progress,
  double width = 480,
  double pixelRatio = 3,
}) async {
  final result = await captureExportWidget(
    context,
    buildContent(),
    theme: theme,
    width: width,
    pixelRatio: pixelRatio,
    onProgress: (value) => progress.value = value,
  );
  progress.value = const ExportImageProgress(ExportImageStage.saving);
  final dir = await getTemporaryDirectory();
  final file = File(
    '${dir.path}/chat-export-${DateTime.now().microsecondsSinceEpoch}.png',
  );
  await file.writeAsBytes(result.pngBytes);
  return _ExportedImageResult(file, result.preview);
}

@visibleForTesting
Widget buildExportCaptureRootForTesting({
  required ThemeData theme,
  required Widget child,
  double width = 480,
}) {
  return _ExportCaptureRoot(
    theme: theme,
    boundaryKey: GlobalKey(),
    width: width,
    child: child,
  );
}

@visibleForTesting
Widget buildExportCaptureViewportRootForTesting({
  required ThemeData theme,
  required Widget child,
  required double viewportHeight,
  required double contentHeight,
  double width = 480,
  double offsetY = 0,
}) {
  return _ExportCaptureViewportRoot(
    theme: theme,
    boundaryKey: GlobalKey(),
    width: width,
    viewportHeight: viewportHeight,
    contentHeight: contentHeight,
    offsetY: offsetY,
    child: child,
  );
}

class _ExportCaptureRoot extends StatelessWidget {
  const _ExportCaptureRoot({
    required this.theme,
    required this.boundaryKey,
    required this.width,
    required this.child,
  });

  final ThemeData theme;
  final GlobalKey boundaryKey;
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: theme,
      child: RepaintBoundary(
        key: boundaryKey,
        child: Container(
          width: width,
          color: theme.colorScheme.surface,
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}

class _ExportCaptureViewportRoot extends StatelessWidget {
  const _ExportCaptureViewportRoot({
    required this.theme,
    required this.boundaryKey,
    required this.width,
    required this.viewportHeight,
    required this.contentHeight,
    required this.offsetY,
    required this.child,
  });

  final ThemeData theme;
  final GlobalKey boundaryKey;
  final double width;
  final double viewportHeight;
  final double contentHeight;
  final double offsetY;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: theme,
      child: RepaintBoundary(
        key: boundaryKey,
        child: Container(
          width: width,
          height: viewportHeight,
          color: theme.colorScheme.surface,
          child: Material(
            type: MaterialType.transparency,
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.topCenter,
                minWidth: width,
                maxWidth: width,
                minHeight: contentHeight,
                maxHeight: contentHeight,
                child: Transform.translate(
                  offset: Offset(0, -offsetY),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

@visibleForTesting
Future<Uint8List?> captureExportBoundaryPngBytesForTesting(
  RenderRepaintBoundary boundary, {
  required double pixelRatio,
}) async {
  final ratio = exportFullCaptureRatio(boundary.size, pixelRatio);
  if (ratio == null) return null;
  final png = await captureExportBoundary(boundary, ratio);
  if (png == null) return null;
  return (await compute(
    processExportImage,
    ExportImageProcessingRequest(singlePngBytes: png),
  )).pngBytes;
}

@visibleForTesting
bool shouldUseFullExportCaptureForTesting({
  required Size logicalSize,
  required double pixelRatio,
}) => exportFullCaptureRatio(logicalSize, pixelRatio) != null;

@visibleForTesting
double? exportFullCapturePixelRatioForTesting({
  required Size logicalSize,
  required double requestedPixelRatio,
}) => exportFullCaptureRatio(logicalSize, requestedPixelRatio);

@visibleForTesting
double exportCaptureSliceLogicalHeightForTesting({
  required double pixelRatio,
}) => exportSliceLogicalHeight(pixelRatio);

@visibleForTesting
Uint8List stitchExportPngSlicesForTesting({
  required int outputWidth,
  required int outputHeight,
  required List<({Uint8List bytes, int y})> slices,
}) => image_lib.encodePng(stitchExportImage(outputWidth, outputHeight, slices));

@visibleForTesting
Uint8List trimExportPngBlankPaddingForTesting(
  Uint8List bytes, {
  required int preservePadding,
}) => processExportImage(
  ExportImageProcessingRequest(
    singlePngBytes: bytes,
    preservePadding: preservePadding,
  ),
).pngBytes;

@visibleForTesting
Future<Uint8List> processCapturedExportPngForTesting({
  Uint8List? singlePngBytes,
  int? outputWidth,
  int? outputHeight,
  List<({Uint8List bytes, int y})>? slices,
  required int preservePadding,
}) async => (await compute(
  processExportImage,
  ExportImageProcessingRequest(
    singlePngBytes: singlePngBytes,
    outputWidth: outputWidth ?? 0,
    outputHeight: outputHeight ?? 0,
    slices: slices ?? const [],
    preservePadding: preservePadding,
  ),
)).pngBytes;

Future<void> showMessageExportSheet(
  BuildContext context,
  ChatMessage message,
) async {
  try {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      // Desktop: show centered dialog
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => Dialog(
          elevation: 12,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: _ExportDialog(message: message, parentContext: context),
        ),
      );
      return;
    }
  } catch (_) {
    // Fallback to bottom sheet below
  }
  // Mobile: keep bottom sheet
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.overlaySurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return SafeArea(
        top: false,
        child: _ExportSheet(message: message, parentContext: context),
      );
    },
  );
}

Future<void> showChatExportSheet(
  BuildContext context, {
  required Conversation conversation,
  required List<ChatMessage> selectedMessages,
}) async {
  try {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      // Desktop: show centered dialog
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => Dialog(
          elevation: 12,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: _BatchExportDialog(
            conversation: conversation,
            messages: selectedMessages,
            parentContext: context,
          ),
        ),
      );
      return;
    }
  } catch (_) {
    // Fallback to bottom sheet below
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.overlaySurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return SafeArea(
        top: false,
        child: _BatchExportSheet(
          conversation: conversation,
          messages: selectedMessages,
          parentContext: context,
        ),
      );
    },
  );
}

// Desktop dialog: single message export
class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.message, required this.parentContext});
  final ChatMessage message;
  final BuildContext parentContext;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  final bool _exporting = false;
  bool _showThinkingAndToolCards = false;
  bool _expandThinkingContent = false;

  Future<void> _onExportMarkdown() async {
    if (_exporting) return;
    try {
      final pctx = widget.parentContext;
      final msg = widget.message;
      final service = pctx.read<ChatService>();
      final convo = service.getConversation(msg.conversationId);
      final effectiveConvo =
          convo ?? Conversation(id: msg.conversationId, title: '');
      await Navigator.of(context).maybePop();
      if (!pctx.mounted) return;
      await exportChatMessagesMarkdown(
        pctx,
        conversation: effectiveConvo,
        messages: [msg],
        showThinkingAndToolCards: _showThinkingAndToolCards,
        expandThinkingContent: _expandThinkingContent,
      );
    } catch (e) {
      final pctx = widget.parentContext;
      if (!pctx.mounted) return;
      final l10n = AppLocalizations.of(pctx)!;
      showAppSnackBar(
        pctx,
        message: l10n.messageExportSheetExportFailed('$e'),
        type: NotificationType.error,
      );
    }
  }

  Future<void> _onExportTxt() async {
    if (_exporting) return;
    try {
      final pctx = widget.parentContext;
      final msg = widget.message;
      final service = pctx.read<ChatService>();
      final convo = service.getConversation(msg.conversationId);
      final effectiveConvo =
          convo ?? Conversation(id: msg.conversationId, title: '');
      await Navigator.of(context).maybePop();
      if (!pctx.mounted) return;
      await exportChatMessagesTxt(
        pctx,
        conversation: effectiveConvo,
        messages: [msg],
        showThinkingAndToolCards: _showThinkingAndToolCards,
        expandThinkingContent: _expandThinkingContent,
      );
    } catch (e) {
      final pctx = widget.parentContext;
      if (!pctx.mounted) return;
      final l10n = AppLocalizations.of(pctx)!;
      showAppSnackBar(
        pctx,
        message: l10n.messageExportSheetExportFailed('$e'),
        type: NotificationType.error,
      );
    }
  }

  Future<void> _onExportImage() async {
    if (_exporting) return;
    try {
      final pctx = widget.parentContext;
      await Navigator.of(context).maybePop();
      if (!pctx.mounted) return;
      _ExportedImageResult? file;
      await _runWithExportingOverlay(pctx, (progress) async {
        file = await _renderAndSaveMessageImage(
          pctx,
          widget.message,
          progress: progress,
          showThinkingAndToolCards: _showThinkingAndToolCards,
          expandThinkingContent: _expandThinkingContent,
        );
      });
      if (file == null) throw 'render error';
      if (!pctx.mounted) return;
      await showImagePreviewSheet(
        pctx,
        file: file!.file,
        preparedPreview: file!.preview,
      );
      return;
    } catch (e) {
      final pctx = widget.parentContext;
      if (!pctx.mounted) return;
      final l10n = AppLocalizations.of(pctx)!;
      showAppSnackBar(
        pctx,
        message: l10n.messageExportSheetExportFailed('$e'),
        type: NotificationType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: 420,
        maxWidth: 640,
        maxHeight: 640,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          color: context.appColors.surfaceCard,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.messageExportSheetFormatTitle,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: AppFontWeights.emphasis,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.mcpPageClose,
                      icon: Icon(
                        Lucide.X,
                        size: 18,
                        color: cs.onSurface.withValues(alpha: 0.75),
                      ),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              // Body
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Scrollbar(
                    child: ListView(
                      children: [
                        _ExportOptionTile(
                          icon: Lucide.BookOpenText,
                          title: l10n.messageExportSheetMarkdown,
                          subtitle:
                              l10n.messageExportSheetSingleMarkdownSubtitle,
                          onTap: _exporting ? null : _onExportMarkdown,
                        ),
                        _ExportOptionTile(
                          icon: Lucide.FileText,
                          title: l10n.messageExportSheetPlainText,
                          subtitle: l10n.messageExportSheetSingleTxtSubtitle,
                          onTap: _exporting ? null : _onExportTxt,
                        ),
                        _ExportOptionTile(
                          icon: Lucide.Image,
                          title: l10n.messageExportSheetExportImage,
                          subtitle:
                              l10n.messageExportSheetSingleExportImageSubtitle,
                          onTap: _exporting ? null : _onExportImage,
                        ),
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Column(
                            children: [
                              _buildSwitchRow(
                                context,
                                title: l10n
                                    .messageExportSheetShowThinkingAndToolCards,
                                value: _showThinkingAndToolCards,
                                onChanged: (v) {
                                  setState(() {
                                    _showThinkingAndToolCards = v;
                                    if (!v) _expandThinkingContent = false;
                                  });
                                },
                              ),
                              _buildSwitchRow(
                                context,
                                title:
                                    l10n.messageExportSheetShowThinkingContent,
                                value: _expandThinkingContent,
                                onChanged: _showThinkingAndToolCards
                                    ? (v) => setState(
                                        () => _expandThinkingContent = v,
                                      )
                                    : null,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSwitchRow(
    BuildContext context, {
    required String title,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isEnabled = onChanged != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 14,
                color: isEnabled
                    ? cs.onSurface
                    : cs.onSurface.withValues(alpha: 0.4),
              ),
            ),
          ),
          IosSwitch(
            value: value,
            onChanged: onChanged,
            activeColor: cs.primary,
          ),
        ],
      ),
    );
  }
}

// Desktop dialog: batch export
class _BatchExportDialog extends StatefulWidget {
  const _BatchExportDialog({
    required this.conversation,
    required this.messages,
    required this.parentContext,
  });
  final Conversation conversation;
  final List<ChatMessage> messages;
  final BuildContext parentContext;

  @override
  State<_BatchExportDialog> createState() => _BatchExportDialogState();
}

class _BatchExportDialogState extends State<_BatchExportDialog> {
  final bool _exporting = false;
  bool _showThinkingAndToolCards = false;
  bool _expandThinkingContent = false;

  Future<void> _onExportMarkdown() async {
    if (_exporting) return;
    final pctx = widget.parentContext;
    await Navigator.of(context).maybePop();
    if (!pctx.mounted) return;
    await exportChatMessagesMarkdown(
      pctx,
      conversation: widget.conversation,
      messages: widget.messages,
      showThinkingAndToolCards: _showThinkingAndToolCards,
      expandThinkingContent: _expandThinkingContent,
    );
  }

  Future<void> _onExportTxt() async {
    if (_exporting) return;
    final pctx = widget.parentContext;
    await Navigator.of(context).maybePop();
    if (!pctx.mounted) return;
    await exportChatMessagesTxt(
      pctx,
      conversation: widget.conversation,
      messages: widget.messages,
      showThinkingAndToolCards: _showThinkingAndToolCards,
      expandThinkingContent: _expandThinkingContent,
    );
  }

  Future<void> _onExportPdf() async {
    if (_exporting) return;
    final pctx = widget.parentContext;
    final settings = pctx.read<SettingsProvider>();
    await Navigator.of(context).maybePop();
    if (!pctx.mounted) return;
    await showPdfExportDialog(
      pctx,
      conversation: widget.conversation,
      messages: widget.messages,
      showThinkingAndToolCards: _showThinkingAndToolCards,
      expandThinkingContent: _expandThinkingContent,
      appFontPath: settings.appFontLocalPath,
      codeFontPath: settings.codeFontLocalPath,
      appFontFamily: settings.appFontFamily,
      codeFontFamily: settings.codeFontFamily,
    );
  }

  Future<void> _onExportImage() async {
    if (_exporting) return;
    try {
      final pctx = widget.parentContext;
      await Navigator.of(context).maybePop();
      if (!pctx.mounted) return;
      _ExportedImageResult? file;
      await _runWithExportingOverlay(pctx, (progress) async {
        file = await _renderAndSaveChatImage(
          pctx,
          widget.conversation,
          widget.messages,
          progress: progress,
          showThinkingAndToolCards: _showThinkingAndToolCards,
          expandThinkingContent: _expandThinkingContent,
        );
      });
      if (file == null) throw 'render error';
      if (!pctx.mounted) return;
      await showImagePreviewSheet(
        pctx,
        file: file!.file,
        preparedPreview: file!.preview,
      );
      return;
    } catch (e) {
      final pctx = widget.parentContext;
      if (!pctx.mounted) return;
      final l10n = AppLocalizations.of(pctx)!;
      showAppSnackBar(
        pctx,
        message: l10n.messageExportSheetExportFailed('$e'),
        type: NotificationType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: 480,
        maxWidth: 720,
        maxHeight: 460,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          color: context.appColors.surfaceCard,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.messageExportSheetFormatTitle,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: AppFontWeights.emphasis,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.mcpPageClose,
                      icon: Icon(
                        Lucide.X,
                        size: 18,
                        color: cs.onSurface.withValues(alpha: 0.75),
                      ),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              // Body
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Scrollbar(
                    child: ListView(
                      children: [
                        _ExportOptionTile(
                          icon: Lucide.BookOpenText,
                          title: l10n.messageExportSheetMarkdown,
                          subtitle:
                              l10n.messageExportSheetBatchMarkdownSubtitle,
                          onTap: _exporting ? null : _onExportMarkdown,
                        ),
                        _ExportOptionTile(
                          icon: Lucide.FileText,
                          title: l10n.messageExportSheetPlainText,
                          subtitle: l10n.messageExportSheetBatchTxtSubtitle,
                          onTap: _exporting ? null : _onExportTxt,
                        ),
                        _ExportOptionTile(
                          icon: Lucide.FileType,
                          title: l10n.messageExportSheetPdf,
                          subtitle: l10n.messageExportSheetBatchPdfSubtitle,
                          onTap: _exporting ? null : _onExportPdf,
                        ),
                        _ExportOptionTile(
                          icon: Lucide.Image,
                          title: l10n.messageExportSheetExportImage,
                          subtitle:
                              l10n.messageExportSheetBatchExportImageSubtitle,
                          onTap: _exporting ? null : _onExportImage,
                        ),
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Column(
                            children: [
                              _buildSwitchRow(
                                context,
                                title: l10n
                                    .messageExportSheetShowThinkingAndToolCards,
                                value: _showThinkingAndToolCards,
                                onChanged: (v) {
                                  setState(() {
                                    _showThinkingAndToolCards = v;
                                    if (!v) _expandThinkingContent = false;
                                  });
                                },
                              ),
                              _buildSwitchRow(
                                context,
                                title:
                                    l10n.messageExportSheetShowThinkingContent,
                                value: _expandThinkingContent,
                                onChanged: _showThinkingAndToolCards
                                    ? (v) => setState(
                                        () => _expandThinkingContent = v,
                                      )
                                    : null,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSwitchRow(
    BuildContext context, {
    required String title,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isEnabled = onChanged != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 14,
                color: isEnabled
                    ? cs.onSurface
                    : cs.onSurface.withValues(alpha: 0.4),
              ),
            ),
          ),
          IosSwitch(
            value: value,
            onChanged: onChanged,
            activeColor: cs.primary,
          ),
        ],
      ),
    );
  }
}

class _ExportSheet extends StatefulWidget {
  const _ExportSheet({required this.message, required this.parentContext});
  final ChatMessage message;
  final BuildContext parentContext;

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _BatchExportSheet extends StatefulWidget {
  const _BatchExportSheet({
    required this.conversation,
    required this.messages,
    required this.parentContext,
  });
  final Conversation conversation;
  final List<ChatMessage> messages;
  final BuildContext parentContext;

  @override
  State<_BatchExportSheet> createState() => _BatchExportSheetState();
}

class _BatchExportSheetState extends State<_BatchExportSheet> {
  final DraggableScrollableController _ctrl = DraggableScrollableController();
  bool _exporting = false;
  bool _showThinkingAndToolCards = false;
  bool _expandThinkingContent = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _onExportMarkdown() async {
    if (_exporting) return;

    // Dismiss dialog immediately
    if (mounted) Navigator.of(context).maybePop();

    await exportChatMessagesMarkdown(
      widget.parentContext,
      conversation: widget.conversation,
      messages: widget.messages,
      showThinkingAndToolCards: _showThinkingAndToolCards,
      expandThinkingContent: _expandThinkingContent,
    );
  }

  Future<void> _onExportTxt() async {
    if (_exporting) return;

    // Dismiss dialog immediately
    if (mounted) Navigator.of(context).maybePop();

    await exportChatMessagesTxt(
      widget.parentContext,
      conversation: widget.conversation,
      messages: widget.messages,
      showThinkingAndToolCards: _showThinkingAndToolCards,
      expandThinkingContent: _expandThinkingContent,
    );
  }

  Future<void> _onExportPdf() async {
    if (_exporting) return;

    // Dismiss the sheet immediately: the configuration is its own surface, and
    // the overlay that follows it must not be stacked behind this one.
    final pctx = widget.parentContext;
    final settings = pctx.read<SettingsProvider>();
    if (mounted) Navigator.of(context).maybePop();
    if (!pctx.mounted) return;

    await showPdfExportDialog(
      pctx,
      conversation: widget.conversation,
      messages: widget.messages,
      showThinkingAndToolCards: _showThinkingAndToolCards,
      expandThinkingContent: _expandThinkingContent,
      appFontPath: settings.appFontLocalPath,
      codeFontPath: settings.codeFontLocalPath,
      appFontFamily: settings.appFontFamily,
      codeFontFamily: settings.codeFontFamily,
    );
  }

  Future<void> _onExportImage() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final pctx = widget.parentContext;
      _ExportedImageResult? file;
      await _runWithExportingOverlay(pctx, (progress) async {
        file = await _renderAndSaveChatImage(
          pctx,
          widget.conversation,
          widget.messages,
          progress: progress,
          showThinkingAndToolCards: _showThinkingAndToolCards,
          expandThinkingContent: _expandThinkingContent,
        );
      });
      if (file == null) throw 'render error';
      // After generation, close current sheet then open preview
      if (mounted) await Navigator.of(context).maybePop();
      if (!pctx.mounted) return;
      await showImagePreviewSheet(
        pctx,
        file: file!.file,
        preparedPreview: file!.preview,
      );
      return; // do not fall through to setState after pop
    } catch (e) {
      final pctx = widget.parentContext;
      if (!pctx.mounted) return;
      final l10n = AppLocalizations.of(pctx)!;
      showAppSnackBar(
        pctx,
        message: l10n.messageExportSheetExportFailed('$e'),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return DraggableScrollableSheet(
      controller: _ctrl,
      expand: false,
      initialChildSize: 0.55,
      maxChildSize: 0.70,
      minChildSize: 0.3,
      builder: (c, sc) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(
                l10n.messageExportSheetFormatTitle,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: AppFontWeights.semibold,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ListView(
                controller: sc,
                children: [
                  _ExportOptionTile(
                    icon: Lucide.BookOpenText,
                    title: l10n.messageExportSheetMarkdown,
                    subtitle: l10n.messageExportSheetBatchMarkdownSubtitle,
                    onTap: _exporting
                        ? null
                        : () {
                            _onExportMarkdown();
                          },
                  ),
                  _ExportOptionTile(
                    icon: Lucide.FileText,
                    title: l10n.messageExportSheetPlainText,
                    subtitle: l10n.messageExportSheetBatchTxtSubtitle,
                    onTap: _exporting
                        ? null
                        : () {
                            _onExportTxt();
                          },
                  ),
                  _ExportOptionTile(
                    icon: Lucide.FileType,
                    title: l10n.messageExportSheetPdf,
                    subtitle: l10n.messageExportSheetBatchPdfSubtitle,
                    onTap: _exporting
                        ? null
                        : () {
                            _onExportPdf();
                          },
                  ),
                  _ExportOptionTile(
                    icon: Lucide.Image,
                    title: l10n.messageExportSheetExportImage,
                    subtitle: l10n.messageExportSheetBatchExportImageSubtitle,
                    onTap: _exporting
                        ? null
                        : () {
                            _onExportImage();
                          },
                  ),
                  const SizedBox(height: 8),
                  // Image export options
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Column(
                      children: [
                        _buildSwitchRow(
                          context,
                          title:
                              l10n.messageExportSheetShowThinkingAndToolCards,
                          value: _showThinkingAndToolCards,
                          onChanged: (v) {
                            setState(() {
                              _showThinkingAndToolCards = v;
                              if (!v) {
                                _expandThinkingContent = false;
                              }
                            });
                          },
                        ),
                        _buildSwitchRow(
                          context,
                          title: l10n.messageExportSheetShowThinkingContent,
                          value: _expandThinkingContent,
                          onChanged: _showThinkingAndToolCards
                              ? (v) {
                                  setState(() {
                                    _expandThinkingContent = v;
                                  });
                                }
                              : null,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSwitchRow(
    BuildContext context, {
    required String title,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isEnabled = onChanged != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 14,
                color: isEnabled
                    ? cs.onSurface
                    : cs.onSurface.withValues(alpha: 0.4),
              ),
            ),
          ),
          IosSwitch(
            value: value,
            onChanged: onChanged,
            activeColor: cs.primary,
          ),
        ],
      ),
    );
  }
}

class _ExportSheetState extends State<_ExportSheet> {
  final DraggableScrollableController _ctrl = DraggableScrollableController();
  bool _exporting = false;
  bool _showThinkingAndToolCards = false;
  bool _expandThinkingContent = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _onExportMarkdown() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final pctx = widget.parentContext;
      final msg = widget.message;
      final service = pctx.read<ChatService>();
      final convo = service.getConversation(msg.conversationId);
      final effectiveConvo =
          convo ?? Conversation(id: msg.conversationId, title: '');
      await exportChatMessagesMarkdown(
        pctx,
        conversation: effectiveConvo,
        messages: [msg],
        showThinkingAndToolCards: _showThinkingAndToolCards,
        expandThinkingContent: _expandThinkingContent,
      );
    } catch (e) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        showAppSnackBar(
          context,
          message: l10n.messageExportSheetExportFailed('$e'),
          type: NotificationType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _onExportTxt() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final pctx = widget.parentContext;
      final msg = widget.message;
      final service = pctx.read<ChatService>();
      final convo = service.getConversation(msg.conversationId);
      final effectiveConvo =
          convo ?? Conversation(id: msg.conversationId, title: '');
      await exportChatMessagesTxt(
        pctx,
        conversation: effectiveConvo,
        messages: [msg],
        showThinkingAndToolCards: _showThinkingAndToolCards,
        expandThinkingContent: _expandThinkingContent,
      );
    } catch (e) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        showAppSnackBar(
          context,
          message: l10n.messageExportSheetExportFailed('$e'),
          type: NotificationType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _onExportImage() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final pctx = widget.parentContext;
      _ExportedImageResult? file;
      await _runWithExportingOverlay(pctx, (progress) async {
        file = await _renderAndSaveMessageImage(
          pctx,
          widget.message,
          progress: progress,
          showThinkingAndToolCards: _showThinkingAndToolCards,
          expandThinkingContent: _expandThinkingContent,
        );
      });
      if (file == null) throw 'render error';
      if (mounted) await Navigator.of(context).maybePop();
      if (!pctx.mounted) return;
      await showImagePreviewSheet(
        pctx,
        file: file!.file,
        preparedPreview: file!.preview,
      );
      return;
    } catch (e) {
      final pctx = widget.parentContext;
      if (!pctx.mounted) return;
      final l10n = AppLocalizations.of(pctx)!;
      showAppSnackBar(
        pctx,
        message: l10n.messageExportSheetExportFailed('$e'),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return DraggableScrollableSheet(
      controller: _ctrl,
      expand: false,
      initialChildSize: 0.55,
      maxChildSize: 0.70,
      minChildSize: 0.3,
      builder: (c, sc) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(
                l10n.messageExportSheetFormatTitle,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: AppFontWeights.semibold,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ListView(
                controller: sc,
                children: [
                  _ExportOptionTile(
                    icon: Lucide.BookOpenText,
                    title: l10n.messageExportSheetMarkdown,
                    subtitle: l10n.messageExportSheetSingleMarkdownSubtitle,
                    onTap: _exporting
                        ? null
                        : () {
                            _onExportMarkdown();
                          },
                  ),
                  _ExportOptionTile(
                    icon: Lucide.FileText,
                    title: l10n.messageExportSheetPlainText,
                    subtitle: l10n.messageExportSheetSingleTxtSubtitle,
                    onTap: _exporting
                        ? null
                        : () {
                            _onExportTxt();
                          },
                  ),
                  _ExportOptionTile(
                    icon: Lucide.Image,
                    title: l10n.messageExportSheetExportImage,
                    subtitle: l10n.messageExportSheetSingleExportImageSubtitle,
                    onTap: _exporting
                        ? null
                        : () {
                            _onExportImage();
                          },
                  ),
                  const SizedBox(height: 8),
                  // Image export options
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Column(
                      children: [
                        _buildSwitchRow(
                          context,
                          title:
                              l10n.messageExportSheetShowThinkingAndToolCards,
                          value: _showThinkingAndToolCards,
                          onChanged: (v) {
                            setState(() {
                              _showThinkingAndToolCards = v;
                              if (!v) {
                                _expandThinkingContent = false;
                              }
                            });
                          },
                        ),
                        _buildSwitchRow(
                          context,
                          title: l10n.messageExportSheetShowThinkingContent,
                          value: _expandThinkingContent,
                          onChanged: _showThinkingAndToolCards
                              ? (v) {
                                  setState(() {
                                    _expandThinkingContent = v;
                                  });
                                }
                              : null,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSwitchRow(
    BuildContext context, {
    required String title,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isEnabled = onChanged != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 14,
                color: isEnabled
                    ? cs.onSurface
                    : cs.onSurface.withValues(alpha: 0.4),
              ),
            ),
          ),
          IosSwitch(
            value: value,
            onChanged: onChanged,
            activeColor: cs.primary,
          ),
        ],
      ),
    );
  }

  // shared widgets and helpers moved to top-level
}

@visibleForTesting
Widget buildExportedMessageCardForTesting(
  ChatMessage message, {
  bool showThinkingAndToolCards = false,
  bool expandThinkingContent = false,
  bool conversationBubble = false,
}) => Builder(
  builder: (context) => conversationBubble
      ? _ExportedBubble(
          message: message,
          cs: Theme.of(context).colorScheme,
          showThinkingAndToolCards: showThinkingAndToolCards,
          expandThinkingContent: expandThinkingContent,
        )
      : _ExportedMessageCard(
          message: message,
          title: 'Export',
          cs: Theme.of(context).colorScheme,
          chatFontScale: 1,
          showThinkingAndToolCards: showThinkingAndToolCards,
          expandThinkingContent: expandThinkingContent,
        ),
);

class _ExportedMessageCard extends StatelessWidget {
  const _ExportedMessageCard({
    required this.message,
    required this.title,
    required this.cs,
    required this.chatFontScale,
    this.showThinkingAndToolCards = false,
    this.expandThinkingContent = false,
    this.isDesktop = false,
  });
  final ChatMessage message;
  final String title;
  final ColorScheme cs;
  final double chatFontScale;
  final bool showThinkingAndToolCards;
  final bool expandThinkingContent;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    final isAssistant = message.role == 'assistant';
    final headerFg = cs.onSurface;
    final time = DateFormat('yyyy-MM-dd HH:mm').format(message.timestamp);

    // Desktop uses smaller font sizes for better proportions
    final double titleFontSize = isDesktop ? 15.0 : 18.0;
    final double timeFontSize = isDesktop ? 10.0 : 12.0;
    // Desktop uses smaller margins and paddings
    final double containerMargin = isDesktop ? 12.0 : 16.0;
    final double containerPadding = isDesktop ? 12.0 : 16.0;

    final messageForExport = messageForThinkingExport(
      message,
      showThinkingAndToolCards: showThinkingAndToolCards,
    );
    final preserveTimeline =
        isAssistant &&
        (showThinkingAndToolCards || uiDisplayFences(message).isNotEmpty);
    final exportReasoningPayload = preserveTimeline
        ? _exportReasoningPayloadForMessage(
            message,
            expandThinkingContent: expandThinkingContent,
          )
        : const _ExportReasoningPayload(segments: <ReasoningSegment>[]);
    final toolParts = preserveTimeline
        ? _exportToolPartsForMessage(context, message)
        : const <ToolUIPart>[];
    final assistant = context.read<AssistantProvider>().currentAssistant;
    final useAssistAvatar =
        isAssistant && (assistant?.useAssistantAvatar == true);
    final useAssistName = isAssistant && (assistant?.useAssistantName == true);

    return MediaQuery(
      // Respect chat font scale for export rendering
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(
          MediaQuery.textScalerOf(context).scale(1) * chatFontScale,
        ),
      ),
      child: Container(
        margin: EdgeInsets.all(containerMargin),
        padding: EdgeInsets.all(containerPadding),
        decoration: BoxDecoration(
          color: context.appColors.surfaceCard,
          borderRadius: BorderRadius.circular(16),
          // removed outer border per UX
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Title (no icon, no bordered container)
            Text(
              title,
              style: TextStyle(
                fontSize: titleFontSize,
                fontWeight: AppFontWeights.emphasis,
                color: headerFg.withValues(alpha: 0.95),
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
            const SizedBox(height: 2),
            // Timestamp under title, aligned with title
            Text(
              time,
              style: TextStyle(
                fontSize: timeFontSize,
                color: headerFg.withValues(alpha: 0.6),
              ),
            ),
            SizedBox(height: isDesktop ? 10.0 : 12.0),
            ChatMessageWidget(
              message: messageForExport,
              collapseLongUserText: false,
              modelIcon:
                  (!useAssistAvatar &&
                      message.role == 'assistant' &&
                      message.providerId != null &&
                      message.modelId != null)
                  ? CurrentModelIcon(
                      providerKey: message.providerId,
                      modelId: message.modelId,
                      size: 30,
                    )
                  : null,
              showModelIcon: !useAssistAvatar,
              useAssistantAvatar: useAssistAvatar,
              useAssistantName: useAssistName,
              assistantName: (useAssistAvatar || useAssistName)
                  ? (assistant?.name ?? 'Assistant')
                  : null,
              assistantAvatar: useAssistAvatar
                  ? (assistant?.avatar ?? '')
                  : null,
              showUserAvatar: context.read<SettingsProvider>().showUserAvatar,
              showTokenStats: false,
              reasoningSegments: exportReasoningPayload.segments.isEmpty
                  ? null
                  : exportReasoningPayload.segments,
              reasoningSegmentsFromInlineThinking:
                  exportReasoningPayload.fromInlineThinking,
              toolParts: toolParts.isEmpty ? null : toolParts,
              contentSplitOffsets: exportReasoningPayload.contentSplitOffsets,
              reasoningCountAtSplit:
                  exportReasoningPayload.reasoningCountAtSplit,
              toolCountAtSplit: exportReasoningPayload.toolCountAtSplit,
              hideStreamingIndicator: true,
              showThinkingCards: showThinkingAndToolCards,
              showToolCards: showThinkingAndToolCards,
            ),
            SizedBox(height: isDesktop ? 12.0 : 16.0),
            _ExportDisclaimer(isDesktop: isDesktop),
          ],
        ),
      ),
    );
  }
}

class _ExportedChatImage extends StatelessWidget {
  const _ExportedChatImage({
    required this.conversationTitle,
    required this.cs,
    required this.chatFontScale,
    required this.messages,
    required this.timestamp,
    this.showThinkingAndToolCards = false,
    this.expandThinkingContent = false,
    this.isDesktop = false,
  });
  final String conversationTitle;
  final ColorScheme cs;
  final double chatFontScale;
  final List<ChatMessage> messages;
  final DateTime timestamp;
  final bool showThinkingAndToolCards;
  final bool expandThinkingContent;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    // Desktop uses smaller font sizes for better proportions
    final double titleFontSize = isDesktop ? 15.0 : 18.0;
    final double timeFontSize = isDesktop ? 10.0 : 12.0;
    final double containerMargin = isDesktop ? 5.0 : 6.0;
    final double containerPadding = isDesktop ? 5.0 : 6.0;

    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(
          MediaQuery.textScalerOf(context).scale(1) * chatFontScale,
        ),
      ),
      child: ClipRect(
        child: Container(
          margin: EdgeInsets.all(containerMargin),
          padding: EdgeInsets.all(containerPadding),
          decoration: BoxDecoration(
            color: context.appColors.surfaceCard,
            borderRadius: BorderRadius.circular(isDesktop ? 12.0 : 16.0),
            // removed outer border per UX
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Title (no icon, no bordered container)
              Text(
                conversationTitle,
                style: TextStyle(
                  fontSize: titleFontSize,
                  fontWeight: AppFontWeights.emphasis,
                  color: cs.onSurface.withValues(alpha: 0.95),
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
              const SizedBox(height: 2),
              // Timestamp under title, aligned with title
              Text(
                DateFormat('yyyy-MM-dd HH:mm').format(timestamp),
                style: TextStyle(
                  fontSize: timeFontSize,
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
              ),
              SizedBox(height: isDesktop ? 10.0 : 12.0),
              for (final m in messages) ...[
                _ExportedBubble(
                  message: m,
                  cs: cs,
                  showThinkingAndToolCards: showThinkingAndToolCards,
                  expandThinkingContent: expandThinkingContent,
                  isDesktop: isDesktop,
                ),
                SizedBox(height: isDesktop ? 6.0 : 8.0),
              ],
              SizedBox(height: isDesktop ? 10.0 : 12.0),
              _ExportDisclaimer(isDesktop: isDesktop),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExportedBubble extends StatelessWidget {
  const _ExportedBubble({
    required this.message,
    required this.cs,
    this.showThinkingAndToolCards = false,
    this.expandThinkingContent = false,
    this.isDesktop = false,
  });
  final ChatMessage message;
  final ColorScheme cs;
  final bool showThinkingAndToolCards;
  final bool expandThinkingContent;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    final isAssistant = message.role == 'assistant';
    final bubbleBg = cs.primary.withValues(alpha: 0.08);
    final bubbleFg = cs.onSurface;

    // Desktop uses smaller font sizes for better proportions
    final double contentFontSize = isDesktop ? 13.0 : 15.7;

    final messageForExport = messageForThinkingExport(
      message,
      showThinkingAndToolCards: showThinkingAndToolCards,
    );
    final preserveTimeline =
        isAssistant &&
        (showThinkingAndToolCards || uiDisplayFences(message).isNotEmpty);
    final exportReasoningPayload = preserveTimeline
        ? _exportReasoningPayloadForMessage(
            message,
            expandThinkingContent: expandThinkingContent,
          )
        : const _ExportReasoningPayload(segments: <ReasoningSegment>[]);
    final toolParts = preserveTimeline
        ? _exportToolPartsForMessage(context, message)
        : const <ToolUIPart>[];
    final assistant = context.read<AssistantProvider>().currentAssistant;
    final useAssistAvatar =
        isAssistant && (assistant?.useAssistantAvatar == true);
    final useAssistName = isAssistant && (assistant?.useAssistantName == true);

    // Keep attachments from the original message parts. copyWith(content:)
    // rewrites parts to a single TextPart and would drop ImagePart/FilePart.
    final parsed = _exportPartsFromMessage(
      message,
      textOverride: messageForExport.content,
    );
    final mdText = StringBuffer();
    if (parsed.text.isNotEmpty) mdText.writeln(_softBreakMd(parsed.text));
    for (final p in parsed.images) {
      mdText.writeln('\n![](${SandboxPathResolver.fix(p)})\n');
    }
    for (final d in parsed.docs) {
      mdText.writeln('\n- ${d.fileName}  `(${d.mime})`');
    }
    final Widget contentWidget = (mdText.toString().trim().isNotEmpty)
        ? DefaultTextStyle.merge(
            style: TextStyle(fontSize: contentFontSize, height: 1.5),
            child: AppSelectionArea(
              child: MarkdownWithCodeHighlight(text: mdText.toString()),
            ),
          )
        : Text('—', style: TextStyle(color: bubbleFg.withValues(alpha: 0.5)));

    if (isAssistant) {
      return Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isDesktop ? 760.0 : 860.0),
          child: ChatMessageWidget(
            message: messageForExport,
            modelIcon:
                (!useAssistAvatar &&
                    message.role == 'assistant' &&
                    message.providerId != null &&
                    message.modelId != null)
                ? CurrentModelIcon(
                    providerKey: message.providerId,
                    modelId: message.modelId,
                    size: 30,
                  )
                : null,
            showModelIcon: !useAssistAvatar,
            useAssistantAvatar: useAssistAvatar,
            useAssistantName: useAssistName,
            assistantName: (useAssistAvatar || useAssistName)
                ? (assistant?.name ?? 'Assistant')
                : null,
            assistantAvatar: useAssistAvatar ? (assistant?.avatar ?? '') : null,
            showUserAvatar: context.read<SettingsProvider>().showUserAvatar,
            showTokenStats: false,
            reasoningSegments: exportReasoningPayload.segments.isEmpty
                ? null
                : exportReasoningPayload.segments,
            reasoningSegmentsFromInlineThinking:
                exportReasoningPayload.fromInlineThinking,
            toolParts: toolParts.isEmpty ? null : toolParts,
            contentSplitOffsets: exportReasoningPayload.contentSplitOffsets,
            reasoningCountAtSplit: exportReasoningPayload.reasoningCountAtSplit,
            toolCountAtSplit: exportReasoningPayload.toolCountAtSplit,
            hideStreamingIndicator: true,
            showThinkingCards: showThinkingAndToolCards,
            showToolCards: showThinkingAndToolCards,
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isDesktop ? 600.0 : 680.0),
        child: Container(
          padding: EdgeInsets.all(isDesktop ? 10.0 : 12.0),
          decoration: BoxDecoration(
            color: bubbleBg,
            borderRadius: BorderRadius.circular(isDesktop ? 12.0 : 16.0),
          ),
          child: contentWidget,
        ),
      ),
    );
  }
}

class _ExportDisclaimer extends StatelessWidget {
  const _ExportDisclaimer({this.isDesktop = false});
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = AppLocalizations.of(context)!.exportDisclaimerAiGenerated;
    final double fontSize = isDesktop ? 10.0 : 12.0;
    return Center(
      child: Padding(
        padding: EdgeInsets.only(
          top: isDesktop ? 3.0 : 4.0,
          bottom: isDesktop ? 4.0 : 6.0,
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: fontSize,
            color: cs.onSurface.withValues(alpha: 0.5),
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

@visibleForTesting
Widget buildImageExportProgressForTesting(ExportImageProgress progress) =>
    _ExportProgressContent(progress: progress);

class _ExportProgressContent extends StatelessWidget {
  const _ExportProgressContent({required this.progress});
  final ExportImageProgress progress;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final label = switch (progress.stage) {
      ExportImageStage.preparing => l10n.imageExportPreparing,
      ExportImageStage.diagrams => l10n.imageExportDiagrams(
        progress.completed,
        progress.total,
      ),
      ExportImageStage.capturing => l10n.imageExportCapturing(
        progress.completed,
        progress.total,
      ),
      ExportImageStage.processing => l10n.imageExportProcessing,
      ExportImageStage.saving => l10n.imageExportSaving,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: SizedBox(
        width: 240,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CupertinoActivityIndicator(radius: 16),
            const SizedBox(height: 12),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: .8),
              ),
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress.fraction),
          ],
        ),
      ),
    );
  }
}

Future<void> _runWithExportingOverlay(
  BuildContext context,
  Future<void> Function(ValueNotifier<ExportImageProgress> progress) task,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final progress = ValueNotifier(
    const ExportImageProgress(ExportImageStage.preparing),
  );
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: Center(
        child: Material(
          color: context.appColors.surfaceCard,
          elevation: 6,
          shadowColor: Theme.of(
            context,
          ).colorScheme.shadow.withValues(alpha: .2),
          borderRadius: BorderRadius.circular(14),
          child: ValueListenableBuilder<ExportImageProgress>(
            valueListenable: progress,
            builder: (context, value, _) =>
                _ExportProgressContent(progress: value),
          ),
        ),
      ),
    ),
  );
  unawaited(navigator.push(route));
  try {
    await WidgetsBinding.instance.endOfFrame;
    await task(progress);
  } finally {
    // Remove only this operation's dialog, even when another route was opened.
    if (route.isActive) navigator.removeRoute(route);
    progress.dispose();
  }
}

class _Parsed {
  final String text;
  final List<String> images;
  final List<_DocRef> docs;
  _Parsed(this.text, this.images, this.docs);
}

/// Display-only document ref (fileName/MIME). If future code reads [path],
/// resolve via [SandboxPathResolver.fix] first — it may be a kelivo-file URI.
class _DocRef {
  final String path;
  final String fileName;
  final String mime;
  _DocRef({required this.path, required this.fileName, required this.mime});
}

class _ExportOptionTile extends StatelessWidget {
  const _ExportOptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final Color base = isDark
        ? cs.primary.withValues(alpha: 0.10)
        : cs.primary.withValues(alpha: 0.06);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: IosCardPress(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        baseColor: base,
        pressedBlendStrength: isDark ? 0.14 : 0.12,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 22, color: cs.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: AppFontWeights.semibold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The one-line marker a context operation leaves in an export.
///
/// A compression or a clear is part of what the conversation says: a reader who
/// sees a summary section needs to know it is one, and whether it still applies.
String _exportContextNodeText(
  ContextOperation op,
  AppLocalizations l10n, {
  required bool hidden,
  required List<ContextOperation> operations,
}) {
  final title = op.isCompression
      ? l10n.contextCompressMarker
      : l10n.contextClearMarker;
  final status = op.revoked
      ? l10n.contextOperationUndone
      : hidden
      ? l10n.contextOperationHidden
      : operations.any(
          (item) => !item.revoked && item.dependencies.contains(op.id),
        )
      ? l10n.contextOperationSuperseded
      : l10n.contextOperationActive;
  return op.isCompression && op.summary.isNotEmpty
      ? '$title · $status\n${op.summary}'
      : '$title · $status';
}
