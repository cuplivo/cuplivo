import 'package:uuid/uuid.dart';

class Conversation {
  final String id;

  String title;

  final DateTime createdAt;

  DateTime updatedAt;

  final List<String> messageIds;

  bool isPinned;

  // Per-conversation enabled MCP servers (by server id)
  List<String> mcpServerIds;

  // Owner assistant id; null for global/default
  String? assistantId;

  // Parent conversation that spawned this one via handoff; null for normal
  String? parentConversationId;

  // Truncate context starting at this index (-1 means no truncation). In a
  // directed conversation this index is relative to the active root-to-leaf
  // path, not the full chronological row set.
  int truncateIndex;

  // Selected version per message group (groupId -> selected version index)
  Map<String, int> versionSelections;

  /// Current leaf of the directed message tree. Null keeps a legacy
  /// conversation on its original linear/versioned behavior.
  String? activeMessageId;

  // LLM-generated conversation summary
  String? summary;

  // Message count when summary was last generated (to avoid redundant updates)
  int lastSummarizedMessageCount;

  // LLM-generated quick follow-up suggestions for the latest assistant reply.
  List<String> chatSuggestions;

  /// 'normal' | 'group'
  String conversationKind;

  static const String kindNormal = 'normal';
  static const String kindGroup = 'group';

  bool get isGroup => conversationKind == kindGroup;

  Conversation({
    String? id,
    required this.title,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<String>? messageIds,
    this.isPinned = false,
    List<String>? mcpServerIds,
    this.assistantId,
    this.parentConversationId,
    int? truncateIndex,
    Map<String, int>? versionSelections,
    this.activeMessageId,
    this.summary,
    int? lastSummarizedMessageCount,
    List<String>? chatSuggestions,
    this.conversationKind = kindNormal,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now(),
       messageIds = messageIds ?? [],
       mcpServerIds = mcpServerIds ?? [],
       truncateIndex = truncateIndex ?? -1,
       versionSelections = versionSelections ?? <String, int>{},
       lastSummarizedMessageCount = lastSummarizedMessageCount ?? 0,
       chatSuggestions = chatSuggestions ?? [];

  Conversation copyWith({
    String? id,
    String? title,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<String>? messageIds,
    bool? isPinned,
    List<String>? mcpServerIds,
    String? assistantId,
    String? parentConversationId,
    int? truncateIndex,
    Map<String, int>? versionSelections,
    String? activeMessageId,
    bool clearActiveMessageId = false,
    String? summary,
    int? lastSummarizedMessageCount,
    List<String>? chatSuggestions,
    bool clearSummary = false,
    String? conversationKind,
  }) {
    return Conversation(
      id: id ?? this.id,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      messageIds: messageIds ?? this.messageIds,
      isPinned: isPinned ?? this.isPinned,
      mcpServerIds: mcpServerIds ?? this.mcpServerIds,
      assistantId: assistantId ?? this.assistantId,
      parentConversationId: parentConversationId ?? this.parentConversationId,
      truncateIndex: truncateIndex ?? this.truncateIndex,
      versionSelections: versionSelections ?? this.versionSelections,
      activeMessageId: clearActiveMessageId
          ? null
          : (activeMessageId ?? this.activeMessageId),
      summary: clearSummary ? null : (summary ?? this.summary),
      lastSummarizedMessageCount:
          lastSummarizedMessageCount ?? this.lastSummarizedMessageCount,
      chatSuggestions: chatSuggestions ?? this.chatSuggestions,
      conversationKind: conversationKind ?? this.conversationKind,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'messageIds': messageIds,
      'isPinned': isPinned,
      'mcpServerIds': mcpServerIds,
      'assistantId': assistantId,
      'parentConversationId': parentConversationId,
      'truncateIndex': truncateIndex,
      'versionSelections': versionSelections,
      'activeMessageId': activeMessageId,
      'summary': summary,
      'lastSummarizedMessageCount': lastSummarizedMessageCount,
      'chatSuggestions': chatSuggestions,
      'conversationKind': conversationKind,
    };
  }

  factory Conversation.fromJson(Map<String, dynamic> json) {
    return Conversation(
      id: json['id'] as String,
      title: json['title'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      messageIds: (json['messageIds'] as List?)?.cast<String>() ?? <String>[],
      isPinned: json['isPinned'] as bool? ?? false,
      mcpServerIds:
          (json['mcpServerIds'] as List?)?.cast<String>() ?? <String>[],
      assistantId: json['assistantId'] as String?,
      parentConversationId: json['parentConversationId'] as String?,
      truncateIndex: json['truncateIndex'] as int? ?? -1,
      versionSelections:
          (json['versionSelections'] as Map?)?.map(
            (k, v) => MapEntry(k.toString(), (v as num).toInt()),
          ) ??
          <String, int>{},
      activeMessageId: json['activeMessageId'] as String?,
      summary: json['summary'] as String?,
      lastSummarizedMessageCount:
          json['lastSummarizedMessageCount'] as int? ?? 0,
      chatSuggestions:
          (json['chatSuggestions'] as List?)?.cast<String>() ?? <String>[],
      conversationKind: json['conversationKind'] as String? ?? kindNormal,
    );
  }
}
