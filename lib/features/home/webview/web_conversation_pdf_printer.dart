import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:webview_windows/webview_windows.dart' as winweb;

import '../../../core/models/assistant.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/reasoning_payload.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/network/dio_http_client.dart';
import '../../../l10n/app_localizations.dart';
import '../../../theme/app_semantic_colors.dart';
import '../../chat/models/tool_ui_part.dart';
import 'android_web_chat_pdf_controller.dart';
import 'web_chat_pdf_bridge.dart';
import 'web_chat_protocol.dart';
import 'web_chat_shell_cache.dart';
import 'web_chat_snapshot.dart';

/// Renders a conversation (or message selection) to PDF using the web chat
/// shell in print mode — the same DOM renderer + styles as the interactive
/// Web viewport (ADR-0044). This is the Windows capture endpoint; Android uses
/// [printConversationPdfOnAndroid] with the same snapshot and bridge.
///
/// The flow:
/// 1. build a static snapshot (collapsed messages, no streaming/patches);
/// 2. load `index.html` with `mode=print` over the Windows secure origin;
/// 3. answer shell `mediaRequest`s from the media registry;
/// 4. wait for the shell's `printRenderComplete` signal;
/// 5. call WebView2 `PrintToPdf` into a temp file and return it.
Future<({File file, bool timedOut})> renderConversationPdf(
  BuildContext context, {
  required Conversation conversation,
  required List<ChatMessage> messages,
  bool showThinkingAndToolCards = false,
  bool expandThinkingContent = false,
}) async {
  if (!Platform.isWindows) {
    throw const PdfUnsupportedPlatformException();
  }
  final render = _preparePdfRender(
    context,
    conversation: conversation,
    messages: messages,
    showThinkingAndToolCards: showThinkingAndToolCards,
    expandThinkingContent: expandThinkingContent,
  );

  final outputDir = await getTemporaryDirectory();
  final outputFile = File(
    '${outputDir.path}/cuplivo-pdf-${DateTime.now().millisecondsSinceEpoch}.pdf',
  );

  final controller = winweb.WebviewController();
  StreamSubscription<dynamic>? subscription;
  final completer = Completer<({File file, bool timedOut})>();
  late final WebChatPdfBridgeCoordinator bridge;
  bridge = WebChatPdfBridgeCoordinator(
    renderSessionId: render.sessionId,
    conversationId: render.conversationId,
    capabilityToken: render.capabilityToken,
    snapshot: render.snapshot,
    mediaRegistry: render.mediaRegistry,
    clientFactory: () => _newMediaClient(render.settings),
    sendEnvelope: (envelope) => controller.postWebMessage(jsonEncode(envelope)),
    onRenderComplete: (timedOut) async {
      try {
        await controller.printToPdf(outputFile.path, printBackgrounds: true);
        await _validatePdfFile(outputFile);
        if (!completer.isCompleted) {
          completer.complete((file: outputFile, timedOut: timedOut));
        }
      } catch (error) {
        if (!completer.isCompleted) {
          completer.completeError(
            WebChatProtocolException('PDF capture failed: $error'),
          );
        }
      }
    },
    onFailure: (error) {
      if (!completer.isCompleted) completer.completeError(error);
    },
  );

  var succeeded = false;
  try {
    await controller.initialize().timeout(const Duration(seconds: 20));
    await controller.setBackgroundColor(const Color(0x00000000));
    await controller.setPopupWindowPolicy(winweb.WebviewPopupWindowPolicy.deny);
    subscription = controller.webMessage.listen(
      (event) {
        unawaited(bridge.handleMessage(_windowsMessageText(event)));
      },
      onError: (Object error) {
        debugPrint(
          'WebConversationPdfPrinter: bridge error (${error.runtimeType})',
        );
        if (!completer.isCompleted) completer.completeError(error);
      },
    );
    final shell = await prepareWindowsWebChatShell();
    await controller.addVirtualHostNameMapping(
      webChatWindowsVirtualHost,
      shell.parent.path,
      winweb.WebviewHostResourceAccessKind.deny,
    );
    await controller.loadUrl(
      Uri(
        scheme: 'https',
        host: webChatWindowsVirtualHost,
        path: '/index.html',
        queryParameters: <String, String>{
          'platform': 'windows',
          'mode': 'print',
        },
      ).toString(),
    );

    final result = await completer.future.timeout(const Duration(seconds: 90));
    succeeded = true;
    return result;
  } finally {
    bridge.dispose();
    await subscription?.cancel();
    try {
      await controller.dispose();
    } catch (error) {
      debugPrint(
        'WebConversationPdfPrinter: dispose failed (${error.runtimeType})',
      );
    }
    if (!succeeded && await outputFile.exists()) {
      try {
        await outputFile.delete();
      } catch (error) {
        debugPrint(
          'WebConversationPdfPrinter: partial PDF cleanup failed '
          '(${error.runtimeType})',
        );
      }
    }
  }
}

class PdfUnsupportedPlatformException implements Exception {
  const PdfUnsupportedPlatformException();

  @override
  String toString() => 'PDF export is only supported on Windows and Android';
}

/// Renders with the shared print snapshot/bridge, then opens Android's
/// official system print UI. Android owns the destination and offers
/// “Save as PDF” alongside installed print services.
Future<({bool timedOut, bool cancelled})> printConversationPdfOnAndroid(
  BuildContext context, {
  required Conversation conversation,
  required List<ChatMessage> messages,
  bool showThinkingAndToolCards = false,
  bool expandThinkingContent = false,
}) async {
  if (!Platform.isAndroid) {
    throw const PdfUnsupportedPlatformException();
  }
  final render = _preparePdfRender(
    context,
    conversation: conversation,
    messages: messages,
    showThinkingAndToolCards: showThinkingAndToolCards,
    expandThinkingContent: expandThinkingContent,
  );
  final renderComplete = Completer<bool>();
  late final WebChatPdfBridgeCoordinator bridge;
  late final AndroidWebChatPdfController controller;

  void fail(Object error) {
    if (!renderComplete.isCompleted) renderComplete.completeError(error);
  }

  controller = AndroidWebChatPdfController(
    onMessage: (message) => bridge.handleMessage(message),
    onResourceError: (errorCode) => fail(
      WebChatProtocolException('Android PDF shell resource failed: $errorCode'),
    ),
    onDiagnostic: (code) {
      debugPrint('WebConversationPdfPrinter: Android diagnostic $code');
      if (code == 'render_process_gone') {
        fail(
          const WebChatProtocolException(
            'Android PDF WebView render process exited',
          ),
        );
      }
    },
  );
  bridge = WebChatPdfBridgeCoordinator(
    renderSessionId: render.sessionId,
    conversationId: render.conversationId,
    capabilityToken: render.capabilityToken,
    snapshot: render.snapshot,
    mediaRegistry: render.mediaRegistry,
    clientFactory: () => _newMediaClient(render.settings),
    sendEnvelope: controller.postEnvelope,
    onRenderComplete: (timedOut) async {
      if (!renderComplete.isCompleted) renderComplete.complete(timedOut);
    },
    onFailure: fail,
  );

  try {
    await controller.start();
    final timedOut = await renderComplete.future.timeout(
      const Duration(seconds: 90),
    );
    final title = conversation.title.trim();
    final status = await controller.print(
      documentName: title.isEmpty ? 'Cuplivo' : title,
    );
    return (
      timedOut: timedOut,
      cancelled: status == AndroidPdfPrintStatus.cancelled,
    );
  } finally {
    bridge.dispose();
    await controller.dispose();
  }
}

class _PreparedPdfRender {
  const _PreparedPdfRender({
    required this.settings,
    required this.sessionId,
    required this.conversationId,
    required this.capabilityToken,
    required this.snapshot,
    required this.mediaRegistry,
  });

  final SettingsProvider settings;
  final String sessionId;
  final String conversationId;
  final String capabilityToken;
  final Map<String, dynamic> snapshot;
  final Map<String, WebChatMediaSource> mediaRegistry;
}

_PreparedPdfRender _preparePdfRender(
  BuildContext context, {
  required Conversation conversation,
  required List<ChatMessage> messages,
  required bool showThinkingAndToolCards,
  required bool expandThinkingContent,
}) {
  final settings = context.read<SettingsProvider>();
  final userProvider = context.read<UserProvider>();
  final assistant = context.read<AssistantProvider>().currentAssistant;
  final chatService = context.read<ChatService>();
  final l10n = AppLocalizations.of(context)!;
  final themeData = Theme.of(context);
  final isDark = themeData.brightness == Brightness.dark;
  final sessionId =
      'pdf-${DateTime.now().microsecondsSinceEpoch}-${conversation.id.hashCode}';
  final capabilityToken = _randomCapabilityToken();
  final toolParts = showThinkingAndToolCards
      ? _exportToolParts(chatService, messages)
      : <String, List<ToolUIPart>>{};
  final media = buildPdfMediaBundle(
    messages: messages,
    assistant: assistant,
    userAvatarType: userProvider.avatarType,
    userAvatarValue: userProvider.avatarValue,
    toolParts: toolParts,
  );
  final snapshot = const WebChatSnapshotBuilder().build(
    renderSessionId: sessionId,
    conversationId: conversation.id,
    renderRevision: 0,
    actionEpoch: 0,
    messages: messages,
    byGroup: _byGroup(messages),
    versionSelections: <String, int>{},
    reasoning: <String, ReasoningData>{},
    reasoningSegments: showThinkingAndToolCards
        ? _exportReasoningSegments(messages, expandThinkingContent)
        : <String, List<ReasoningSegmentData>>{},
    contentSplits: showThinkingAndToolCards
        ? _exportContentSplits(messages)
        : <String, ContentSplitData>{},
    toolParts: toolParts,
    selectedItems: <String>{},
    selecting: false,
    truncCollapsedIndex: 0,
    suggestions: const <String>[],
    hasMoreBefore: false,
    hasMoreAfter: false,
    strings: webChatUiStrings(l10n),
    theme: webChatThemeColors(
      colors: themeData.colorScheme,
      semantic: context.appColors,
      isDark: isDark,
      backgroundMaskStrength: settings.chatBackgroundMaskStrength,
    ),
    appearance:
        settings.activeWebConversationStyle?.resolveAppearance(
          isDark: isDark,
        ) ??
        const <String, dynamic>{},
    user: buildWebChatUserSnapshot(
      name: userProvider.name,
      avatarType: userProvider.avatarType,
      avatarValue: userProvider.avatarValue,
    ),
    display: webChatDisplay(
      settings,
      wrapCode: Platform.isWindows || settings.mobileCodeBlockWrap,
      isDark: isDark,
      ttsActive: false,
    ),
    topContentPadding: 0,
    bottomContentPadding: 0,
    assistant: assistant,
    fontScale: settings.chatFontScale,
    canStartMultiAI: false,
    autoCollapseThinking:
        settings.autoCollapseThinking || !expandThinkingContent,
    locale: Localizations.localeOf(context).toLanguageTag(),
    textDirection: Directionality.of(context) == TextDirection.rtl
        ? 'rtl'
        : 'ltr',
    remoteMediaHandles: media.remoteMediaHandles,
  );
  return _PreparedPdfRender(
    settings: settings,
    sessionId: sessionId,
    conversationId: conversation.id,
    capabilityToken: capabilityToken,
    snapshot: snapshot,
    mediaRegistry: media.registry,
  );
}

/// The media registry + remote-handle map backing [renderConversationPdf]'s
/// snapshot.
///
/// The same `toolParts` the snapshot renders must reach the registry, otherwise
/// remote images inside tool results are never registered and the shell's print
/// render waits on them until its 30s `timedOut` fallback. `toolParts` is
/// required so the printer can never lose the second wiring by accident.
@visibleForTesting
({
  Map<String, WebChatMediaSource> registry,
  Map<String, String> remoteMediaHandles,
})
buildPdfMediaBundle({
  required List<ChatMessage> messages,
  Assistant? assistant,
  String? userAvatarType,
  String? userAvatarValue,
  required Map<String, List<ToolUIPart>> toolParts,
}) {
  final registry = buildWebChatMediaRegistry(
    messages,
    assistant: assistant,
    userAvatarType: userAvatarType,
    userAvatarValue: userAvatarValue,
    toolParts: toolParts,
  );
  return (
    registry: registry,
    remoteMediaHandles: <String, String>{
      for (final entry in registry.entries)
        if (entry.value.kind == WebChatMediaSourceKind.remoteImage)
          entry.value.value: entry.key,
    },
  );
}

NetworkProxyConfig? _proxyFor(SettingsProvider settings) {
  final host = settings.globalProxyHost.trim();
  final port = settings.globalProxyPort.trim();
  if (!settings.globalProxyEnabled || host.isEmpty || port.isEmpty) {
    return null;
  }
  return NetworkProxyConfig(
    enabled: true,
    type: settings.globalProxyType,
    host: host,
    port: int.tryParse(port) ?? 8080,
    username: settings.globalProxyUsername.trim().isEmpty
        ? null
        : settings.globalProxyUsername.trim(),
    password: settings.globalProxyPassword.isEmpty
        ? null
        : settings.globalProxyPassword,
  );
}

/// A fresh client per remote-image load — `WebChatRemoteImageLoader.load`
/// closes its client in `finally` on every call, so a reused DioHttpClient
/// would die after the first http:// image (same pattern as the interactive
/// viewport's `_webChatHttpClient(settings)`).
DioHttpClient _newMediaClient(SettingsProvider settings) =>
    DioHttpClient(forceCloseOnDispose: true, proxy: _proxyFor(settings));

Map<String, List<ChatMessage>> _byGroup(List<ChatMessage> messages) {
  final result = <String, List<ChatMessage>>{};
  for (final message in messages) {
    (result[message.groupId ?? message.id] ??= <ChatMessage>[]).add(message);
  }
  return result;
}

String _randomCapabilityToken() {
  final random = math.Random.secure();
  final buffer = <int>[];
  for (var i = 0; i < 32; i++) {
    buffer.add(random.nextInt(256));
  }
  return base64Encode(buffer);
}

String _windowsMessageText(dynamic event) {
  if (event is String) return event;
  if (event is Map && event['value'] is String) {
    return event['value'] as String;
  }
  return event?.toString() ?? '';
}

Future<void> _validatePdfFile(File file) async {
  if (!await file.exists() || await file.length() < 5) {
    throw const FileSystemException('PDF output is empty');
  }
  final handle = await file.open();
  try {
    final header = await handle.read(5);
    if (ascii.decode(header, allowInvalid: true) != '%PDF-') {
      throw const FileSystemException('PDF output has an invalid header');
    }
  } finally {
    await handle.close();
  }
}

Map<String, List<ReasoningSegmentData>> _exportReasoningSegments(
  List<ChatMessage> messages,
  bool expandThinkingContent,
) {
  final result = <String, List<ReasoningSegmentData>>{};
  for (final message in messages) {
    final segments = _reasoningSegmentsForMessage(
      message,
      expandThinkingContent: expandThinkingContent,
    );
    if (segments.isNotEmpty) result[message.id] = segments;
  }
  return result;
}

List<ReasoningSegmentData> _reasoningSegmentsForMessage(
  ChatMessage message, {
  required bool expandThinkingContent,
}) {
  final segments = <ReasoningSegmentData>[];
  final segJson = (message.reasoningSegmentsJson ?? '').trim();
  if (segJson.isNotEmpty) {
    try {
      final decoded = jsonDecode(segJson);
      final rawSegments = decoded is Map<String, dynamic>
          ? (decoded['segments'] as List? ?? const <dynamic>[])
          : decoded is List
          ? decoded
          : const <dynamic>[];
      for (final item in rawSegments) {
        if (item is! Map) continue;
        final map = item.cast<String, dynamic>();
        final text = (map['text']?.toString() ?? '').trim();
        if (text.isEmpty) continue;
        segments.add(
          ReasoningSegmentData()
            ..text = text
            ..startAt = DateTime.tryParse(map['startAt']?.toString() ?? '')
            ..finishedAt = DateTime.tryParse(
              map['finishedAt']?.toString() ?? '',
            )
            ..expanded = expandThinkingContent
            ..toolStartIndex = (map['toolStartIndex'] as int?) ?? 0,
        );
      }
    } catch (_) {}
  }
  if (segments.isEmpty) {
    final rt = (message.reasoningText ?? '').trim();
    if (rt.isNotEmpty) {
      segments.add(
        ReasoningSegmentData()
          ..text = rt
          ..expanded = expandThinkingContent,
      );
    }
  }
  return segments;
}

Map<String, ContentSplitData> _exportContentSplits(List<ChatMessage> messages) {
  final result = <String, ContentSplitData>{};
  for (final message in messages) {
    final segJson = (message.reasoningSegmentsJson ?? '').trim();
    if (segJson.isEmpty) continue;
    try {
      final decoded = jsonDecode(segJson);
      if (decoded is Map<String, dynamic>) {
        final contentSplits = (decoded['contentSplits'] as Map?)
            ?.cast<String, dynamic>();
        if (contentSplits != null) {
          final offsets =
              (contentSplits['offsets'] as List? ?? const <dynamic>[])
                  .map((item) => (item as num).toInt())
                  .toList();
          final reasoningCounts =
              (contentSplits['reasoningCounts'] as List? ?? const <dynamic>[])
                  .map((item) => (item as num).toInt())
                  .toList();
          final toolCounts =
              (contentSplits['toolCounts'] as List? ?? const <dynamic>[])
                  .map((item) => (item as num).toInt())
                  .toList();
          final normalizedLength = [
            offsets.length,
            reasoningCounts.length,
            toolCounts.length,
          ].reduce((a, b) => a < b ? a : b);
          result[message.id] = ContentSplitData(
            offsets: List<int>.of(offsets.take(normalizedLength)),
            reasoningCounts: List<int>.of(
              reasoningCounts.take(normalizedLength),
            ),
            toolCounts: List<int>.of(toolCounts.take(normalizedLength)),
          );
        }
      }
    } catch (_) {}
  }
  return result;
}

Map<String, List<ToolUIPart>> _exportToolParts(
  ChatService chatService,
  List<ChatMessage> messages,
) {
  final result = <String, List<ToolUIPart>>{};
  for (final message in messages) {
    try {
      final events = chatService.getToolEvents(message.id);
      if (events.isEmpty) continue;
      result[message.id] = events
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
              loading: !(e['content']?.toString().isNotEmpty == true),
            ),
          )
          .toList();
    } catch (error) {
      debugPrint(
        'WebConversationPdfPrinter: tool parts failed for '
        '${message.id} (${error.runtimeType})',
      );
    }
  }
  return result;
}
