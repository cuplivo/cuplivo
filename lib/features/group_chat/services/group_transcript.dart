import '../../../core/models/chat_message.dart';
import '../../../core/models/group_chat.dart';
import '../../../core/models/message_part.dart';
import '../../../core/models/assistant.dart';
import '../../chat/utils/thinking_tag_parser.dart';

/// How a group conversation is turned into model input.
///
/// Two rules drive everything here:
///
///  * a reply carries its author only in [ChatMessage.senderId], which no
///    provider understands, so the author becomes a visible `[Name]` line;
///  * another member's reasoning, tool cards and images are not replayed. A
///    `tool_call_id` produced under one provider is not valid under the next
///    speaker's provider, and an image one model generated is not an attachment
///    the next one can read.
class GroupTranscript {
  GroupTranscript._();

  /// Display name for a message's author, or a neutral placeholder.
  ///
  /// A deleted assistant must not silently become the current one: the panel
  /// would then attribute an old reply to whoever the user happens to be
  /// talking to now.
  static String speakerName(
    String? senderId,
    Assistant? Function(String? senderId) resolve,
  ) {
    final assistant = resolve(senderId);
    final name = assistant?.name.trim();
    if (name != null && name.isNotEmpty) return name;
    if (senderId == null) return 'Assistant';
    return 'Unknown assistant';
  }

  /// The public text of one assistant reply: thinking blocks stripped, and
  /// nothing else.
  static String publicText(ChatMessage message) =>
      ThinkingTagParser.parseWithRanges(message.content).visibleContent.trim();

  /// The tag that wraps another member's turn inside a `user` message.
  static const String envelopeTag = 'group_message';

  /// The history as the next speaker should see it.
  ///
  /// Only the speaker's own turns stay `assistant`: everyone else is somebody
  /// else talking, so their turn travels as `user` with the author in front.
  /// Handing a peer over as `assistant` made the model read another member's
  /// words as its own, and copy the name line as a reply prefix.
  ///
  /// User turns travel unchanged (their attachments are the user's own and are
  /// filtered by the speaker's model capabilities downstream). Assistant turns
  /// are reduced to an author plus public text, so no cross-provider artifact
  /// survives into another model's request.
  static List<ChatMessage> forSpeaker(
    List<ChatMessage> messages, {
    required String speakerId,
    required Assistant? Function(String? senderId) resolve,
  }) {
    return [
      for (final message in messages)
        if (message.role != 'assistant')
          message
        else if (message.senderId == speakerId)
          _rebuild(message, role: 'assistant', content: publicText(message))
        else
          _rebuild(
            message,
            role: 'user',
            content:
                '<$envelopeTag from="${speakerName(message.senderId, resolve)}">\n'
                '${publicText(message)}\n'
                '</$envelopeTag>',
          ),
    ];
  }

  /// The same message under a new role and content.
  ///
  /// Identity fields stay so the message can still be attributed, edited and
  /// versioned; the parts go, because a `tool_call_id` or an image produced
  /// under one provider is not valid input for the next speaker's model.
  static ChatMessage _rebuild(
    ChatMessage message, {
    required String role,
    required String content,
  }) {
    return ChatMessage(
      id: message.id,
      role: role,
      content: content,
      timestamp: message.timestamp,
      conversationId: message.conversationId,
      modelId: message.modelId,
      providerId: message.providerId,
      groupId: message.groupId,
      version: message.version,
      isStreaming: message.isStreaming,
      senderId: message.senderId,
    );
  }

  /// The roster paragraph appended to a speaker's system context.
  ///
  /// Names only: another member's system prompt, memory and world books belong
  /// to that member, and handing them to a peer model would turn a roster into a
  /// prompt leak.
  static String rosterDirective({
    required GroupChat group,
    required List<Assistant> members,
    required String speakerName,
    required Set<String> spokeThisRound,
  }) {
    final names = [
      for (final member in members)
        member.name.trim().isEmpty ? member.id : member.name.trim(),
    ];
    final buffer = StringBuffer()
      ..writeln(
        'You are "$speakerName", one member of the group chat '
        '"${group.name}". Other members may also reply to the same user '
        'message; write only your own turn.',
      )
      ..writeln('Group members: ${names.join(', ')}.')
      ..writeln(
        'Messages from other members reach you as user turns wrapped in '
        '<$envelopeTag from="Name"> … </$envelopeTag>. A user turn without '
        'that wrapper was written by the user.',
      );
    if (spokeThisRound.isNotEmpty) {
      final spoke = [
        for (final member in members)
          if (spokeThisRound.contains(member.id))
            member.name.trim().isEmpty ? member.id : member.name.trim(),
      ];
      if (spoke.isNotEmpty) {
        buffer.writeln('Already replied in this round: ${spoke.join(', ')}.');
      }
    }
    buffer.writeln(
      'Reply as yourself only. Do not write dialogue for other members and do '
      'not describe what they would say. Start with your own words: no '
      'wrapper, no name prefix.',
    );
    return buffer.toString().trim();
  }

  /// The compact transcript the director reads: role, author, text.
  static List<Map<String, String>> forDirector(
    List<ChatMessage> messages, {
    required Assistant? Function(String? senderId) resolve,
    int maxMessages = 12,
    int maxChars = 6000,
  }) {
    final selected = <Map<String, String>>[];
    String? lastName;
    for (var index = messages.length - 1; index >= 0; index--) {
      final message = messages[index];
      if (message.role != 'user' && message.role != 'assistant') continue;
      final text = message.role == 'assistant'
          ? publicText(message)
          : message.content.trim();
      if (text.isEmpty) continue;
      final name = message.role == 'assistant'
          ? speakerName(message.senderId, resolve)
          : null;
      // Consecutive replies from the same member are one voice; collapsing them
      // keeps the director's budget for distinct speakers.
      if (name != null && name == lastName) {
        selected.last['text'] = '${selected.last['text']}\n$text';
      } else {
        selected.add({
          'role': message.role,
          if (name != null) 'name': name,
          'text': text,
        });
      }
      lastName = name;
      if (selected.length >= maxMessages) break;
    }
    final ordered = selected.reversed.toList();
    var budget = maxChars;
    final out = <Map<String, String>>[];
    for (final entry in ordered.reversed) {
      final text = entry['text']!;
      if (budget <= 0) break;
      final clipped = text.length <= budget ? text : text.substring(0, budget);
      budget -= clipped.length;
      out.add({...entry, 'text': clipped});
    }
    return out.reversed.toList();
  }

  /// One line of the text a title model reads.
  ///
  /// Only the public text is sent: another member's reasoning is not what a
  /// title should be drawn from, and the title model is not guaranteed to be
  /// the member's own provider.
  static String Function(ChatMessage message) titleLine(
    Assistant? Function(String? senderId) resolve,
  ) {
    return (message) => message.role == 'assistant'
        ? '[${speakerName(message.senderId, resolve)}]: '
              '${publicText(message)}'
        : 'User: ${message.content}';
  }

  /// Whether a message is an empty assistant placeholder that must not count as
  /// part of the public transcript.
  static bool isBlankAssistantTurn(ChatMessage message) =>
      message.role == 'assistant' &&
      !message.isStreaming &&
      publicText(message).isEmpty &&
      !message.parts.any((part) => part is ImagePart || part is FilePart);
}
