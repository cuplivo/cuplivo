import '../../models/assistant.dart';
import '../../models/group_chat_message.dart';
import '../../models/group_chat_settings.dart';

/// One member card injected into the director's first turn.
class DirectorMemberIntro {
  const DirectorMemberIntro({
    required this.assistantId,
    required this.name,
    required this.systemPrompt,
  });

  final String assistantId;
  final String name;
  final String systemPrompt;

  factory DirectorMemberIntro.fromAssistant(Assistant a) {
    return DirectorMemberIntro(
      assistantId: a.id,
      name: a.name,
      systemPrompt: a.systemPrompt,
    );
  }
}

/// Builds director (hidden session) prompts and public transcript deltas.
class DirectorPromptBuilder {
  const DirectorPromptBuilder._();

  /// Built-in director system prompt (product default).
  static const String defaultSystemPrompt = '''
你是群聊「导演」（对话管理模型），不直接与终端用户聊天，也不代替任何成员助手撰写对用户可见的回复正文。

职责：
1. 阅读用户消息与各成员已公开的发言，决定下一条对用户可见的消息应由哪位成员助手发出，或本轮结束。
2. 仅通过工具表达决定：select_speaker / end_round。不要输出长篇对用户说话的正文。
3. 可以在一轮用户消息后安排多位成员依次发言；也可让同一成员连续多条（若设置允许）。
4. 当话题已充分回应、或继续发言收益低时，调用 end_round。
5. 不要编造未提供的成员；assistant_id 必须来自成员列表。
6. 不考虑工具调用的内部细节；你看到的历史是用户与成员的公开对话内容。
''';

  static const String decisionUserPrompt =
      '请决定下一条对用户可见的消息由哪位成员发送，或结束本轮。'
      '仅调用工具 select_speaker 或 end_round，不要撰写对用户可见的回复正文。';

  /// Resolve system prompt: custom override or built-in default.
  static String resolveSystemPrompt(GroupChatSettings settings) {
    final custom = settings.directorSystemPrompt?.trim();
    if (custom != null && custom.isNotEmpty) return custom;
    return defaultSystemPrompt;
  }

  /// First director turn after a user message when the hidden session is empty.
  static List<Map<String, dynamic>> buildInitialMessages({
    required String systemPrompt,
    required List<DirectorMemberIntro> members,
    required String userMessage,
    bool allowSameAssistantConsecutive = true,
  }) {
    final buf = StringBuffer();
    buf.writeln('## 群成员');
    if (members.isEmpty) {
      buf.writeln('（无启用成员）');
    } else {
      for (final m in members) {
        buf.writeln('- id: `${m.assistantId}`');
        buf.writeln('  name: ${m.name}');
        final sp = m.systemPrompt.trim();
        if (sp.isNotEmpty) {
          buf.writeln('  system_prompt:');
          buf.writeln('  """');
          buf.writeln(sp);
          buf.writeln('  """');
        } else {
          buf.writeln('  system_prompt: (empty)');
        }
        buf.writeln();
      }
    }
    buf.writeln('## 规则补充');
    buf.writeln(
      allowSameAssistantConsecutive
          ? '- 允许同一助手连续发言。'
          : '- 不允许同一助手连续发言；请选择不同成员。',
    );
    buf.writeln();
    buf.writeln('## 用户消息');
    buf.writeln(userMessage.trim());
    buf.writeln();
    buf.writeln(decisionUserPrompt);

    return <Map<String, dynamic>>[
      <String, dynamic>{'role': 'system', 'content': systemPrompt},
      <String, dynamic>{'role': 'user', 'content': buf.toString()},
    ];
  }

  /// Public timeline content suitable for the director (user + assistant body only).
  static List<Map<String, dynamic>> publicTranscriptMessages(
    List<GroupChatMessage> messages, {
    Map<String, String> assistantNames = const <String, String>{},
  }) {
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      if (m.role == 'user' || m.speakerAssistantId == null) {
        final c = m.content.trim();
        if (c.isEmpty) continue;
        out.add(<String, dynamic>{'role': 'user', 'content': c});
        continue;
      }
      final c = m.content.trim();
      if (c.isEmpty) continue;
      final name = assistantNames[m.speakerAssistantId!];
      final content = (name != null && name.trim().isNotEmpty)
          ? '[${name.trim()}]: $c'
          : c;
      out.add(<String, dynamic>{'role': 'assistant', 'content': content});
    }
    return out;
  }

  /// Append a newly finished public message + decision request to director history.
  ///
  /// Director history is a list of role/content maps (no tool transcripts required).
  static List<Map<String, dynamic>> appendPublicMessageAndAsk(
    List<Map<String, dynamic>> directorMessages, {
    required GroupChatMessage publicMessage,
    Map<String, String> assistantNames = const <String, String>{},
  }) {
    final next = List<Map<String, dynamic>>.from(
      directorMessages.map((e) => Map<String, dynamic>.from(e)),
    );

    if (publicMessage.role == 'user' ||
        publicMessage.speakerAssistantId == null) {
      final c = publicMessage.content.trim();
      if (c.isNotEmpty) {
        next.add(<String, dynamic>{'role': 'user', 'content': c});
      }
    } else {
      final c = publicMessage.content.trim();
      if (c.isNotEmpty) {
        final name = assistantNames[publicMessage.speakerAssistantId!];
        final content = (name != null && name.trim().isNotEmpty)
            ? '[${name.trim()}]: $c'
            : c;
        next.add(<String, dynamic>{'role': 'assistant', 'content': content});
      }
    }

    next.add(<String, dynamic>{'role': 'user', 'content': decisionUserPrompt});
    return next;
  }

  /// Ensure the last user turn is a decision request (idempotent-ish).
  static List<Map<String, dynamic>> ensureTrailingDecisionPrompt(
    List<Map<String, dynamic>> directorMessages,
  ) {
    if (directorMessages.isEmpty) {
      return <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': decisionUserPrompt},
      ];
    }
    final last = directorMessages.last;
    final role = (last['role'] ?? '').toString();
    final content = (last['content'] ?? '').toString();
    if (role == 'user' && content.contains('select_speaker')) {
      return List<Map<String, dynamic>>.from(
        directorMessages.map((e) => Map<String, dynamic>.from(e)),
      );
    }
    final next = List<Map<String, dynamic>>.from(
      directorMessages.map((e) => Map<String, dynamic>.from(e)),
    );
    next.add(<String, dynamic>{'role': 'user', 'content': decisionUserPrompt});
    return next;
  }
}
