import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../../../utils/sandbox_path_resolver.dart';
import '../../chat/models/tool_ui_part.dart';
import 'web_chat_protocol.dart';
import 'web_chat_remote_media.dart';
import 'web_chat_shell_cache.dart';
import 'web_chat_snapshot.dart';

/// Renders a conversation (or message selection) to PDF using the web chat
/// shell in print mode — the same DOM renderer + styles as the interactive
/// Web viewport (ADR-0044). Windows only in v1; other platforms throw
/// [PdfUnsupportedPlatformException] instead of silently degrading.
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
  final settings = context.read<SettingsProvider>();
  final userProvider = context.read<UserProvider>();
  final assistant = context.read<AssistantProvider>().currentAssistant;
  final chatService = context.read<ChatService>();
  final l10n = AppLocalizations.of(context)!;
  final themeData = Theme.of(context);
  final colors = themeData.colorScheme;
  final semantic = context.appColors;
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
  final registry = media.registry;

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
      colors: colors,
      semantic: semantic,
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

  final outputDir = await getTemporaryDirectory();
  final outputFile = File(
    '${outputDir.path}/cuplivo-pdf-${DateTime.now().millisecondsSinceEpoch}.pdf',
  );

  final controller = winweb.WebviewController();
  StreamSubscription<dynamic>? subscription;
  var disposed = false;
  final completer = Completer<({File file, bool timedOut})>();
  var snapshotSent = false;

  Future<void> sendEnvelope(Map<String, dynamic> envelope) async {
    await controller.postWebMessage(jsonEncode(envelope));
  }

  Future<void> sendSnapshot() async {
    if (snapshotSent) return;
    final payload = Map<String, dynamic>.of(snapshot)
      ..['capabilityToken'] = capabilityToken;
    if (!completer.isCompleted && !disposed) {
      snapshotSent = true;
      for (final chunk in chunkWebChatEnvelope(
        payload: payload,
        transferId: 'pdf-snapshot:$sessionId',
      )) {
        await sendEnvelope(chunk);
      }
    }
  }

  Future<void> handleBridgeMessage(String raw) async {
    Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      message = decoded.map((key, value) => MapEntry(key.toString(), value));
    } catch (_) {
      return;
    }
    final type = message['type']?.toString();
    final authorized = message['capabilityToken'] == capabilityToken;
    try {
      switch (type) {
        case 'ready':
          if (!completer.isCompleted) await sendSnapshot();
          return;
        case 'mediaRequest':
          if (!authorized) return;
          await _answerMediaRequest(
            message: message,
            sessionId: sessionId,
            conversationId: conversation.id,
            registry: registry,
            clientFactory: () => _newMediaClient(settings),
            sendEnvelope: sendEnvelope,
          );
          return;
        case 'printRenderComplete':
          if (!authorized ||
              message['renderSessionId'] != sessionId ||
              message['conversationId'] != conversation.id) {
            return;
          }
          final timedOut = message['timedOut'] == true;
          if (timedOut) {
            debugPrint(
              'WebConversationPdfPrinter: shell print render completed with '
              'timeout (media/renderers incomplete)',
            );
          }
          try {
            await controller.printToPdf(
              outputFile.path,
              printBackgrounds: true,
            );
          } catch (error) {
            if (!completer.isCompleted) {
              completer.completeError(
                WebChatProtocolException('pdf capture failed: $error'),
              );
            }
            return;
          }
          if (!completer.isCompleted) {
            completer.complete((file: outputFile, timedOut: timedOut));
          }
          return;
        case 'diagnostic':
          debugPrint(
            'WebConversationPdfPrinter: shell diagnostic '
            '${message['code'] ?? message}',
          );
          return;
      }
    } catch (error) {
      debugPrint(
        'WebConversationPdfPrinter: bridge handling failed '
        '(${error.runtimeType})',
      );
    }
  }

  try {
    await controller.initialize().timeout(const Duration(seconds: 20));
    await controller.setBackgroundColor(const Color(0x00000000));
    await controller.setPopupWindowPolicy(winweb.WebviewPopupWindowPolicy.deny);
    subscription = controller.webMessage.listen(
      (event) {
        try {
          unawaited(handleBridgeMessage(_windowsMessageText(event)));
        } catch (error) {
          debugPrint(
            'WebConversationPdfPrinter: bridge handling failed '
            '(${error.runtimeType})',
          );
        }
      },
      onError: (Object error) {
        debugPrint(
          'WebConversationPdfPrinter: bridge error (${error.runtimeType})',
        );
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
    return result;
  } finally {
    disposed = true;
    await subscription?.cancel();
    try {
      await controller.dispose();
    } catch (error) {
      debugPrint(
        'WebConversationPdfPrinter: dispose failed (${error.runtimeType})',
      );
    }
  }
}

class PdfUnsupportedPlatformException implements Exception {
  const PdfUnsupportedPlatformException();

  @override
  String toString() => 'PDF export is only supported on Windows in v1';
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
  final random = math.Random();
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

Future<void> _answerMediaRequest({
  required Map<String, dynamic> message,
  required String sessionId,
  required String conversationId,
  required Map<String, WebChatMediaSource> registry,
  required WebChatHttpClientFactory clientFactory,
  required Future<void> Function(Map<String, dynamic>) sendEnvelope,
}) async {
  final handle = message['handle']?.toString() ?? '';
  final source = registry[handle];
  if (source == null) {
    await _sendMediaError(sendEnvelope, sessionId, conversationId, handle);
    return;
  }
  try {
    String mime;
    Uint8List bytes;
    if (source.kind == WebChatMediaSourceKind.remoteImage) {
      final remote = await WebChatRemoteImageLoader(
        clientFactory: clientFactory,
      ).load(source.value);
      mime = remote.mime;
      bytes = remote.bytes;
    } else {
      final extension = source.value.toLowerCase().split('.').last;
      mime = switch (extension) {
        'png' => 'image/png',
        'jpg' || 'jpeg' => 'image/jpeg',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        'svg' when source.kind == WebChatMediaSourceKind.bundledAsset =>
          'image/svg+xml',
        _ => '',
      };
      if (mime.isEmpty) {
        await _sendMediaError(sendEnvelope, sessionId, conversationId, handle);
        return;
      }
      bytes = switch (source.kind) {
        WebChatMediaSourceKind.localFile => await _readLocalMedia(source.value),
        WebChatMediaSourceKind.bundledAsset => await _readBundledMedia(
          source.value,
        ),
        WebChatMediaSourceKind.remoteImage => throw StateError(
          'remote media handled above',
        ),
      };
    }
    final payload = <String, dynamic>{
      'type': 'mediaResult',
      'renderSessionId': sessionId,
      'conversationId': conversationId,
      'handle': handle,
      'dataUrl': 'data:$mime;base64,${base64Encode(bytes)}',
    };
    for (final chunk in chunkWebChatEnvelope(
      payload: payload,
      transferId: 'pdf-media:$sessionId:${handle.hashCode}',
    )) {
      await sendEnvelope(chunk);
    }
  } catch (error) {
    debugPrint(
      'WebConversationPdfPrinter: media request failed for $handle '
      '(${error.runtimeType}: $error)',
    );
    await _sendMediaError(sendEnvelope, sessionId, conversationId, handle);
  }
}

Future<void> _sendMediaError(
  Future<void> Function(Map<String, dynamic>) sendEnvelope,
  String sessionId,
  String conversationId,
  String handle,
) async {
  try {
    await sendEnvelope(<String, dynamic>{
      'type': 'mediaError',
      'renderSessionId': sessionId,
      'conversationId': conversationId,
      'handle': handle,
    });
  } catch (error) {
    debugPrint(
      'WebConversationPdfPrinter: mediaError reply failed '
      '(${error.runtimeType})',
    );
  }
}

Future<Uint8List> _readLocalMedia(String path) async {
  final resolvedPath = SandboxPathResolver.fix(path);
  final file = File(resolvedPath);
  if (!await file.exists()) {
    throw const FileSystemException('media file does not exist');
  }
  final length = await file.length();
  if (length > 16 * 1024 * 1024) {
    throw const WebChatProtocolException('local media exceeds size limit');
  }
  final bytes = await file.readAsBytes();
  if (bytes.length > 16 * 1024 * 1024) {
    throw const WebChatProtocolException('local media exceeds size limit');
  }
  return bytes;
}

Future<Uint8List> _readBundledMedia(String path) async {
  if (!path.startsWith('assets/icons/') ||
      path.contains('..') ||
      path.contains(r'\')) {
    throw const WebChatProtocolException('bundled media is not allowed');
  }
  final data = await rootBundle.load(path);
  if (data.lengthInBytes > 2 * 1024 * 1024) {
    throw const WebChatProtocolException('bundled media exceeds size limit');
  }
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
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
