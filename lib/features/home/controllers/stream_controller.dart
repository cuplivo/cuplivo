import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/reasoning_payload.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/api/providers/gemini_thought_signature.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/generation_engine.dart';
import '../../../core/services/streaming_content_notifier.dart';
import '../../chat/models/tool_ui_part.dart';

export '../../../core/models/reasoning_payload.dart';
export '../../../core/services/streaming_content_notifier.dart';

/// Controller for managing streaming message generation.
///
/// This controller handles:
/// - Stream throttling to reduce UI rebuild frequency
/// - Reasoning state management (including segments)
/// - Tool UI state management
/// - Inline image sanitization during streaming
///
/// The controller is designed to work alongside ChatController and be used
/// by the home page to handle streaming generation without cluttering the UI code.
class StreamController {
  StreamController({
    required this._chatService,
    required this.onStateChanged,
    required this.getSettingsProvider,
    required this.getCurrentConversationId,
    this.onStreamTick,
  });

  final ChatService _chatService;

  /// Callback when state changes (trigger setState in the widget).
  /// NOTE: This should only be used for non-streaming state changes.
  /// For streaming content updates, use streamingContentNotifier instead.
  final VoidCallback onStateChanged;

  /// Optional callback fired during streaming updates (e.g., auto-scroll).
  final VoidCallback? onStreamTick;

  /// Lightweight notifier for streaming content updates.
  /// This avoids triggering full page rebuilds during streaming.
  final StreamingContentNotifier streamingContentNotifier =
      StreamingContentNotifier();

  /// Set of message IDs currently being streamed.
  /// Used to suppress onStateChanged calls during streaming.
  final Set<String> _activeStreamingIds = <String>{};

  /// Mark a message as actively streaming.
  /// Also creates the StreamingContentNotifier for this message so that
  /// MessageListView can detect it and use ValueListenableBuilder.
  void markStreamingStarted(String messageId) {
    _activeStreamingIds.add(messageId);
    // Pre-create notifier so MessageListView can detect streaming state
    streamingContentNotifier.getNotifier(messageId);
  }

  /// Mark a message as no longer streaming.
  void markStreamingEnded(String messageId) {
    _activeStreamingIds.remove(messageId);
  }

  /// Get current settings provider (for auto-collapse setting, etc.).
  final SettingsProvider Function() getSettingsProvider;

  /// Get current conversation ID (for checking if we should update UI).
  final String? Function() getCurrentConversationId;

  // ============================================================================
  // State Maps
  // ============================================================================

  /// Reasoning data per assistant message.
  final Map<String, ReasoningData> _reasoning = <String, ReasoningData>{};
  Map<String, ReasoningData> get reasoning => _reasoning;

  /// Reasoning segments per assistant message (for interleaved tool/thinking).
  final Map<String, List<ReasoningSegmentData>> _reasoningSegments =
      <String, List<ReasoningSegmentData>>{};
  Map<String, List<ReasoningSegmentData>> get reasoningSegments =>
      _reasoningSegments;

  /// Content/text split metadata per assistant message.
  final Map<String, ContentSplitData> _contentSplits =
      <String, ContentSplitData>{};
  Map<String, ContentSplitData> get contentSplits => _contentSplits;

  /// Tool UI parts per assistant message.
  final Map<String, List<ToolUIPart>> _toolParts = <String, List<ToolUIPart>>{};
  Map<String, List<ToolUIPart>> get toolParts => _toolParts;

  /// Gemini thought signatures per assistant message.
  final Map<String, String> _geminiThoughtSigs = <String, String>{};
  Map<String, String> get geminiThoughtSigs => _geminiThoughtSigs;

  /// Vendor reasoning details (OpenRouter-style `reasoning_details`, may carry
  /// thinking signatures) per assistant message. Persisted inside the
  /// reasoningSegmentsJson payload so they can be echoed back on later turns.
  final Map<String, dynamic> _reasoningDetails = <String, dynamic>{};
  Map<String, dynamic> get reasoningDetails => _reasoningDetails;

  /// Regex to capture Gemini thought signature comments.
  static final RegExp _geminiThoughtSigRe = RegExp(
    r'<!--\s*gemini_thought_signatures:.*?-->',
    dotAll: true,
  );

  // ============================================================================
  // Public Methods - State Access
  // ============================================================================

  /// Get reasoning data for a message.
  ReasoningData? getReasoningData(String messageId) => _reasoning[messageId];

  /// Set reasoning data for a message.
  void setReasoningData(String messageId, ReasoningData data) {
    _reasoning[messageId] = data;
  }

  /// Remove reasoning data for a message.
  void removeReasoningData(String messageId) {
    _reasoning.remove(messageId);
  }

  /// Get reasoning segments for a message.
  List<ReasoningSegmentData>? getReasoningSegments(String messageId) =>
      _reasoningSegments[messageId];

  /// Set reasoning segments for a message.
  void setReasoningSegments(
    String messageId,
    List<ReasoningSegmentData> segments,
  ) {
    _reasoningSegments[messageId] = segments;
  }

  /// Remove reasoning segments for a message.
  void removeReasoningSegments(String messageId) {
    _reasoningSegments.remove(messageId);
  }

  /// Get content split metadata for a message.
  ContentSplitData? getContentSplitData(String messageId) =>
      _contentSplits[messageId];

  /// Set content split metadata for a message.
  void setContentSplitData(String messageId, ContentSplitData data) {
    _contentSplits[messageId] = data;
  }

  /// Remove content split metadata for a message.
  void removeContentSplitData(String messageId) {
    _contentSplits.remove(messageId);
  }

  /// Get tool parts for a message.
  List<ToolUIPart>? getToolParts(String messageId) => _toolParts[messageId];

  /// Set tool parts for a message.
  void setToolParts(String messageId, List<ToolUIPart> parts) {
    _toolParts[messageId] = parts;
  }

  /// Remove tool parts for a message.
  void removeToolParts(String messageId) {
    _toolParts.remove(messageId);
  }

  // ============================================================================
  // Engine Snapshot Bridge (ADR-0034)
  // ============================================================================

  /// Mirrors one [GenerationSlotUiState] snapshot into the page UI state maps
  /// (reasoning / segments / splits / tool parts / gemini signature). Called
  /// per chunk and at settle by the engine adapters (chat_actions,
  /// GroupChatSlotRunner) — the engine owns the state, the page renders it.
  void syncEngineUiState(String messageId, GenerationSlotUiState state) {
    if (state.reasoningText.isNotEmpty ||
        state.reasoningStartAt != null ||
        state.reasoningFinishedAt != null) {
      final existing = _reasoning[messageId];
      final rd = ReasoningData()
        ..text = state.reasoningText
        ..startAt = state.reasoningStartAt
        ..finishedAt = state.reasoningFinishedAt
        ..expanded = existing?.expanded ?? false;
      _reasoning[messageId] = rd;
    }
    if (state.segments.isNotEmpty) {
      _reasoningSegments[messageId] = List<ReasoningSegmentData>.of(
        state.segments,
      );
    }
    if (state.contentSplitOffsets.isNotEmpty ||
        state.reasoningCountAtSplit.isNotEmpty ||
        state.toolCountAtSplit.isNotEmpty) {
      _contentSplits[messageId] = _normalizeContentSplitData(
        ContentSplitData(
          offsets: List<int>.of(state.contentSplitOffsets),
          reasoningCounts: List<int>.of(state.reasoningCountAtSplit),
          toolCounts: List<int>.of(state.toolCountAtSplit),
        ),
      );
    }
    if (state.toolEvents.isNotEmpty) {
      _toolParts[messageId] = _toolPartsFromEvents(
        dedupeToolEvents(state.toolEvents),
      );
    }
    if (state.geminiThoughtSig != null && state.geminiThoughtSig!.isNotEmpty) {
      _geminiThoughtSigs[messageId] = state.geminiThoughtSig!;
    }
    // Auto-retry countdown is boundary-sensitive: publish even when null so a
    // cleared countdown reaches the bubble. No-op when nobody is listening.
    streamingContentNotifier.updateRetryStatus(messageId, state.retryStatus);
  }

  /// Maps persisted tool events (id/name/arguments/content/metadata) to UI
  /// tool parts. Shared by [restoreMessageUiState] and
  /// [syncEngineUiState].
  static List<ToolUIPart> _toolPartsFromEvents(
    List<Map<String, dynamic>> events,
  ) {
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
            loading: !(e['content']?.toString().isNotEmpty == true),
          ),
        )
        .toList();
  }

  /// Clear all state for a message (reasoning, segments, tools).
  void clearMessageState(String messageId) {
    _reasoning.remove(messageId);
    _reasoningSegments.remove(messageId);
    _contentSplits.remove(messageId);
    _toolParts.remove(messageId);
    _geminiThoughtSigs.remove(messageId);
    _reasoningDetails.remove(messageId);
  }

  /// Clear all state maps (for new conversation).
  void clearAllState() {
    _reasoning.clear();
    _reasoningSegments.clear();
    _contentSplits.clear();
    _toolParts.clear();
    _geminiThoughtSigs.clear();
    _reasoningDetails.clear();
    streamingContentNotifier.clear();
  }

  // ============================================================================
  // Gemini Thought Signature Handling
  // ============================================================================

  /// Capture and strip Gemini thought signature from content; persists the
  /// normalized payload (bare JSON) so follow-up API calls in the conversation
  /// can echo it without leaking the comment into message text.
  String captureGeminiThoughtSignature(String content, String messageId) {
    if (content.isEmpty) return content;
    final m = _geminiThoughtSigRe.firstMatch(content);
    if (m != null) {
      final sig = m.group(0) ?? '';
      if (sig.isNotEmpty) {
        final meta = decodeGeminiThoughtSignature(sig, cleanedText: '');
        final payload = meta == null
            ? ''
            : encodeGeminiThoughtSignature(
                textKey: meta.textKey,
                textValue: meta.textValue,
                imageSigs: meta.images,
              );
        if (payload.isNotEmpty) {
          if (_geminiThoughtSigs[messageId] != payload) {
            _geminiThoughtSigs[messageId] = payload;
            unawaited(
              _chatService.setGeminiThoughtSignature(messageId, payload),
            );
          }
        }
      }
      content = content.replaceAll(_geminiThoughtSigRe, '').trimRight();
    }
    return content;
  }

  /// The Gemini thought signature payload for [message], or null. Reads the
  /// in-memory capture first, then the persisted row. Legacy comment shells
  /// are decoded at the Google history builder, so both formats are
  /// faithfully returned as-is.
  String? geminiThoughtSignatureForApi(ChatMessage message) {
    final sig = _geminiThoughtSigs[message.id];
    if (sig != null && sig.isNotEmpty) return sig;
    return _chatService.getGeminiThoughtSignature(message.id);
  }

  /// Clear Gemini thought signatures map.
  void clearGeminiThoughtSigs() {
    _geminiThoughtSigs.clear();
  }

  // ============================================================================
  // Reasoning Serialization
  // ============================================================================

  /// Serialize reasoning segments to JSON string.
  String serializeReasoningSegments(List<ReasoningSegmentData> segments) {
    final list = segments
        .map(
          (s) => {
            'text': s.text,
            'startAt': s.startAt?.toIso8601String(),
            'finishedAt': s.finishedAt?.toIso8601String(),
            'expanded': s.expanded,
            'toolStartIndex': s.toolStartIndex,
          },
        )
        .toList();
    return _encodeJson(list);
  }

  /// Extract persisted vendor reasoning details (if any) from a serialized
  /// reasoningSegmentsJson payload.
  dynamic deserializeReasoningDetails(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      final decoded = _decodeJson(json);
      if (decoded is! Map<String, dynamic>) return null;
      final details = decoded['reasoningDetails'];
      if (details is List && details.isNotEmpty) return details;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Deserialize reasoning segments from JSON string.
  List<ReasoningSegmentData> deserializeReasoningSegments(String? json) {
    if (json == null || json.isEmpty) return [];
    try {
      final decoded = _decodeJson(json);
      final list = decoded is Map<String, dynamic>
          ? (decoded['segments'] as List? ?? const [])
          : decoded as List;
      return list.map((item) {
        final s = ReasoningSegmentData();
        s.text = item['text'] ?? '';
        s.startAt = item['startAt'] != null
            ? DateTime.parse(item['startAt'])
            : null;
        final parsedFinished = item['finishedAt'] != null
            ? DateTime.parse(item['finishedAt'])
            : null;
        // If finishedAt is null but startAt exists, the stream was interrupted;
        // treat segment as finished to avoid an infinite timer on restore.
        s.finishedAt = parsedFinished ?? s.startAt;
        s.expanded = item['expanded'] ?? false;
        s.toolStartIndex = (item['toolStartIndex'] as int?) ?? 0;
        return s;
      }).toList();
    } catch (_) {
      return [];
    }
  }

  ContentSplitData? deserializeContentSplits(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      final decoded = _decodeJson(json);
      if (decoded is! Map<String, dynamic>) return null;
      final contentSplits = (decoded['contentSplits'] as Map?)
          ?.cast<String, dynamic>();
      if (contentSplits == null) return null;
      return _normalizeContentSplitData(
        ContentSplitData(
          offsets: (contentSplits['offsets'] as List? ?? const [])
              .map((item) => item as int)
              .toList(),
          reasoningCounts:
              (contentSplits['reasoningCounts'] as List? ?? const [])
                  .map((item) => item as int)
                  .toList(),
          toolCounts: (contentSplits['toolCounts'] as List? ?? const [])
              .map((item) => item as int)
              .toList(),
        ),
      );
    } catch (_) {
      return null;
    }
  }

  ContentSplitData _normalizeContentSplitData(ContentSplitData data) {
    final length = math.min(
      data.offsets.length,
      math.min(data.reasoningCounts.length, data.toolCounts.length),
    );
    return ContentSplitData(
      offsets: List<int>.of(data.offsets.take(length)),
      reasoningCounts: List<int>.of(data.reasoningCounts.take(length)),
      toolCounts: List<int>.of(data.toolCounts.take(length)),
    );
  }

  // Simple JSON encode/decode helpers, re-exported from the shared reasoning
  // payload module (lib/core/models/reasoning_payload.dart).
  String _encodeJson(dynamic obj) {
    return encodeReasoningJson(obj);
  }

  dynamic _decodeJson(String json) {
    return decodeReasoningJson(json);
  }

  // ============================================================================
  // Tool Parts Deduplication
  // ============================================================================

  /// Deduplicate tool UI parts by id or by name+args when id is empty.
  List<ToolUIPart> dedupeToolPartsList(List<ToolUIPart> parts) {
    final completedIds = <String>{
      for (final p in parts)
        if (p.id.trim().isNotEmpty && _hasToolContent(p.content)) p.id.trim(),
    };
    final completedNoIdBases = <String>{
      for (final p in parts)
        if (p.id.trim().isEmpty && _hasToolContent(p.content))
          _toolDedupeBase(p.toolName, p.arguments),
    };
    final indexByKey = <String, int>{};
    final out = <ToolUIPart>[];
    for (final p in parts) {
      final id = p.id.trim();
      if (!_hasToolContent(p.content) &&
          ((id.isNotEmpty && completedIds.contains(id)) ||
              (id.isEmpty &&
                  completedNoIdBases.contains(
                    _toolDedupeBase(p.toolName, p.arguments),
                  )))) {
        continue;
      }
      final key = _toolDedupeKey(
        id: p.id,
        name: p.toolName,
        arguments: p.arguments,
        content: p.content,
      );
      final existingIndex = indexByKey[key];
      if (existingIndex != null) {
        if (id.isNotEmpty) out[existingIndex] = p;
        continue;
      }
      indexByKey[key] = out.length;
      out.add(p);
    }
    return out;
  }

  String _toolDedupeBase(String name, Map<String, dynamic> arguments) {
    return 'name:$name|args:${_encodeJson(arguments)}';
  }

  bool _hasToolContent(String? content) => content?.trim().isNotEmpty == true;

  String _toolDedupeKey({
    required String id,
    required String name,
    required Map<String, dynamic> arguments,
    String? content,
  }) {
    final trimmedId = id.trim();
    if (trimmedId.isNotEmpty) return 'id:$trimmedId';

    final base = _toolDedupeBase(name, arguments);
    final trimmedContent = content?.trim();
    if (trimmedContent == null || trimmedContent.isEmpty) return base;
    return '$base|content:$trimmedContent';
  }

  /// Remove the streaming content notifier for a message.
  ///
  /// This must be called AFTER onMessagesChanged to avoid a race where
  /// the UI rebuilds without the notifier and falls back to stale
  /// message.content (which may still be empty).
  /// Idempotent: safe to call multiple times.
  void removeStreamingNotifier(String messageId) {
    streamingContentNotifier.removeNotifier(messageId);
  }

  // ============================================================================
  // Restoration from Database
  // ============================================================================

  /// Restore UI state for a message from its persisted data.
  ///
  /// STREAMING messages are skipped entirely: their live state (reasoning
  /// segments, tool parts, signatures) is owned by the in-flight pipeline and
  /// survives conversation switches — the maps are never cleared on switch.
  /// Restoring them here would overwrite the live entry with a snapshot whose
  /// `reasoningFinishedAt` is null mid-reasoning, synthesizing a bogus
  /// `finishedAt = startAt` (thinking card stuck at 0.0s) and a forced
  /// collapse, and the still-running pipeline would then persist that bogus
  /// timestamp into the DB row permanently.
  void restoreMessageUiState(
    ChatMessage message, {
    required List<Map<String, dynamic>> Function(String messageId)
    getToolEventsFromDb,
    required String? Function(String messageId) getGeminiThoughtSigFromDb,
  }) {
    if (message.role != 'assistant') return;
    if (message.isStreaming) return;

    final messageId = message.id;

    // Restore Gemini thought signature
    final storedSig = getGeminiThoughtSigFromDb(messageId);
    if (storedSig != null && storedSig.isNotEmpty) {
      _geminiThoughtSigs[messageId] = storedSig;
    }

    // Restore reasoning state
    final txt = message.reasoningText ?? '';
    if (txt.isNotEmpty ||
        message.reasoningStartAt != null ||
        message.reasoningFinishedAt != null) {
      final rd = ReasoningData();
      rd.text = txt;
      rd.startAt = message.reasoningStartAt;
      // If finishedAt is null but startAt exists, the stream was interrupted
      // (e.g. app force-quit mid-reasoning); treat reasoning as finished to
      // avoid an infinite timer.
      rd.finishedAt = message.reasoningFinishedAt ?? message.reasoningStartAt;
      rd.expanded = false;
      _reasoning[messageId] = rd;
    }

    // Restore tool events
    try {
      final events = dedupeToolEvents(getToolEventsFromDb(messageId));
      if (events.isNotEmpty) {
        _toolParts[messageId] = _toolPartsFromEvents(events);
      }
    } catch (_) {}

    // Restore reasoning segments
    final segments = deserializeReasoningSegments(
      message.reasoningSegmentsJson,
    );
    if (segments.isNotEmpty) {
      _reasoningSegments[messageId] = segments;
    }
    final contentSplits = deserializeContentSplits(
      message.reasoningSegmentsJson,
    );
    if (contentSplits != null) {
      _contentSplits[messageId] = contentSplits;
    }

    // Restore vendor reasoning details (thinking signatures) for API replays
    final details = deserializeReasoningDetails(message.reasoningSegmentsJson);
    if (details != null) {
      _reasoningDetails[messageId] = details;
    }
  }

  // ============================================================================
  // Disposal
  // ============================================================================

  /// Dispose of all resources.
  void dispose() {
    streamingContentNotifier.dispose();
  }
}

// ============================================================================
// Data Classes
// ============================================================================

// ReasoningData / ReasoningSegmentData / ContentSplitData and
// serializeReasoningSegmentsWithSplits live in the shared reasoning payload
// module (lib/core/models/reasoning_payload.dart) — re-exported by this file
// so the page pipeline and the GenerationEngine persist ONE payload format.

/// Context object for message generation.
class GenerationContext {
  GenerationContext({
    required this.assistantMessage,
    required this.apiMessages,
    required this.userMediaPaths,
    required this.allowImagesApiRouting,
    required this.providerKey,
    required this.modelId,
    required this.assistant,
    required this.settings,
    required this.config,
    required this.toolDefs,
    this.onToolCall,
    this.extraHeaders,
    this.extraBody,
    required this.supportsReasoning,
    required this.enableReasoning,
    required this.streamOutput,
    this.ocrActive = false,
    this.generateTitleOnFinish = true,
  });

  final ChatMessage assistantMessage;
  final List<Map<String, dynamic>> apiMessages;
  final List<String> userMediaPaths;
  final bool allowImagesApiRouting;
  final String providerKey;
  final String modelId;
  final dynamic assistant;
  final SettingsProvider settings;
  final ProviderConfig config;
  final List<Map<String, dynamic>> toolDefs;
  final ToolCallHandler? onToolCall;
  final Map<String, String>? extraHeaders;
  final Map<String, dynamic>? extraBody;
  final bool supportsReasoning;
  final bool enableReasoning;
  final bool streamOutput;
  final bool ocrActive;
  final bool generateTitleOnFinish;
}
