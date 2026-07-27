/// Parsed [ChatGroup.settingsJson] advanced options for multi-assistant group chat.
///
/// copyWith uses the plain `??` pattern (same as [Conversation] / [Assistant]).
/// Nullable director model fields use [clearDirectorModel] to set null.
class GroupChatSettings {
  static const int defaultMaxAssistantMessagesPerUserTurn = 6;

  /// null → use global default model.
  final String? directorModelProvider;
  final String? directorModelId;

  /// Empty / null → built-in default director system prompt (orchestrator phase).
  final String? directorSystemPrompt;

  final int maxAssistantMessagesPerUserTurn;
  final bool allowSameAssistantConsecutive;
  final bool persistDirectorTranscript;
  final bool stripOtherReasoningAndTools;

  /// Reserved: group chat disables MultiAI / proactive care / temporary sessions.
  final bool disableMultiAi;
  final bool disableProactiveCare;
  final bool disableTemporarySession;

  const GroupChatSettings({
    this.directorModelProvider,
    this.directorModelId,
    this.directorSystemPrompt,
    this.maxAssistantMessagesPerUserTurn =
        defaultMaxAssistantMessagesPerUserTurn,
    this.allowSameAssistantConsecutive = true,
    this.persistDirectorTranscript = true,
    this.stripOtherReasoningAndTools = true,
    this.disableMultiAi = true,
    this.disableProactiveCare = true,
    this.disableTemporarySession = true,
  });

  static const GroupChatSettings defaults = GroupChatSettings();

  GroupChatSettings copyWith({
    String? directorModelProvider,
    String? directorModelId,
    String? directorSystemPrompt,
    int? maxAssistantMessagesPerUserTurn,
    bool? allowSameAssistantConsecutive,
    bool? persistDirectorTranscript,
    bool? stripOtherReasoningAndTools,
    bool? disableMultiAi,
    bool? disableProactiveCare,
    bool? disableTemporarySession,
    bool clearDirectorModel = false,
    bool clearDirectorSystemPrompt = false,
  }) {
    return GroupChatSettings(
      directorModelProvider: clearDirectorModel
          ? null
          : (directorModelProvider ?? this.directorModelProvider),
      directorModelId: clearDirectorModel
          ? null
          : (directorModelId ?? this.directorModelId),
      directorSystemPrompt: clearDirectorSystemPrompt
          ? null
          : (directorSystemPrompt ?? this.directorSystemPrompt),
      maxAssistantMessagesPerUserTurn:
          maxAssistantMessagesPerUserTurn ??
          this.maxAssistantMessagesPerUserTurn,
      allowSameAssistantConsecutive:
          allowSameAssistantConsecutive ?? this.allowSameAssistantConsecutive,
      persistDirectorTranscript:
          persistDirectorTranscript ?? this.persistDirectorTranscript,
      stripOtherReasoningAndTools:
          stripOtherReasoningAndTools ?? this.stripOtherReasoningAndTools,
      disableMultiAi: disableMultiAi ?? this.disableMultiAi,
      disableProactiveCare: disableProactiveCare ?? this.disableProactiveCare,
      disableTemporarySession:
          disableTemporarySession ?? this.disableTemporarySession,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'directorModelProvider': directorModelProvider,
      'directorModelId': directorModelId,
      'directorSystemPrompt': directorSystemPrompt,
      'maxAssistantMessagesPerUserTurn': maxAssistantMessagesPerUserTurn,
      'allowSameAssistantConsecutive': allowSameAssistantConsecutive,
      'persistDirectorTranscript': persistDirectorTranscript,
      'stripOtherReasoningAndTools': stripOtherReasoningAndTools,
      'disableMultiAi': disableMultiAi,
      'disableProactiveCare': disableProactiveCare,
      'disableTemporarySession': disableTemporarySession,
    };
  }

  factory GroupChatSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null || json.isEmpty) return defaults;
    return GroupChatSettings(
      directorModelProvider: json['directorModelProvider'] as String?,
      directorModelId: json['directorModelId'] as String?,
      directorSystemPrompt: json['directorSystemPrompt'] as String?,
      maxAssistantMessagesPerUserTurn:
          (json['maxAssistantMessagesPerUserTurn'] as num?)?.toInt() ??
          defaultMaxAssistantMessagesPerUserTurn,
      allowSameAssistantConsecutive:
          json['allowSameAssistantConsecutive'] as bool? ?? true,
      persistDirectorTranscript:
          json['persistDirectorTranscript'] as bool? ?? true,
      stripOtherReasoningAndTools:
          json['stripOtherReasoningAndTools'] as bool? ?? true,
      disableMultiAi: json['disableMultiAi'] as bool? ?? true,
      disableProactiveCare: json['disableProactiveCare'] as bool? ?? true,
      disableTemporarySession: json['disableTemporarySession'] as bool? ?? true,
    );
  }
}
