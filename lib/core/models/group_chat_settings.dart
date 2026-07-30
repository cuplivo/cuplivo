/// Advanced options for a multi-assistant group chat.
///
/// Group chat deliberately does not participate in MultiAI, temporary-session,
/// or proactive-care flows. Those boundaries are structural and are therefore
/// not persisted as no-op "disable" flags.
class GroupChatSettings {
  static const int defaultMaxAssistantMessagesPerUserTurn = 6;
  static const Object sentinel = Object();

  /// null → use the global default model.
  final String? directorModelProvider;
  final String? directorModelId;

  /// Empty / null → use the built-in director prompt.
  final String? directorSystemPrompt;

  final int maxAssistantMessagesPerUserTurn;
  final bool allowSameAssistantConsecutive;
  final bool persistDirectorTranscript;

  const GroupChatSettings({
    this.directorModelProvider,
    this.directorModelId,
    this.directorSystemPrompt,
    this.maxAssistantMessagesPerUserTurn =
        defaultMaxAssistantMessagesPerUserTurn,
    this.allowSameAssistantConsecutive = true,
    this.persistDirectorTranscript = true,
  });

  static const GroupChatSettings defaults = GroupChatSettings();

  GroupChatSettings copyWith({
    Object? directorModelProvider = sentinel,
    Object? directorModelId = sentinel,
    Object? directorSystemPrompt = sentinel,
    Object? maxAssistantMessagesPerUserTurn = sentinel,
    Object? allowSameAssistantConsecutive = sentinel,
    Object? persistDirectorTranscript = sentinel,
  }) {
    return GroupChatSettings(
      directorModelProvider: identical(directorModelProvider, sentinel)
          ? this.directorModelProvider
          : directorModelProvider as String?,
      directorModelId: identical(directorModelId, sentinel)
          ? this.directorModelId
          : directorModelId as String?,
      directorSystemPrompt: identical(directorSystemPrompt, sentinel)
          ? this.directorSystemPrompt
          : directorSystemPrompt as String?,
      maxAssistantMessagesPerUserTurn:
          identical(maxAssistantMessagesPerUserTurn, sentinel)
          ? this.maxAssistantMessagesPerUserTurn
          : maxAssistantMessagesPerUserTurn as int,
      allowSameAssistantConsecutive:
          identical(allowSameAssistantConsecutive, sentinel)
          ? this.allowSameAssistantConsecutive
          : allowSameAssistantConsecutive as bool,
      persistDirectorTranscript: identical(persistDirectorTranscript, sentinel)
          ? this.persistDirectorTranscript
          : persistDirectorTranscript as bool,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'directorModelProvider': directorModelProvider,
    'directorModelId': directorModelId,
    'directorSystemPrompt': directorSystemPrompt,
    'maxAssistantMessagesPerUserTurn': maxAssistantMessagesPerUserTurn,
    'allowSameAssistantConsecutive': allowSameAssistantConsecutive,
    'persistDirectorTranscript': persistDirectorTranscript,
  };

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
    );
  }
}
