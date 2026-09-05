import '../../../core/models/assistant.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/group_chat.dart';
import '../../../core/models/group_chat_director_log.dart';
import '../../../core/services/chat/chat_service.dart';
import 'director_context_builder.dart';

enum DirectorLogOutcome { observedSpeaker, noObservedFollowUp, roundCapReached }

class DirectorLogContextMessage {
  const DirectorLogContextMessage({required this.role, required this.content});

  final String role;
  final String content;
}

class DirectorLogEntry {
  DirectorLogEntry({
    required this.order,
    required this.sourceMessageId,
    required this.timestamp,
    required this.trigger,
    required this.triggerContent,
    required List<DirectorLogContextMessage> contextMessages,
    required this.outcome,
    this.observedAssistantId,
    this.runtime,
  }) : contextMessages = List.unmodifiable(contextMessages);

  final int order;
  final String sourceMessageId;
  final DateTime timestamp;
  final GroupChatDirectorLogTrigger trigger;
  final String triggerContent;
  final List<DirectorLogContextMessage> contextMessages;
  final DirectorLogOutcome outcome;
  final String? observedAssistantId;
  final GroupChatDirectorRuntimeLog? runtime;
}

/// Reconstructs the director's visible decision trace from the public stream.
class DirectorLogBuilder {
  DirectorLogBuilder({required ChatService chatService})
    : _contextBuilder = DirectorContextBuilder(chatService: chatService);

  final DirectorContextBuilder _contextBuilder;

  List<DirectorLogEntry> build({
    required GroupChat group,
    required List<ChatMessage> publicMessages,
    required Conversation? conversation,
    required List<Assistant> rosterAssistants,
    required String userName,
    required Map<String, Assistant> assistantsById,
    required String fallbackAssistantName,
    List<GroupChatDirectorRuntimeLog> runtimeLogs = const [],
  }) {
    if (publicMessages.isEmpty || rosterAssistants.isEmpty) {
      return const [];
    }

    final versionSelections = conversation?.versionSelections ?? const {};
    final collapsed = _contextBuilder.collapsePublicVersions(
      publicMessages,
      versionSelections,
    );
    if (collapsed.isEmpty) return const [];

    final runtimeBySourceId = _latestRuntimeLogsBySource(runtimeLogs);
    // Reuse each message's reconstructed content across every entry so the
    // per-message tool-event lookup runs once per build instead of once per
    // entry (the history prefix is re-collapsed for every entry).
    final contentCache = <String, String>{};

    final entries = <DirectorLogEntry>[];
    var assistantCountThisRound = 0;
    ChatMessage? lastAssistant;
    var order = 0;

    for (var i = 0; i < collapsed.length; i++) {
      final message = collapsed[i];
      // Build the context from the already-collapsed prefix. Slicing the raw
      // transcript at a group's first occurrence would drop a prior group's
      // selected version when that version was appended later (edited versions
      // are appended at the end of the raw list, interleaved with newer turns).
      final historyRaw = collapsed.take(i).toList(growable: false);

      if (message.role == 'user') {
        final capReached =
            assistantCountThisRound >= _assistantCap(group) &&
            lastAssistant != null;
        final trigger = capReached
            ? GroupChatDirectorLogTrigger.capMerge
            : GroupChatDirectorLogTrigger.user;
        final tip = capReached
            ? _contextBuilder.buildCapMergeE3(
                assistantName: _assistantName(
                  lastAssistant,
                  assistantsById,
                  fallbackAssistantName,
                ),
                pendingAssistantContent: _contextBuilder.contentForDirector(
                  lastAssistant,
                ),
                userName: userName,
                newUserMessageText: DirectorContextBuilder.plainTextForDirector(
                  message.content,
                ),
              )
            : _contextBuilder.buildUserTurnE1(
                userName: userName,
                userMessageText: DirectorContextBuilder.plainTextForDirector(
                  message.content,
                ),
              );
        final apiMessages = _buildApiMessages(
          group: group,
          conversation: conversation,
          historyRaw: historyRaw,
          newContent: tip,
          rosterAssistants: rosterAssistants,
          userName: userName,
          assistantsById: assistantsById,
          skipPendingCapMessageId: capReached ? lastAssistant.id : null,
          fallbackAssistantName: fallbackAssistantName,
          contentCache: contentCache,
        );
        final nextAssistant = _nextAssistant(collapsed, i);
        entries.add(
          DirectorLogEntry(
            order: order++,
            sourceMessageId: message.id,
            timestamp: message.timestamp,
            trigger: trigger,
            triggerContent: DirectorContextBuilder.plainTextForDirector(
              message.content,
            ),
            contextMessages: _contextMessages(apiMessages),
            outcome: nextAssistant == null
                ? DirectorLogOutcome.noObservedFollowUp
                : DirectorLogOutcome.observedSpeaker,
            observedAssistantId: nextAssistant?.speakerAssistantId,
            runtime: runtimeBySourceId[message.id],
          ),
        );
        assistantCountThisRound = 0;
        lastAssistant = null;
        continue;
      }

      if (message.role != 'assistant') continue;
      assistantCountThisRound++;
      lastAssistant = message;

      if (assistantCountThisRound >= _assistantCap(group)) {
        entries.add(
          DirectorLogEntry(
            order: order++,
            sourceMessageId: message.id,
            timestamp: message.timestamp,
            trigger: GroupChatDirectorLogTrigger.assistant,
            triggerContent: message.content,
            contextMessages: const [],
            outcome: DirectorLogOutcome.roundCapReached,
          ),
        );
        continue;
      }

      final tip = _contextBuilder.buildAssistantTurnE2(
        assistantName: _assistantName(
          message,
          assistantsById,
          fallbackAssistantName,
        ),
        assistantContent: _contextBuilder.contentForDirector(message),
      );
      final apiMessages = _buildApiMessages(
        group: group,
        conversation: conversation,
        historyRaw: historyRaw,
        newContent: tip,
        rosterAssistants: rosterAssistants,
        userName: userName,
        assistantsById: assistantsById,
        fallbackAssistantName: fallbackAssistantName,
        contentCache: contentCache,
      );
      final nextAssistant = _nextAssistant(collapsed, i);
      entries.add(
        DirectorLogEntry(
          order: order++,
          sourceMessageId: message.id,
          timestamp: message.timestamp,
          trigger: GroupChatDirectorLogTrigger.assistant,
          triggerContent: message.content,
          contextMessages: _contextMessages(apiMessages),
          outcome: nextAssistant == null
              ? DirectorLogOutcome.noObservedFollowUp
              : DirectorLogOutcome.observedSpeaker,
          observedAssistantId: nextAssistant?.speakerAssistantId,
          runtime: runtimeBySourceId[message.id],
        ),
      );
    }

    return entries;
  }

  List<Map<String, dynamic>> _buildApiMessages({
    required GroupChat group,
    required Conversation? conversation,
    required List<ChatMessage> historyRaw,
    required String newContent,
    required List<Assistant> rosterAssistants,
    required String userName,
    required Map<String, Assistant> assistantsById,
    required String fallbackAssistantName,
    String? skipPendingCapMessageId,
    Map<String, String>? contentCache,
  }) {
    final memberNames = [userName, ...rosterAssistants.map((a) => a.name)];
    final originalTruncateIndex = conversation?.truncateIndex ?? -1;
    final truncateIndex = originalTruncateIndex <= 0
        ? originalTruncateIndex
        : originalTruncateIndex.clamp(0, historyRaw.length).toInt();
    return _contextBuilder.buildApiMessagesFromPublic(
      group: group,
      publicMessages: historyRaw,
      versionSelections: conversation?.versionSelections ?? const {},
      newUserContent: newContent,
      rosterAssistants: rosterAssistants,
      userName: userName,
      memberNames: memberNames,
      assistantsById: assistantsById,
      skipPendingCapMessageId: skipPendingCapMessageId,
      truncateIndexOverride: truncateIndex,
      fallbackAssistantName: fallbackAssistantName,
      contentCache: contentCache,
    );
  }

  List<DirectorLogContextMessage> _contextMessages(
    List<Map<String, dynamic>> apiMessages,
  ) {
    return apiMessages
        .map(
          (message) => DirectorLogContextMessage(
            role: message['role']?.toString() ?? '',
            content: message['content']?.toString() ?? '',
          ),
        )
        .toList(growable: false);
  }

  ChatMessage? _nextAssistant(List<ChatMessage> messages, int index) {
    final nextIndex = index + 1;
    if (nextIndex >= messages.length) return null;
    final next = messages[nextIndex];
    return next.role == 'assistant' ? next : null;
  }

  Map<String, GroupChatDirectorRuntimeLog> _latestRuntimeLogsBySource(
    List<GroupChatDirectorRuntimeLog> logs,
  ) {
    final result = <String, GroupChatDirectorRuntimeLog>{};
    for (final log in logs) {
      final sourceId = log.sourceMessageId;
      if (sourceId == null || sourceId.isEmpty) continue;
      final previous = result[sourceId];
      if (previous == null || log.finishedAt.isAfter(previous.finishedAt)) {
        result[sourceId] = log;
      }
    }
    return result;
  }

  String _assistantName(
    ChatMessage message,
    Map<String, Assistant> assistantsById,
    String fallbackAssistantName,
  ) {
    final id = message.speakerAssistantId;
    return id == null || id.isEmpty
        ? fallbackAssistantName
        : (assistantsById[id]?.name ?? id);
  }

  int _assistantCap(GroupChat group) {
    final cap = group.maxAssistantMessagesPerRound;
    return cap < 1 ? 1 : cap;
  }
}
