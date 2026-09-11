import '../../models/assistant.dart';
import '../../models/conversation.dart';

/// Pure context transformations shared by interactive and headless chat flows.
class ChatContextTransforms {
  const ChatContextTransforms._();

  static final RegExp _attachmentMarkerPattern = RegExp(
    r'\[image:.+?\]|\[file:.+?\|.+?\|.+?\]',
  );

  static const String timeNote =
      '<time-note>A timestamp will be injected by the system after every user message. Just keep it in mind, and don\'t mention it when irrelevant.</time-note>';

  static String appendTimestamp(
    String content,
    DateTime timestamp, {
    bool useIso8601 = false,
  }) {
    return '$content\n\n(${formatTimestamp(timestamp, useIso8601: useIso8601)})';
  }

  static String formatTimestamp(DateTime timestamp, {bool useIso8601 = false}) {
    if (useIso8601) {
      final offset = timestamp.timeZoneOffset;
      final sign = offset.isNegative ? '-' : '+';
      final minutes = offset.inMinutes.abs();
      final offsetHours = (minutes ~/ 60).toString().padLeft(2, '0');
      final offsetMinutes = (minutes % 60).toString().padLeft(2, '0');
      return '${timestamp.year.toString().padLeft(4, '0')}-'
          '${timestamp.month.toString().padLeft(2, '0')}-'
          '${timestamp.day.toString().padLeft(2, '0')}T'
          '${timestamp.hour.toString().padLeft(2, '0')}:'
          '${timestamp.minute.toString().padLeft(2, '0')}:'
          '${timestamp.second.toString().padLeft(2, '0')}'
          '$sign$offsetHours:$offsetMinutes';
    }
    const weekdays = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    return '${weekdays[timestamp.weekday % 7]} '
        '${(timestamp.year % 100).toString().padLeft(2, '0')}-'
        '${timestamp.month.toString().padLeft(2, '0')}-'
        '${timestamp.day.toString().padLeft(2, '0')} '
        '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}';
  }

  /// Cache-volatile variables a system prompt may embed; `{timezone}` etc.
  /// are excluded because they only change on device/timezone switch.
  static const List<String> volatileTimeVariables = [
    '{cur_date}',
    '{cur_time}',
    '{cur_datetime}',
  ];

  /// Returns which of the cache-volatile time variables occur in [prompt],
  /// in fixed order. Drives the warning badge/banner and the enable gate.
  static List<String> detectTimeVariables(String prompt) {
    return [
      for (final token in volatileTimeVariables)
        if (prompt.contains(token)) token,
    ];
  }

  /// Applies [transform] to message text while preserving persisted attachment
  /// markers byte-for-byte. Attachment loading remains the responsibility of
  /// the interactive chat pipeline; headless context building only protects
  /// their paths, names, and MIME types from user-authored regex rules.
  static String transformTextPreservingAttachmentMarkers(
    String content,
    String Function(String text) transform,
  ) {
    final buffer = StringBuffer();
    var cursor = 0;
    for (final match in _attachmentMarkerPattern.allMatches(content)) {
      buffer.write(transform(content.substring(cursor, match.start)));
      buffer.write(match.group(0));
      cursor = match.end;
    }
    buffer.write(transform(content.substring(cursor)));
    return buffer.toString();
  }

  static void injectTimeNote(List<Map<String, dynamic>> messages) {
    appendToSystemMessage(messages, timeNote);
  }

  static List<Conversation> selectRecentChats(
    Iterable<Conversation> conversations, {
    required String assistantId,
    required String? currentConversationId,
    int limit = 10,
  }) {
    final selected =
        conversations
            .where(
              (conversation) =>
                  !conversation.isGroup &&
                  conversation.assistantId == assistantId &&
                  conversation.id != currentConversationId &&
                  conversation.title.trim().isNotEmpty,
            )
            .toList(growable: false)
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return selected.take(limit).toList(growable: false);
  }

  static String buildRecentChatsBlock(Iterable<Conversation> conversations) {
    final chats = conversations.toList(growable: false);
    if (chats.isEmpty) return '';

    final buffer = StringBuffer();
    buffer.writeln('<recent_chats>');
    buffer.writeln('这是用户最近的一些对话标题和摘要，你可以参考这些内容了解用户偏好和关注点');
    for (final conversation in chats) {
      buffer.writeln('<conversation>');
      final timestamp = conversation.updatedAt.toIso8601String().substring(
        0,
        10,
      );
      final title = conversation.title.trim();
      final summary = (conversation.summary ?? '').trim();
      if (summary.isNotEmpty) {
        buffer.writeln('  $timestamp: $title || $summary');
      } else {
        buffer.writeln('  $timestamp: $title');
      }
      buffer.writeln('</conversation>');
    }
    buffer.writeln('</recent_chats>');
    return buffer.toString();
  }

  static void applyMessageLimit(
    List<Map<String, dynamic>> messages,
    Assistant? assistant,
  ) {
    if (!(assistant?.limitContextMessages ?? true) ||
        (assistant?.contextMessageSize ?? 0) <= 0) {
      return;
    }

    final keep = assistant!.contextMessageSize.clamp(
      Assistant.minContextMessageSize,
      Assistant.maxContextMessageSize,
    );
    var startIndex = 0;
    if (messages.isNotEmpty && messages.first['role'] == 'system') {
      startIndex = 1;
    }
    final tail = messages.sublist(startIndex);
    if (tail.length > keep) {
      final trimmed = tail.sublist(tail.length - keep);
      messages
        ..removeRange(startIndex, messages.length)
        ..addAll(trimmed);
    }

    // Trimming can cut into a tool-call triplet. Never retain dangling tools.
    while (messages.length > startIndex &&
        (messages[startIndex]['role'] ?? '').toString() == 'tool') {
      messages.removeAt(startIndex);
    }
  }

  static void appendToSystemMessage(
    List<Map<String, dynamic>> messages,
    String content,
  ) {
    if (messages.isNotEmpty && messages.first['role'] == 'system') {
      messages[0]['content'] =
          '${(messages[0]['content'] ?? '') as String}\n\n$content';
    } else {
      messages.insert(0, {'role': 'system', 'content': content});
    }
  }
}
