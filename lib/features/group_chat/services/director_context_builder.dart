import '../../../core/models/assistant.dart';
import '../../../core/models/assistant_detail_injection.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/group_chat.dart';
import '../../../core/services/chat/chat_service.dart';

/// Builds director user/system content and roster injection blocks.
class DirectorContextBuilder {
  DirectorContextBuilder({required this.chatService});

  final ChatService chatService;

  static const toolOnlyReminder =
      'Respond only by calling select_speaker or end_turn.';

  /// Strips in-band media markers (`[image:...]` / `[file:...]`) from a user
  /// message before it enters the Director's text-only protocol, replacing
  /// each with a bare placeholder. The Director never sees the raw content
  /// (it only produces speaker-selection tool calls), so the actual image
  /// bytes are handled per member by the private context pipeline.
  ///
  /// Deliberately NOT applied inside [contentForDirector]: that method is
  /// also used by [AssistantPrivateContextBuilder] to rebuild the member
  /// private context, where the markers MUST survive so the pipeline can
  /// parse them back into per-message media paths.
  static String plainTextForDirector(String content) {
    return content
        .replaceAllMapped(RegExp(r'\[image:[^\]]*\]'), (_) => '[image]')
        .replaceAllMapped(RegExp(r'\[file:[^\]]*\]'), (_) => '[file]');
  }

  /// Tool titles only — shared with private context builder.
  String contentForDirector(ChatMessage message) {
    final body = message.content.trim();
    final events = chatService.getToolEvents(message.id);
    final toolLines = <String>[];
    for (final e in events) {
      final name = (e['name'] ?? e['toolName'] ?? e['tool'] ?? '').toString();
      if (name.isNotEmpty) toolLines.add('[tool: $name]');
    }
    if (toolLines.isEmpty) return body;
    if (body.isEmpty) return toolLines.join('\n');
    return '$body\n${toolLines.join('\n')}';
  }

  String buildRosterBlock(List<Assistant> assistants) {
    final buf = StringBuffer('<assistant_roster>\n');
    for (final a in assistants) {
      final persona = _truncatePersona(a.systemPrompt);
      buf.writeln('- id: ${a.id}');
      buf.writeln('  name: ${a.name}');
      buf.writeln('  persona: |');
      for (final line in persona.split('\n')) {
        buf.writeln('    $line');
      }
    }
    buf.write('</assistant_roster>');
    return buf.toString();
  }

  String _truncatePersona(String raw) {
    final t = raw.trim();
    if (t.runes.length <= 4000) return t;
    return '${String.fromCharCodes(t.runes.take(4000))}\n…[truncated]';
  }

  String substituteVariables(
    String template, {
    required GroupChat group,
    required String userName,
    required List<String> memberNames,
  }) {
    final now = DateTime.now();
    final date =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    final time =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    return template
        .replaceAll('{current_hour}', now.hour.toString())
        .replaceAll('{current_date}', date)
        .replaceAll('{current_datetime}', '$date $time')
        .replaceAll('{group_name}', group.name)
        .replaceAll('{member_names}', memberNames.join(', '))
        .replaceAll(
          '{max_assistant_messages_per_round}',
          group.maxAssistantMessagesPerRound.toString(),
        )
        .replaceAll('{user_name}', userName);
  }

  /// E1 — human user message (no pending cap).
  String buildUserTurnE1({
    required String userName,
    required String userMessageText,
  }) {
    return '[$userName]: $userMessageText\n\n'
        '接下来，请选择是否由助手发送下条消息，由哪个助手发送下一条消息。\n'
        '$toolOnlyReminder';
  }

  /// E2 — assistant spoke.
  String buildAssistantTurnE2({
    required String assistantName,
    required String assistantContent,
  }) {
    return '[$assistantName]: $assistantContent\n\n'
        '接下来，请选择由哪个助手发送下一条消息。\n'
        '$toolOnlyReminder';
  }

  /// E3 — cap merge.
  String buildCapMergeE3({
    required String assistantName,
    required String pendingAssistantContent,
    required String userName,
    required String newUserMessageText,
  }) {
    return '[$assistantName]: $pendingAssistantContent\n'
        '[$userName]: $newUserMessageText\n\n'
        '接下来，请选择是否由助手发送下条消息，由哪个助手发送下一条消息。\n'
        '$toolOnlyReminder';
  }

  bool maybeAppendRoster({
    required AssistantDetailInjectionMode mode,
    required int n,
    required bool isHumanUserTurn,
    required bool isFirstHumanUser,
    required int userTurnCount,
    required int directorUserMsgCount,
  }) {
    switch (mode) {
      case AssistantDetailInjectionMode.beforeSystemPrompt:
      case AssistantDetailInjectionMode.appendIntoSystemPrompt:
        return false;
      case AssistantDetailInjectionMode.endOfFirstUserMessage:
        return isHumanUserTurn && isFirstHumanUser;
      case AssistantDetailInjectionMode.endOfEveryUserMessage:
        return isHumanUserTurn;
      case AssistantDetailInjectionMode.endOfEveryUserAndAssistantMessage:
        return true;
      case AssistantDetailInjectionMode.everyNUserMessages:
        return isHumanUserTurn && n > 0 && userTurnCount % n == 0;
      case AssistantDetailInjectionMode.everyNUserAndAssistantMessages:
        return n > 0 && directorUserMsgCount % n == 0;
    }
  }

  int countHumanUserTurnsFromPublic(List<ChatMessage> collapsed) {
    return collapsed.where((m) => m.role == 'user').length;
  }

  int countDirectorUserMessagesFromPublic(List<ChatMessage> collapsed) {
    return collapsed
        .where((m) => m.role == 'user' || m.role == 'assistant')
        .length;
  }

  /// Collapse using index-into-sorted-versions (default last). Delegates to
  /// the canonical [ChatService.collapseMessageVersions].
  List<ChatMessage> collapsePublicVersions(
    List<ChatMessage> publicMessages,
    Map<String, int> versionSelections,
  ) {
    return ChatService.collapseMessageVersions(
      publicMessages,
      versionSelections,
    );
  }

  /// Build API messages from the public transcript (no director DB history).
  ///
  /// Historical turns are reconstructed as full E1/E2 strings (with choice
  /// prompts). [newUserContent] is the live tip (E1/E2/E3), already roster-
  /// injected when needed. A conversation-level context boundary
  /// (`truncateIndex`, set by "clear context") is applied in raw-space and
  /// mapped to collapsed skip count, mirroring normal chat.
  List<Map<String, dynamic>> buildApiMessagesFromPublic({
    required GroupChat group,
    required List<ChatMessage> publicMessages,
    required Map<String, int> versionSelections,
    required String newUserContent,
    required List<Assistant> rosterAssistants,
    required String userName,
    required List<String> memberNames,
    required Map<String, Assistant> assistantsById,
    String? skipPendingCapMessageId,
    String? excludeTrailingUserMessageId,
    int? truncateIndexOverride,
    String fallbackAssistantName = 'Assistant',
    Map<String, String>? contentCache,
  }) {
    final roster = buildRosterBlock(rosterAssistants);
    final prompt = substituteVariables(
      group.directorSystemPrompt,
      group: group,
      userName: userName,
      memberNames: memberNames,
    );
    final mode = group.assistantDetailInjectionMode;
    final api = <Map<String, dynamic>>[];

    String contentFor(ChatMessage message) {
      if (contentCache == null) return contentForDirector(message);
      return contentCache.putIfAbsent(
        message.id,
        () => contentForDirector(message),
      );
    }

    if (mode == AssistantDetailInjectionMode.beforeSystemPrompt) {
      api.add({'role': 'system', 'content': roster});
      api.add({'role': 'system', 'content': prompt});
    } else if (mode == AssistantDetailInjectionMode.appendIntoSystemPrompt) {
      api.add({'role': 'system', 'content': '$prompt\n\n$roster'});
    } else {
      api.add({'role': 'system', 'content': prompt});
    }

    final collapsed = collapsePublicVersions(publicMessages, versionSelections);
    final truncateIndex =
        truncateIndexOverride ??
        chatService.getConversation(group.conversationId)?.truncateIndex ??
        -1;
    final skip = ChatService.rawToCollapsedSkip(
      rawMessages: publicMessages,
      collapsedMessages: collapsed,
      truncateIndex: truncateIndex,
    );
    final history = skip > 0 ? collapsed.sublist(skip) : collapsed;
    for (final m in history) {
      if (skipPendingCapMessageId != null && m.id == skipPendingCapMessageId) {
        continue;
      }
      if (excludeTrailingUserMessageId != null &&
          m.id == excludeTrailingUserMessageId &&
          m.role == 'user') {
        continue;
      }
      if (m.role == 'user') {
        api.add({
          'role': 'user',
          'content': buildUserTurnE1(
            userName: userName,
            userMessageText: plainTextForDirector(contentFor(m)),
          ),
        });
      } else if (m.role == 'assistant') {
        final name =
            assistantsById[m.speakerAssistantId]?.name ??
            m.speakerAssistantId ??
            fallbackAssistantName;
        api.add({
          'role': 'user',
          'content': buildAssistantTurnE2(
            assistantName: name,
            assistantContent: contentFor(m),
          ),
        });
      }
    }
    api.add({'role': 'user', 'content': newUserContent});
    return api;
  }
}
