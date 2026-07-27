import 'package:uuid/uuid.dart';

/// A message in a multi-assistant group chat timeline.
///
/// [speakerAssistantId] is null for user messages. Tool events reuse
/// `tool_event_rows` keyed by this message's UUID (globally unique).
///
/// copyWith uses the **sentinel** pattern (same as [ChatMessage]) so
/// `copyWith(field: null)` clears nullable fields.
class GroupChatMessage {
  final String id;
  final String groupId;

  /// null = user
  final String? speakerAssistantId;

  /// 'user' | 'assistant'
  final String role;
  final String content;
  final DateTime timestamp;

  /// Authoritative order within the group timeline.
  final int messageOrder;

  final String? modelId;
  final String? providerId;
  final String? reasoningText;
  final DateTime? reasoningStartAt;
  final DateTime? reasoningFinishedAt;
  final String? reasoningSegmentsJson;
  final bool isStreaming;
  final int? totalTokens;
  final int? promptTokens;
  final int? completionTokens;
  final int? cachedTokens;
  final int? durationMs;
  final int version;

  factory GroupChatMessage({
    String? id,
    required String groupId,
    String? speakerAssistantId,
    required String role,
    required String content,
    DateTime? timestamp,
    int messageOrder = 0,
    String? modelId,
    String? providerId,
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    String? reasoningSegmentsJson,
    bool isStreaming = false,
    int? totalTokens,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    int? durationMs,
    int version = 0,
  }) {
    return GroupChatMessage._(
      id: id ?? const Uuid().v4(),
      groupId: groupId,
      speakerAssistantId: speakerAssistantId,
      role: role,
      content: content,
      timestamp: timestamp ?? DateTime.now(),
      messageOrder: messageOrder,
      modelId: modelId,
      providerId: providerId,
      reasoningText: reasoningText,
      reasoningStartAt: reasoningStartAt,
      reasoningFinishedAt: reasoningFinishedAt,
      reasoningSegmentsJson: reasoningSegmentsJson,
      isStreaming: isStreaming,
      totalTokens: totalTokens,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      cachedTokens: cachedTokens,
      durationMs: durationMs,
      version: version,
    );
  }

  GroupChatMessage._({
    required this.id,
    required this.groupId,
    this.speakerAssistantId,
    required this.role,
    required this.content,
    required this.timestamp,
    required this.messageOrder,
    this.modelId,
    this.providerId,
    this.reasoningText,
    this.reasoningStartAt,
    this.reasoningFinishedAt,
    this.reasoningSegmentsJson,
    this.isStreaming = false,
    this.totalTokens,
    this.promptTokens,
    this.completionTokens,
    this.cachedTokens,
    this.durationMs,
    this.version = 0,
  });

  static const sentinel = Object();

  GroupChatMessage copyWith({
    Object? id = sentinel,
    Object? groupId = sentinel,
    Object? speakerAssistantId = sentinel,
    Object? role = sentinel,
    Object? content = sentinel,
    Object? timestamp = sentinel,
    Object? messageOrder = sentinel,
    Object? modelId = sentinel,
    Object? providerId = sentinel,
    Object? reasoningText = sentinel,
    Object? reasoningStartAt = sentinel,
    Object? reasoningFinishedAt = sentinel,
    Object? reasoningSegmentsJson = sentinel,
    Object? isStreaming = sentinel,
    Object? totalTokens = sentinel,
    Object? promptTokens = sentinel,
    Object? completionTokens = sentinel,
    Object? cachedTokens = sentinel,
    Object? durationMs = sentinel,
    Object? version = sentinel,
  }) {
    return GroupChatMessage(
      id: identical(id, sentinel) ? this.id : id as String,
      groupId: identical(groupId, sentinel) ? this.groupId : groupId as String,
      speakerAssistantId: identical(speakerAssistantId, sentinel)
          ? this.speakerAssistantId
          : speakerAssistantId as String?,
      role: identical(role, sentinel) ? this.role : role as String,
      content: identical(content, sentinel) ? this.content : content as String,
      timestamp: identical(timestamp, sentinel)
          ? this.timestamp
          : timestamp as DateTime,
      messageOrder: identical(messageOrder, sentinel)
          ? this.messageOrder
          : messageOrder as int,
      modelId: identical(modelId, sentinel) ? this.modelId : modelId as String?,
      providerId: identical(providerId, sentinel)
          ? this.providerId
          : providerId as String?,
      reasoningText: identical(reasoningText, sentinel)
          ? this.reasoningText
          : reasoningText as String?,
      reasoningStartAt: identical(reasoningStartAt, sentinel)
          ? this.reasoningStartAt
          : reasoningStartAt as DateTime?,
      reasoningFinishedAt: identical(reasoningFinishedAt, sentinel)
          ? this.reasoningFinishedAt
          : reasoningFinishedAt as DateTime?,
      reasoningSegmentsJson: identical(reasoningSegmentsJson, sentinel)
          ? this.reasoningSegmentsJson
          : reasoningSegmentsJson as String?,
      isStreaming: identical(isStreaming, sentinel)
          ? this.isStreaming
          : isStreaming as bool,
      totalTokens: identical(totalTokens, sentinel)
          ? this.totalTokens
          : totalTokens as int?,
      promptTokens: identical(promptTokens, sentinel)
          ? this.promptTokens
          : promptTokens as int?,
      completionTokens: identical(completionTokens, sentinel)
          ? this.completionTokens
          : completionTokens as int?,
      cachedTokens: identical(cachedTokens, sentinel)
          ? this.cachedTokens
          : cachedTokens as int?,
      durationMs: identical(durationMs, sentinel)
          ? this.durationMs
          : durationMs as int?,
      version: identical(version, sentinel) ? this.version : version as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'groupId': groupId,
      'speakerAssistantId': speakerAssistantId,
      'role': role,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'messageOrder': messageOrder,
      'modelId': modelId,
      'providerId': providerId,
      'reasoningText': reasoningText,
      'reasoningStartAt': reasoningStartAt?.toIso8601String(),
      'reasoningFinishedAt': reasoningFinishedAt?.toIso8601String(),
      'reasoningSegmentsJson': reasoningSegmentsJson,
      'isStreaming': isStreaming,
      'totalTokens': totalTokens,
      'promptTokens': promptTokens,
      'completionTokens': completionTokens,
      'cachedTokens': cachedTokens,
      'durationMs': durationMs,
      'version': version,
    };
  }

  factory GroupChatMessage.fromJson(Map<String, dynamic> json) {
    return GroupChatMessage(
      id: json['id'] as String,
      groupId: json['groupId'] as String,
      speakerAssistantId: json['speakerAssistantId'] as String?,
      role: json['role'] as String,
      content: json['content'] as String? ?? '',
      timestamp: DateTime.parse(json['timestamp'] as String),
      messageOrder: (json['messageOrder'] as num?)?.toInt() ?? 0,
      modelId: json['modelId'] as String?,
      providerId: json['providerId'] as String?,
      reasoningText: json['reasoningText'] as String?,
      reasoningStartAt: json['reasoningStartAt'] != null
          ? DateTime.parse(json['reasoningStartAt'] as String)
          : null,
      reasoningFinishedAt: json['reasoningFinishedAt'] != null
          ? DateTime.parse(json['reasoningFinishedAt'] as String)
          : null,
      reasoningSegmentsJson: json['reasoningSegmentsJson'] as String?,
      isStreaming: json['isStreaming'] as bool? ?? false,
      totalTokens: (json['totalTokens'] as num?)?.toInt(),
      promptTokens: (json['promptTokens'] as num?)?.toInt(),
      completionTokens: (json['completionTokens'] as num?)?.toInt(),
      cachedTokens: (json['cachedTokens'] as num?)?.toInt(),
      durationMs: (json['durationMs'] as num?)?.toInt(),
      version: (json['version'] as num?)?.toInt() ?? 0,
    );
  }
}
