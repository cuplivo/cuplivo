import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../theme/app_semantic_colors.dart';
import '../../../utils/brand_assets.dart';
import '../../chat/models/tool_ui_part.dart';
import '../../chat/utils/message_visual_content.dart';
import '../../chat/utils/thinking_tag_parser.dart';
import '../controllers/stream_controller.dart' as stream_ctrl;
import 'web_chat_protocol.dart';

final DateFormat _webChatTimestampFormat = DateFormat('yyyy-MM-dd HH:mm:ss');
const int webChatMaxHtmlPreviewCodeUnits = 1024 * 1024;

String stripWebChatAttachmentMarkers(String content) => content
    .replaceAll(RegExp(r'\[image:[^\]]+\]'), '')
    .replaceAll(RegExp(r'\[file:[^\]]+\]'), '')
    .trim();

String normalizeWebChatHtmlPreviewSource(String source) =>
    source.replaceAll(RegExp(r'\r\n?'), '\n').replaceFirst(RegExp(r'\n+$'), '');

String webChatHtmlPreviewHandle(String messageId, String source) {
  final normalized = normalizeWebChatHtmlPreviewSource(source);
  final digest = sha256.convert(utf8.encode('$messageId\u0000$normalized'));
  return 'html:$digest';
}

class WebChatHtmlPreviewSource {
  const WebChatHtmlPreviewSource({
    required this.messageId,
    required this.source,
  });

  final String messageId;
  final String source;
}

WebChatHtmlPreviewSource resolveWebChatHtmlPreviewSource({
  required String messageId,
  required Object? rawSource,
  required Map<String, WebChatHtmlPreviewSource> registry,
}) {
  if (rawSource is! String ||
      rawSource.length > webChatMaxHtmlPreviewCodeUnits) {
    throw const WebChatProtocolException('invalid HTML preview source');
  }
  final source = normalizeWebChatHtmlPreviewSource(rawSource);
  final handle = webChatHtmlPreviewHandle(messageId, source);
  final registered = registry[handle];
  if (registered == null ||
      registered.messageId != messageId ||
      registered.source != source) {
    throw const WebChatProtocolException('HTML preview source is stale');
  }
  return registered;
}

Map<String, WebChatHtmlPreviewSource> buildWebChatHtmlPreviewRegistry(
  Map<String, dynamic> snapshot,
) {
  final registry = <String, WebChatHtmlPreviewSource>{};
  for (final rawMessage
      in snapshot['messages'] as List<dynamic>? ?? const <dynamic>[]) {
    if (rawMessage is! Map) continue;
    final message = rawMessage.map(
      (key, value) => MapEntry(key.toString(), value),
    );
    final messageId = message['id']?.toString() ?? '';
    if (messageId.isEmpty || message['isStreaming'] == true) continue;
    registerWebChatHtmlPreviews(
      messageId: messageId,
      serialized: message,
      registry: registry,
    );
  }
  return registry;
}

void registerWebChatHtmlPreviews({
  required String messageId,
  required Map<String, dynamic> serialized,
  required Map<String, WebChatHtmlPreviewSource> registry,
}) {
  void registerMarkdown(Object? raw) {
    if (raw is! String || raw.isEmpty) return;
    for (final source in webChatHtmlPreviewSources(raw)) {
      if (source.length > webChatMaxHtmlPreviewCodeUnits) continue;
      final handle = webChatHtmlPreviewHandle(messageId, source);
      registry[handle] = WebChatHtmlPreviewSource(
        messageId: messageId,
        source: source,
      );
    }
  }

  registerMarkdown(serialized['content']);
  if (serialized['translationStreaming'] != true) {
    registerMarkdown(serialized['translation']);
  }
  for (final raw
      in serialized['reasoning'] as List<dynamic>? ?? const <dynamic>[]) {
    if (raw is Map && raw['loading'] != true) registerMarkdown(raw['text']);
  }
  for (final raw
      in serialized['tools'] as List<dynamic>? ?? const <dynamic>[]) {
    if (raw is Map && raw['loading'] != true) {
      registerMarkdown(raw['content']);
    }
  }
}

void replaceWebChatHtmlPreviews({
  required String messageId,
  required Map<String, dynamic> serialized,
  required Map<String, WebChatHtmlPreviewSource> registry,
}) {
  registry.removeWhere((_, entry) => entry.messageId == messageId);
  registerWebChatHtmlPreviews(
    messageId: messageId,
    serialized: serialized,
    registry: registry,
  );
}

Iterable<String> webChatHtmlPreviewSources(String markdown) sync* {
  final normalized = markdown.replaceAll(RegExp(r'\r\n?'), '\n');
  final lines = normalized.split('\n');
  final openingPattern = RegExp(r'^( {0,3})((`{3,})|(~{3,}))[ \t]*(.*)$');
  for (var index = 0; index < lines.length; index++) {
    final opening = openingPattern.firstMatch(lines[index]);
    if (opening == null) continue;
    final indent = opening.group(1)!.length;
    final fence = opening.group(2)!;
    final marker = fence[0];
    final info = (opening.group(5) ?? '').trim();
    if (marker == '`' && info.contains('`')) continue;
    final language = info.isEmpty
        ? ''
        : info.split(RegExp(r'\s+')).first.toLowerCase();
    final code = <String>[];
    final closingPattern = RegExp(
      '^ {0,3}${RegExp.escape(marker)}{${fence.length},}[ \\t]*\$',
    );
    var cursor = index + 1;
    while (cursor < lines.length && !closingPattern.hasMatch(lines[cursor])) {
      final line = lines[cursor];
      var removed = 0;
      while (removed < indent &&
          removed < line.length &&
          line.codeUnitAt(removed) == 0x20) {
        removed++;
      }
      code.add(line.substring(removed));
      cursor++;
    }
    index = cursor < lines.length ? cursor : lines.length;
    if (language == 'html') {
      yield normalizeWebChatHtmlPreviewSource(code.join('\n'));
    }
  }
}

class WebChatSnapshotBuilder {
  const WebChatSnapshotBuilder();

  Map<String, dynamic> build({
    required String renderSessionId,
    required String conversationId,
    required int renderRevision,
    required int actionEpoch,
    required List<ChatMessage> messages,
    required Map<String, List<ChatMessage>> byGroup,
    required Map<String, int> versionSelections,
    required Map<String, stream_ctrl.ReasoningData> reasoning,
    required Map<String, List<stream_ctrl.ReasoningSegmentData>>
    reasoningSegments,
    required Map<String, stream_ctrl.ContentSplitData> contentSplits,
    required Map<String, List<ToolUIPart>> toolParts,
    required Set<String> selectedItems,
    required bool selecting,
    required int truncCollapsedIndex,
    required List<String> suggestions,
    required bool hasMoreBefore,
    required bool hasMoreAfter,
    required Map<String, String> strings,
    required Map<String, String> theme,
    Map<String, dynamic> appearance = const <String, dynamic>{},
    required Map<String, dynamic> user,
    required Map<String, dynamic> display,
    required double topContentPadding,
    required double bottomContentPadding,
    required Assistant? assistant,
    required double fontScale,
    required bool canStartMultiAI,
    required bool autoCollapseThinking,
    Map<String, dynamic>? initialViewportAnchor,
    String locale = 'en',
    String textDirection = 'ltr',
    Map<String, String> remoteMediaHandles = const <String, String>{},
    Set<String> liveTranslationMessageIds = const <String>{},
  }) {
    final snapshotDisplay = <String, dynamic>{
      ...display,
      'contentInsets': <String, double>{
        'top': _contentInset(topContentPadding),
        'bottom': _contentInset(bottomContentPadding),
      },
    };
    return <String, dynamic>{
      'type': 'snapshot',
      'protocolVersion': webChatProtocolVersion,
      'assetVersion': webChatAssetVersion,
      'renderSessionId': renderSessionId,
      'conversationId': conversationId,
      'renderRevision': renderRevision,
      'actionEpoch': actionEpoch,
      'initialViewportMode': initialViewportAnchor == null
          ? 'bottom'
          : 'anchor',
      if (initialViewportAnchor != null)
        'initialViewportAnchor': initialViewportAnchor,
      'locale': locale,
      'textDirection': textDirection,
      if (remoteMediaHandles.isNotEmpty)
        'remoteMediaHandles': remoteMediaHandles,
      'messages': <Map<String, dynamic>>[
        for (var index = 0; index < messages.length; index++)
          _message(
            messages[index],
            index: index,
            byGroup: byGroup,
            versionSelections: versionSelections,
            reasoning: reasoning[messages[index].id],
            reasoningSegments: reasoningSegments[messages[index].id],
            contentSplit: contentSplits[messages[index].id],
            toolParts: toolParts[messages[index].id],
            selected: selectedItems.contains(messages[index].id),
            selecting: selecting,
            showContextDivider:
                truncCollapsedIndex >= 0 && index == truncCollapsedIndex,
            assistant: assistant,
            display: snapshotDisplay,
            autoCollapseThinking: autoCollapseThinking,
            translationStreaming: liveTranslationMessageIds.contains(
              messages[index].id,
            ),
          ),
      ],
      'suggestions': suggestions,
      'hasMoreBefore': hasMoreBefore,
      'hasMoreAfter': hasMoreAfter,
      'strings': strings,
      'theme': theme,
      'appearance': _appearance(appearance),
      'user': user,
      'display': snapshotDisplay,
      'fontScale': fontScale,
      'canStartMultiAI': canStartMultiAI,
      'assistant': <String, dynamic>{
        'name': assistant?.name ?? '',
        'avatar': _assistantAvatarReference(assistant?.avatar),
        'avatarLabel': _assistantAvatarLabel(assistant?.avatar),
        'background': _safeMediaReference(assistant?.background),
        'useAvatar': assistant?.useAssistantAvatar ?? false,
        'useName': assistant?.useAssistantName ?? false,
      },
    };
  }

  double _contentInset(double value) =>
      value.isFinite && value >= 0 ? value : 0;

  Map<String, dynamic> _appearance(Map<String, dynamic> source) {
    const surfaces = <String>{'userBubble', 'assistantBubble', 'processCard'};
    const colorFields = <String>{
      'backgroundColor',
      'textColor',
      'accentColor',
      'borderColor',
    };
    const ranges = <String, (double, double)>{
      'borderWidth': (0, 4),
      'cornerRadius': (0, 48),
      'paddingHorizontal': (0, 32),
      'paddingVertical': (0, 32),
      'shadowElevation': (0, 24),
      'maxWidthPercent': (40, 100),
    };
    final colorPattern = RegExp(r'^#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?$');
    final result = <String, dynamic>{};
    for (final surfaceName in surfaces) {
      final value = source[surfaceName];
      if (value is! Map) continue;
      final surface = <String, dynamic>{};
      for (final field in colorFields) {
        if (field == 'accentColor' && surfaceName != 'processCard') continue;
        final color = value[field];
        if (color is String && colorPattern.hasMatch(color)) {
          surface[field] = color;
        }
      }
      for (final entry in ranges.entries) {
        if (entry.key == 'maxWidthPercent' && surfaceName == 'processCard') {
          continue;
        }
        final number = value[entry.key];
        if (number is num &&
            number.isFinite &&
            number >= entry.value.$1 &&
            number <= entry.value.$2) {
          surface[entry.key] = number.toDouble();
        }
      }
      if (surface.isNotEmpty) result[surfaceName] = surface;
    }
    return result;
  }

  Map<String, dynamic> _message(
    ChatMessage message, {
    required int index,
    required Map<String, List<ChatMessage>> byGroup,
    required Map<String, int> versionSelections,
    required stream_ctrl.ReasoningData? reasoning,
    required List<stream_ctrl.ReasoningSegmentData>? reasoningSegments,
    required stream_ctrl.ContentSplitData? contentSplit,
    required List<ToolUIPart>? toolParts,
    required bool selected,
    required bool selecting,
    required bool showContextDivider,
    required Assistant? assistant,
    required Map<String, dynamic> display,
    required bool autoCollapseThinking,
    required bool translationStreaming,
  }) {
    final versions = List<ChatMessage>.of(
      byGroup[message.groupId] ?? <ChatMessage>[message],
    )..sort((a, b) => a.version.compareTo(b.version));
    final selectedVersion =
        versionSelections[message.groupId] ?? message.version;
    final selectedVersionIndex = versions.indexWhere(
      (item) => item.version == selectedVersion,
    );
    final legacy = ThinkingTagParser.parseLegacyInlineBlocks(message.content);
    final rawVisualContent = message.role == 'assistant'
        ? messageVisualContent(message, assistant: assistant)
        : message.content;
    final visualContent = stripWebChatAttachmentMarkers(rawVisualContent);
    return <String, dynamic>{
      'id': message.id,
      'index': index,
      'role': message.role,
      'content': visualContent,
      'quickInstructions': message.quickInstructionInvocations
          .map((snapshot) => snapshot.title)
          .where((title) => title.trim().isNotEmpty)
          .toList(growable: false),
      'timestamp': message.timestamp.toIso8601String(),
      'timestampLabel': _webChatTimestampFormat.format(message.timestamp),
      'modelId': message.modelId,
      'providerId': message.providerId,
      'modelIcon': _modelIconReference(message),
      'modelIconMonochrome': _modelIconIsMonochrome(message),
      'tokens': message.contextTokens ?? message.totalTokens,
      'promptTokens': message.promptTokens,
      'completionTokens': message.completionTokens,
      'cachedTokens': message.cachedTokens,
      'durationMs': message.durationMs,
      'isStreaming': message.isStreaming,
      'isPreset': message.isPreset,
      'translation': message.translation == null
          ? null
          : stripWebChatAttachmentMarkers(message.translation!),
      'translationStreaming': translationStreaming,
      'reasoning': _reasoning(
        message,
        reasoning,
        reasoningSegments,
        legacy.thinkingTexts,
        autoCollapseThinking: autoCollapseThinking,
      ),
      'contentSplits': contentSplit == null
          ? null
          : <String, dynamic>{
              'offsets': contentSplit.offsets,
              'reasoningCounts': contentSplit.reasoningCounts,
              'toolCounts': contentSplit.toolCounts,
            },
      'tools': (toolParts ?? const <ToolUIPart>[])
          .map((part) {
            final serialized = part.toJson();
            if (serialized['content'] case final String content) {
              serialized['content'] = stripWebChatAttachmentMarkers(content);
            }
            return serialized;
          })
          .toList(growable: false),
      'citations': buildWebChatCitationSources(
        toolParts ?? const <ToolUIPart>[],
      ),
      'attachments': parseWebChatAttachments(message.content),
      'selected': selected,
      'selecting': selecting,
      'showContextDivider': showContextDivider,
      'groupId': message.groupId,
      'version': message.version,
      'versionCount': versions.length,
      'selectedVersion': selectedVersion,
      'versionIndex': selectedVersionIndex < 0 ? 0 : selectedVersionIndex,
      'actions': _primaryActions(message, display),
    };
  }

  List<String> _primaryActions(
    ChatMessage message,
    Map<String, dynamic> display,
  ) {
    if (message.role == 'user') {
      if (display['showUserMessageActions'] == false) return const <String>[];
      return const <String>['copy', 'resend', 'edit', 'more'];
    }
    if (message.isStreaming) return const <String>[];
    return const <String>['copy', 'regenerate', 'speak', 'translate', 'more'];
  }

  List<Map<String, dynamic>> _reasoning(
    ChatMessage message,
    stream_ctrl.ReasoningData? live,
    List<stream_ctrl.ReasoningSegmentData>? liveSegments,
    List<String> legacyThinking, {
    required bool autoCollapseThinking,
  }) {
    if (liveSegments != null && liveSegments.isNotEmpty) {
      return liveSegments
          .asMap()
          .entries
          .map(
            (entry) => <String, dynamic>{
              'kind': 'segment',
              'index': entry.key,
              'key': _reasoningKey(message.id, 'segment', entry.key),
              'text': stripWebChatAttachmentMarkers(entry.value.text),
              'expanded': entry.value.expanded,
              'loading': entry.value.finishedAt == null && message.isStreaming,
              'startAt': entry.value.startAt?.toIso8601String(),
              'finishedAt': entry.value.finishedAt?.toIso8601String(),
              'toolStartIndex': entry.value.toolStartIndex,
            },
          )
          .toList(growable: false);
    }
    final raw = message.reasoningSegmentsJson;
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        final segments = decoded is Map ? decoded['segments'] : decoded;
        if (segments is List) {
          return segments
              .whereType<Map>()
              .toList(growable: false)
              .asMap()
              .entries
              .map(
                (entry) => <String, dynamic>{
                  'kind': 'segment',
                  'index': entry.key,
                  'key': _reasoningKey(message.id, 'segment', entry.key),
                  'text': stripWebChatAttachmentMarkers(
                    entry.value['text']?.toString() ?? '',
                  ),
                  'expanded': entry.value['expanded'] is bool
                      ? entry.value['expanded']
                      : !autoCollapseThinking,
                  'loading': false,
                  'startAt': entry.value['startAt']?.toString(),
                  'finishedAt': entry.value['finishedAt']?.toString(),
                  'toolStartIndex':
                      (entry.value['toolStartIndex'] as num?)?.toInt() ?? 0,
                },
              )
              .toList(growable: false);
        }
      } catch (error) {
        debugPrint(
          'WebChatSnapshotBuilder: malformed reasoning payload '
          '(${error.runtimeType})',
        );
        // The legacy text below remains authoritative for malformed old rows.
      }
    }
    final text = live?.text ?? message.reasoningText;
    if (text != null && text.isNotEmpty) {
      return <Map<String, dynamic>>[
        <String, dynamic>{
          'kind': 'single',
          'index': 0,
          'key': _reasoningKey(message.id, 'single', 0),
          'text': stripWebChatAttachmentMarkers(text),
          'expanded': live?.expanded ?? !autoCollapseThinking,
          'loading': message.isStreaming && live?.finishedAt == null,
          'startAt': (live?.startAt ?? message.reasoningStartAt)
              ?.toIso8601String(),
          'finishedAt': (live?.finishedAt ?? message.reasoningFinishedAt)
              ?.toIso8601String(),
          'toolStartIndex': 0,
        },
      ];
    }
    return legacyThinking
        .asMap()
        .entries
        .map(
          (entry) => <String, dynamic>{
            'kind': 'legacy',
            'index': entry.key,
            'key': _reasoningKey(message.id, 'legacy', entry.key),
            'text': stripWebChatAttachmentMarkers(entry.value),
            'expanded': !autoCollapseThinking,
            'loading': false,
            'startAt': null,
            'finishedAt': null,
            'toolStartIndex': 0,
          },
        )
        .toList(growable: false);
  }
}

String _reasoningKey(String messageId, String kind, int index) =>
    '$messageId:reasoning:$kind:$index';

String? _modelIconAsset(ChatMessage message) {
  final modelId = message.modelId?.trim();
  final providerId = message.providerId?.trim();
  if (modelId != null && modelId.isNotEmpty) {
    final asset = BrandAssets.assetForName(modelId);
    if (asset != null) return asset;
  }
  if (providerId != null && providerId.isNotEmpty) {
    return BrandAssets.assetForName(providerId);
  }
  return null;
}

String? _modelIconReference(ChatMessage message) {
  final asset = _modelIconAsset(message);
  return asset == null ? null : webChatBundledAssetHandle(asset);
}

bool _modelIconIsMonochrome(ChatMessage message) {
  final asset = _modelIconAsset(message);
  if (asset == null) return false;
  return !asset.contains('-color.');
}

List<Map<String, dynamic>> parseWebChatAttachments(String content) {
  final attachments = <Map<String, dynamic>>[];
  final imagePattern = RegExp(r'\[image:([^\]]+)\]');
  for (final match in imagePattern.allMatches(content)) {
    final reference = _safeMediaReference(match.group(1));
    if (reference != null) {
      attachments.add(<String, dynamic>{
        'kind': 'image',
        'reference': reference,
      });
    }
  }
  final filePattern = RegExp(r'\[file:([^|\]]+)\|([^|\]]*)\|([^\]]*)\]');
  for (final match in filePattern.allMatches(content)) {
    final reference = _safeMediaReference(match.group(1));
    if (reference != null) {
      attachments.add(<String, dynamic>{
        'kind': 'file',
        'reference': reference,
        'name': match.group(2) ?? '',
        'mime': match.group(3) ?? '',
      });
    }
  }
  return attachments;
}

String? _safeMediaReference(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final lower = trimmed.toLowerCase();
  if (lower.startsWith('data:') ||
      trimmed.startsWith('#') ||
      lower.startsWith('https://')) {
    return trimmed;
  }
  if (lower.startsWith('http://')) return webChatRemoteMediaHandle(trimmed);
  // Local paths never cross the Web bridge. A later media request must be
  // validated and fulfilled by Dart for this opaque handle.
  return webChatMediaHandle(trimmed);
}

String webChatMediaHandle(String path) =>
    'local:${sha256.convert(utf8.encode(path)).toString()}';

String webChatBundledAssetHandle(String assetPath) =>
    'asset:${sha256.convert(utf8.encode(assetPath)).toString()}';

String webChatRemoteMediaHandle(String url) =>
    'remote:${sha256.convert(utf8.encode(url)).toString()}';

enum WebChatMediaSourceKind { localFile, bundledAsset, remoteImage }

/// App- or code-font face handed to the web chat shell.
///
/// [family] is the CSS family name the shell should prefer. When [path] is
/// set, the shell must load the actual font bytes through the opaque media
/// handle ([handle]) and register them under [family]; raw paths never cross
/// the Web bridge (same rule as media references). When [path] is absent the
/// family is passed through as plain CSS (system-installed or Google fonts
/// that the shell may resolve natively).
class WebChatFontFace {
  const WebChatFontFace({required this.family, this.path});

  /// Fixed face names the shell registers under via @font-face.
  static const String appFaceFamily = 'Cuplivo WebApp Font';
  static const String codeFaceFamily = 'Cuplivo WebCode Font';

  final String family;
  final String? path;

  String? get handle => path == null ? null : webChatMediaHandle(path!);

  Map<String, dynamic> toDisplayJson() => <String, dynamic>{
    'family': family,
    if (handle != null) 'handle': handle,
  };

  WebChatMediaSource? toMediaSource() => path == null
      ? null
      : WebChatMediaSource(
          kind: WebChatMediaSourceKind.localFile,
          value: path!,
        );
}

class WebChatMediaSource {
  const WebChatMediaSource({
    required this.kind,
    required this.value,
    this.messageIds = const <String>{},
  });

  final WebChatMediaSourceKind kind;
  final String value;
  final Set<String> messageIds;
}

Map<String, dynamic> buildWebChatUserSnapshot({
  required String name,
  String? avatarType,
  String? avatarValue,
}) {
  final value = avatarValue?.trim();
  return <String, dynamic>{
    'name': name,
    'avatarType': avatarType,
    'avatar': switch (avatarType) {
      'url' || 'file' => _safeMediaReference(value),
      _ => null,
    },
    'avatarLabel': avatarType == 'emoji' ? value : null,
  };
}

Map<String, WebChatMediaSource> buildWebChatMediaRegistry(
  List<ChatMessage> messages, {
  Assistant? assistant,
  String? userAvatarType,
  String? userAvatarValue,
  Map<String, List<ToolUIPart>> toolParts = const <String, List<ToolUIPart>>{},
}) {
  final registry = <String, WebChatMediaSource>{};
  void addRemote(String? url, {String? messageId}) {
    final value = url?.trim();
    final lower = value?.toLowerCase();
    if (value == null ||
        (!lower!.startsWith('http://') && !lower.startsWith('https://'))) {
      return;
    }
    final handle = webChatRemoteMediaHandle(value);
    final existing = registry[handle];
    registry[handle] = WebChatMediaSource(
      kind: WebChatMediaSourceKind.remoteImage,
      value: value,
      messageIds: <String>{
        ...?existing?.messageIds,
        if (messageId != null) messageId,
      },
    );
  }

  void addFile(String? path) {
    final value = path?.trim();
    final lower = value?.toLowerCase();
    if (value == null ||
        value.isEmpty ||
        lower!.startsWith('data:') ||
        value.startsWith('#') ||
        lower.startsWith('http://') ||
        lower.startsWith('https://')) {
      return;
    }
    registry[webChatMediaHandle(value)] = WebChatMediaSource(
      kind: WebChatMediaSourceKind.localFile,
      value: value,
    );
  }

  void addAsset(String? path) {
    final value = path?.trim();
    if (value == null ||
        !value.startsWith('assets/icons/') ||
        value.contains('..') ||
        value.contains(r'\')) {
      return;
    }
    registry[webChatBundledAssetHandle(value)] = WebChatMediaSource(
      kind: WebChatMediaSourceKind.bundledAsset,
      value: value,
    );
  }

  final assistantAvatar = assistant?.avatar?.trim();
  if (assistantAvatar != null && _assistantAvatarIsMedia(assistantAvatar)) {
    final lower = assistantAvatar.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      addRemote(assistantAvatar);
    } else if (assistantAvatar.startsWith('assets/icons/')) {
      addAsset(assistantAvatar);
    } else {
      addFile(assistantAvatar);
    }
  }
  final assistantBackground = assistant?.background?.trim();
  final lowerAssistantBackground = assistantBackground?.toLowerCase();
  if (lowerAssistantBackground?.startsWith('http://') == true ||
      lowerAssistantBackground?.startsWith('https://') == true) {
    addRemote(assistant?.background);
  } else {
    addFile(assistant?.background);
  }
  if (userAvatarType == 'file') {
    addFile(userAvatarValue);
  } else if (userAvatarType == 'url') {
    addRemote(userAvatarValue);
  }
  final imagePattern = RegExp(r'\[image:([^\]]+)\]');
  final filePattern = RegExp(r'\[file:([^|\]]+)\|[^\]]*\]');
  void addRemoteImages(String? content, String messageId) {
    if (content == null || content.isEmpty) return;
    for (final url in webChatRemoteImageReferences(content)) {
      addRemote(url, messageId: messageId);
    }
  }

  for (final message in messages) {
    addAsset(_modelIconAsset(message));
    for (final match in imagePattern.allMatches(message.content)) {
      addFile(match.group(1));
    }
    for (final match in filePattern.allMatches(message.content)) {
      addFile(match.group(1));
    }
    addRemoteImages(message.content, message.id);
    addRemoteImages(message.translation, message.id);
    addRemoteImages(message.reasoningText, message.id);
    for (final part in toolParts[message.id] ?? const <ToolUIPart>[]) {
      addRemoteImages(part.content, message.id);
    }
  }
  return registry;
}

List<Map<String, dynamic>> buildWebChatCitationSources(List<ToolUIPart> parts) {
  if (parts.isEmpty) return const <Map<String, dynamic>>[];
  final sources = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (var index = parts.length - 1; index >= 0; index--) {
    final part = parts[index];
    if ((part.toolName != 'search_web' && part.toolName != 'builtin_search') ||
        (part.content?.isNotEmpty ?? false) == false) {
      continue;
    }
    try {
      final decoded = jsonDecode(part.content!);
      if (decoded is! Map) continue;
      final items = decoded['items'];
      if (items is! List) continue;
      for (final raw in items) {
        if (raw is! Map) continue;
        final item = raw.map((key, value) => MapEntry(key.toString(), value));
        final key = (item['id'] ?? item['url'] ?? '').toString();
        if (key.isNotEmpty && !seen.add(key)) continue;
        final rawIndex = item['index'];
        final sourceIndex = rawIndex is num
            ? rawIndex.toInt()
            : int.tryParse(rawIndex?.toString() ?? '') ?? sources.length + 1;
        sources.add(<String, dynamic>{
          'id': item['id']?.toString(),
          'index': sourceIndex,
          'title': (item['title'] ?? '').toString(),
          'url': (item['url'] ?? '').toString(),
          'text': (item['text'] ?? item['quote'] ?? item['snippet'] ?? '')
              .toString(),
          'sourceName':
              (item['sourceName'] ??
                      item['source_name'] ??
                      item['web_site_name'])
                  ?.toString(),
          'webSiteSource': item['webSiteSource']?.toString(),
          'publishedText': (item['publish_time'] ?? item['publishedText'])
              ?.toString(),
          'tags': item['tags'] is List ? item['tags'] : const <dynamic>[],
        });
      }
    } catch (error) {
      debugPrint(
        'WebChatSnapshotBuilder: malformed citation payload '
        '(${error.runtimeType})',
      );
    }
  }
  return sources;
}

Iterable<String> webChatRemoteImageReferences(String content) sync* {
  final seen = <String>{};
  final patterns = <RegExp>[
    RegExp(r'\[image:(https?://[^\]]+)\]', caseSensitive: false),
    RegExp(r'!\[[^\]]*\]\(\s*<?(https?://[^\s>)]+)', caseSensitive: false),
    RegExp(
      r'''<img\b[^>]*\bsrc\s*=\s*["'](https?://[^"']+)["']''',
      caseSensitive: false,
    ),
  ];
  for (final pattern in patterns) {
    for (final match in pattern.allMatches(content)) {
      final value = match.group(1)?.trim();
      if (value != null && value.isNotEmpty && seen.add(value)) yield value;
    }
  }
}

String? _assistantAvatarReference(String? value) {
  final avatar = value?.trim();
  if (avatar == null || avatar.isEmpty) return null;
  if (avatar.startsWith('assets/icons/')) {
    return webChatBundledAssetHandle(avatar);
  }
  if (_assistantAvatarIsMedia(avatar)) {
    return _safeMediaReference(avatar);
  }
  return null;
}

String? _assistantAvatarLabel(String? value) {
  final avatar = value?.trim();
  if (avatar == null || avatar.isEmpty || _assistantAvatarIsMedia(avatar)) {
    return null;
  }
  return avatar;
}

bool _assistantAvatarIsMedia(String avatar) =>
    avatar.toLowerCase().startsWith('data:') ||
    avatar.toLowerCase().startsWith('http://') ||
    avatar.toLowerCase().startsWith('https://') ||
    avatar.contains('/') ||
    avatar.contains(r'\') ||
    avatar.contains(':');

/// Localized UI strings consumed by the web chat shell. Single source shared
/// by the interactive viewport (home_page) and the PDF printer.
Map<String, String> webChatUiStrings(AppLocalizations l10n) => <String, String>{
  'timeline': l10n.webChatTimelineLabel,
  'loading': l10n.webChatLoading,
  'empty': l10n.webChatEmptyConversation,
  'user': l10n.webChatUser,
  'assistant': l10n.webChatAssistant,
  'tokens': l10n.webChatTokens,
  'code': l10n.webChatCode,
  'copyCode': l10n.webChatCopyCode,
  'expandCode': l10n.codeBlockExpandButton,
  'collapseCode': l10n.codeBlockCollapseButton,
  'htmlPreview': l10n.webChatHtmlPreview,
  'openHtmlPreview': l10n.htmlOpenFullScreenPreview,
  'thinking': l10n.chatMessageWidgetThinking,
  'reasoning': l10n.chatMessageWidgetDeepThinking,
  'collapseThinkingSteps': l10n.chainOfThoughtCollapse,
  'expandThinkingSteps': l10n.chainOfThoughtExpandSteps('{count}'),
  'toolCall': l10n.webChatToolCall,
  'toolResult': l10n.webChatToolResult,
  'translation': l10n.webChatTranslation,
  'contextDivider': l10n.homePageClearContext,
  'unsupportedBlock': l10n.webChatUnsupportedBlock,
  'copy': l10n.chatMessageWidgetCopyAsMarkdown,
  'edit': l10n.messageMoreSheetEdit,
  'resend': l10n.chatMessageWidgetResendTooltip,
  'regenerate': l10n.chatMessageWidgetRegenerateTooltip,
  'quote': l10n.chatMessageWidgetQuote,
  'translate': l10n.chatMessageWidgetTranslateTooltip,
  'speak': l10n.chatMessageWidgetSpeakTooltip,
  'stop': l10n.chatMessageWidgetStopTooltip,
  'more': l10n.chatMessageWidgetMoreTooltip,
  'share': l10n.messageMoreSheetShare,
  'fork': l10n.messageMoreSheetCreateBranch,
  'select': l10n.messageMoreSheetSelectMessages,
  'delete': l10n.messageMoreSheetDelete,
  'multiAI': l10n.messageMoreSheetMultiAI,
  'approve': l10n.toolApprovalApprove,
  'deny': l10n.toolApprovalDeny,
  'submit': l10n.askUserCardSubmit,
  'customAnswer': l10n.askUserCardCustomHint,
  'skip': l10n.askUserCardSkip,
  'skipped': l10n.askUserCardSkipped,
  'previousVersion': l10n.webChatPreviousVersion,
  'nextVersion': l10n.webChatNextVersion,
  'sources': l10n.chatMessageWidgetSearchResultsTitle,
};

/// Theme color tokens exposed to the web shell. Shared by the interactive
/// viewport (home_page) and the PDF printer.
Map<String, String> webChatThemeColors({
  required ColorScheme colors,
  required AppSemanticColors semantic,
  required bool isDark,
  required double backgroundMaskStrength,
}) => <String, String>{
  'surface': _webCssColor(colors.surface),
  'on-surface': _webCssColor(colors.onSurface),
  'primary': _webCssColor(colors.primary),
  'on-primary': _webCssColor(colors.onPrimary),
  'secondary': _webCssColor(colors.secondary),
  'error': _webCssColor(colors.error),
  'card': _webCssColor(semantic.surfaceCard),
  'surface-fill': _webCssColor(semantic.surfaceFill),
  'code-body': _webCssColor(colors.surfaceContainer.withValues(alpha: 0.90)),
  'code-header': _webCssColor(
    colors.surfaceContainerHighest.withValues(alpha: 0.90),
  ),
  'code-border': _webCssColor(colors.outlineVariant),
  'code-header-text': _webCssColor(
    colors.onSurfaceVariant.withValues(alpha: 0.72),
  ),
  'code-action': _webCssColor(colors.onSurfaceVariant.withValues(alpha: 0.50)),
  'outline': _webCssColor(colors.outlineVariant),
  'outline-soft': _webCssColor(
    colors.outlineVariant.withValues(alpha: isDark ? 0.24 : 0.18),
  ),
  'outline-frosted': _webCssColor(
    colors.outlineVariant.withValues(alpha: 0.14),
  ),
  'outline-solid': _webCssColor(colors.outlineVariant.withValues(alpha: 0.16)),
  'user': _webCssColor(colors.primary.withValues(alpha: isDark ? 0.15 : 0.08)),
  'thinking': _webCssColor(
    colors.primaryContainer.withValues(alpha: isDark ? 0.25 : 0.30),
  ),
  'frosted': _webCssColor(
    isDark
        // Matches the shared Flutter frosted message surface.
        // color-gate: ignore
        ? const Color(0xFF1C1C1E).withValues(alpha: 0.66)
        : Colors.white.withValues(alpha: 0.66),
  ),
  'muted': _webCssColor(
    colors.onSurface.withValues(alpha: isDark ? 0.56 : 0.50),
  ),
  'model-icon-background': _webCssColor(
    colors.secondary.withValues(alpha: 0.10),
  ),
  'user-avatar-background': _webCssColor(
    colors.primary.withValues(alpha: 0.10),
  ),
  'assistant-avatar-background': _webCssColor(
    colors.primary.withValues(alpha: 0.10),
  ),
  'background-mask-top': _webCssColor(
    colors.surface.withValues(
      alpha: (0.20 * backgroundMaskStrength).clamp(0, 1),
    ),
  ),
  'background-mask-bottom': _webCssColor(
    colors.surface.withValues(
      alpha: (0.50 * backgroundMaskStrength).clamp(0, 1),
    ),
  ),
};

/// Display settings exposed to the web shell. Shared by the interactive
/// viewport (home_page) and the PDF printer; [wrapCode] and [isDark] must be
/// computed by the caller with its own platform / theme knowledge.
Map<String, dynamic> webChatDisplay(
  SettingsProvider settings, {
  required bool wrapCode,
  required bool isDark,
  required bool ttsActive,
}) => <String, dynamic>{
  'userMarkdown': settings.enableUserMarkdown,
  'assistantMarkdown': settings.enableAssistantMarkdown,
  'reasoningMarkdown': settings.enableReasoningMarkdown,
  'math': settings.enableMathRendering,
  'dollarMath': settings.enableDollarLatex,
  'wrapCode': wrapCode,
  'collapsedCodeLines': settings.autoCollapseCodeBlock
      ? settings.autoCollapseCodeBlockLines
      : null,
  'backgroundStyle': settings.chatMessageBackgroundStyle.name,
  'backgroundOwner': 'flutter',
  'isDark': isDark,
  'showUserAvatar': settings.showUserAvatar,
  'showUserName': settings.showUserName,
  'showUserTimestamp': settings.showUserTimestamp,
  'showUserMessageActions': settings.showUserMessageActions,
  'showModelIcon': settings.showModelIcon,
  'showModelName': settings.showModelName,
  'showModelTimestamp': settings.showModelTimestamp,
  'showTokenStats': settings.showTokenStats,
  'autoCollapseThinking': settings.autoCollapseThinking,
  'collapseThinkingSteps': settings.collapseThinkingSteps,
  'showToolResultSummary': settings.showToolResultSummary,
  'ttsActive': ttsActive,
};

String _webCssColor(Color color) {
  final value = color.toARGB32();
  final alpha = (value >> 24) & 0xff;
  final red = (value >> 16) & 0xff;
  final green = (value >> 8) & 0xff;
  final blue = value & 0xff;
  if (alpha == 0xff) {
    final rgb = value & 0x00ffffff;
    return '#${rgb.toRadixString(16).padLeft(6, '0')}';
  }
  return 'rgba($red, $green, $blue, ${(alpha / 255).toStringAsFixed(3)})';
}
