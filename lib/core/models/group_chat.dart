import 'package:uuid/uuid.dart';

import 'assistant_detail_injection.dart';

/// Multi-assistant group chat metadata (public transcript lives in Conversation).
class GroupChat {
  GroupChat({
    String? id,
    required this.name,
    this.avatar,
    required this.conversationId,
    this.directorModelProvider,
    this.directorModelId,
    this.directorSystemPrompt = defaultDirectorSystemPrompt,
    this.maxAssistantMessagesPerRound = 3,
    this.assistantDetailInjectionMode =
        AssistantDetailInjectionMode.endOfEveryUserMessage,
    this.assistantDetailInjectionN = 5,
    this.injectGroupMembersIntoAssistantSystemPrompt = true,
    this.pendingCapAssistantMessageId,
    this.assistantMessagesThisRound = 0,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String name;
  String? avatar;
  final String conversationId;

  String? directorModelProvider;
  String? directorModelId;
  String directorSystemPrompt;
  int maxAssistantMessagesPerRound;
  AssistantDetailInjectionMode assistantDetailInjectionMode;
  int assistantDetailInjectionN;

  /// When enabled, member assistants get a short "you are in a group chat
  /// whose members are: ..." paragraph appended to their system prompt, so
  /// they can perceive the other participants. Names only — never the other
  /// members' system prompts (see issue #190).
  bool injectGroupMembersIntoAssistantSystemPrompt;

  /// When set, last assistant message hit the per-round cap and must merge
  /// with the next user message before sending to the director.
  String? pendingCapAssistantMessageId;
  int assistantMessagesThisRound;

  final DateTime createdAt;
  DateTime updatedAt;

  static const Object _sentinel = Object();

  static const String defaultDirectorSystemPrompt = '''
You are the silent Director of a multi-assistant group chat. You never speak to the human user directly. Your only job is to decide, via tools, who speaks next or whether the round should end.

## Participants
- One human user and multiple AI assistants. The live roster (id, name, persona) is injected according to group settings; trust the latest roster block when present.
- You are invisible to assistants. Do not address them in public text; only call tools.

## Decision policy
1. After a human message: choose the single most appropriate assistant with `select_speaker`, or `end_turn` if no assistant should reply (e.g. pure acknowledgment already complete, or silence is better).
2. After an assistant message: decide whether another assistant should continue (handoff, debate, specialist follow-up) or `end_turn`.
3. Prefer at most one assistant when a single specialist suffices. Use multiple assistants only when their personas clearly add distinct value.
4. Do not pick the same assistant twice in a row unless the conversation clearly requires a multi-step monologue from that persona.
5. Respect the configured max assistant messages per round ({max_assistant_messages_per_round}). When the limit is nearly reached, prefer `end_turn` after the next necessary speaker.
6. Never invent assistant_ids. Only use ids present in the roster.
7. Do not answer the user's question yourself in natural language. If you output text, keep it minimal; tools are authoritative.

## Style of selection
- Match persona to task (coding → engineer, empathy → companion, search-oriented → researcher, etc.).
- If the user names an assistant, prefer that assistant when id/name matches.
- If the user asks several assistants to discuss, alternate relevant speakers across turns until the topic is covered or the cap is hit.

## Tools
- select_speaker(assistant_id, reason?)
- end_turn(reason?)

Current group: {group_name}
User display name: {user_name}
Members: {member_names}
''';

  static const List<String> directorPromptVariables = [
    '{current_hour}',
    '{current_date}',
    '{current_datetime}',
    '{group_name}',
    '{member_names}',
    '{max_assistant_messages_per_round}',
    '{user_name}',
  ];

  GroupChat copyWith({
    String? id,
    String? name,
    Object? avatar = _sentinel,
    String? conversationId,
    Object? directorModelProvider = _sentinel,
    Object? directorModelId = _sentinel,
    String? directorSystemPrompt,
    int? maxAssistantMessagesPerRound,
    AssistantDetailInjectionMode? assistantDetailInjectionMode,
    int? assistantDetailInjectionN,
    bool? injectGroupMembersIntoAssistantSystemPrompt,
    Object? pendingCapAssistantMessageId = _sentinel,
    int? assistantMessagesThisRound,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool clearDirectorModel = false,
  }) {
    return GroupChat(
      id: id ?? this.id,
      name: name ?? this.name,
      avatar: identical(avatar, _sentinel) ? this.avatar : avatar as String?,
      conversationId: conversationId ?? this.conversationId,
      directorModelProvider: clearDirectorModel
          ? null
          : (identical(directorModelProvider, _sentinel)
                ? this.directorModelProvider
                : directorModelProvider as String?),
      directorModelId: clearDirectorModel
          ? null
          : (identical(directorModelId, _sentinel)
                ? this.directorModelId
                : directorModelId as String?),
      directorSystemPrompt: directorSystemPrompt ?? this.directorSystemPrompt,
      maxAssistantMessagesPerRound:
          maxAssistantMessagesPerRound ?? this.maxAssistantMessagesPerRound,
      assistantDetailInjectionMode:
          assistantDetailInjectionMode ?? this.assistantDetailInjectionMode,
      assistantDetailInjectionN:
          assistantDetailInjectionN ?? this.assistantDetailInjectionN,
      injectGroupMembersIntoAssistantSystemPrompt:
          injectGroupMembersIntoAssistantSystemPrompt ??
          this.injectGroupMembersIntoAssistantSystemPrompt,
      pendingCapAssistantMessageId:
          identical(pendingCapAssistantMessageId, _sentinel)
          ? this.pendingCapAssistantMessageId
          : pendingCapAssistantMessageId as String?,
      assistantMessagesThisRound:
          assistantMessagesThisRound ?? this.assistantMessagesThisRound,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'avatar': avatar,
    'conversationId': conversationId,
    'directorModelProvider': directorModelProvider,
    'directorModelId': directorModelId,
    'directorSystemPrompt': directorSystemPrompt,
    'maxAssistantMessagesPerRound': maxAssistantMessagesPerRound,
    'assistantDetailInjectionMode': assistantDetailInjectionMode.storageValue,
    'assistantDetailInjectionN': assistantDetailInjectionN,
    'injectGroupMembersIntoAssistantSystemPrompt':
        injectGroupMembersIntoAssistantSystemPrompt,
    'pendingCapAssistantMessageId': pendingCapAssistantMessageId,
    'assistantMessagesThisRound': assistantMessagesThisRound,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory GroupChat.fromJson(Map<String, dynamic> json) {
    return GroupChat(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      avatar: json['avatar'] as String?,
      conversationId: json['conversationId'] as String,
      directorModelProvider: json['directorModelProvider'] as String?,
      directorModelId: json['directorModelId'] as String?,
      directorSystemPrompt:
          json['directorSystemPrompt'] as String? ??
          defaultDirectorSystemPrompt,
      maxAssistantMessagesPerRound:
          (json['maxAssistantMessagesPerRound'] as num?)?.toInt() ?? 3,
      assistantDetailInjectionMode: AssistantDetailInjectionModeX.fromStorage(
        json['assistantDetailInjectionMode'] as String?,
      ),
      assistantDetailInjectionN:
          (json['assistantDetailInjectionN'] as num?)?.toInt() ?? 5,
      injectGroupMembersIntoAssistantSystemPrompt:
          (json['injectGroupMembersIntoAssistantSystemPrompt'] as bool?) ??
          true,
      pendingCapAssistantMessageId:
          json['pendingCapAssistantMessageId'] as String?,
      assistantMessagesThisRound:
          (json['assistantMessagesThisRound'] as num?)?.toInt() ?? 0,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : null,
      updatedAt: json['updatedAt'] != null
          ? DateTime.parse(json['updatedAt'] as String)
          : null,
    );
  }
}
