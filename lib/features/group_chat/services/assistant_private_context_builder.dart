import '../../../core/models/assistant.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/group_chat.dart';
import '../../../core/models/message_part.dart';
import '../../../core/services/chat/chat_service.dart';
import 'director_context_builder.dart';

/// Builds on-the-fly private context for a member assistant (full timeline
/// role rewrite). Director is never visible.
class AssistantPrivateContextBuilder {
  AssistantPrivateContextBuilder({required this.chatService})
    : _directorCtx = DirectorContextBuilder(chatService: chatService);

  /// Returns the "you are in a group chat whose members are: ..." paragraph
  /// appended to a member assistant's system prompt when the group setting
  /// [GroupChat.injectGroupMembersIntoAssistantSystemPrompt] is enabled, or
  /// null when disabled. Lists the user and the member assistant names only —
  /// never other members' system prompts. See issue #190.
  static String? buildGroupMemberInjection({
    required GroupChat group,
    required String userName,
    required List<String> memberNames,
  }) {
    if (!group.injectGroupMembersIntoAssistantSystemPrompt) return null;
    final names = <String>[userName, ...memberNames];
    return '你现在处于一个群聊中，该群聊的成员为：${names.join('、')}';
  }

  final ChatService chatService;
  final DirectorContextBuilder _directorCtx;

  /// Returns logical ChatMessages for the send pipeline (user/assistant roles
  /// from the selected speaker's POV).
  ///
  /// Attachments ride along as structured parts instead of the fork's in-band
  /// `[image:...]` markers: this worktree reads media from
  /// [ChatMessage.parts], so a rewritten bubble that merges its author's
  /// image/file parts keeps the current human turn's media even when the
  /// trailing buffer holds only intervening member output.
  List<ChatMessage> build({
    required Conversation conversation,
    required List<ChatMessage> publicMessages,
    required Assistant speaker,
    required String userName,
    required Map<String, Assistant> assistantsById,
  }) {
    // Version collapse first, then apply the clear-context boundary: both the
    // repository context query and ChatService.loadSelectedContextMessages do
    // it in collapsed/logical-slot space, and `truncateIndex` counts logical
    // slots (see ChatService.generateTitleSource).
    final selected = _directorCtx.collapsePublicVersions(
      publicMessages,
      conversation.versionSelections,
    );
    final truncateIndex = conversation.truncateIndex;
    final skip = truncateIndex > 0 && truncateIndex <= selected.length
        ? truncateIndex
        : 0;
    final slice = skip > 0 ? selected.sublist(skip) : selected;

    final buffer = <String>[];
    final out = <ChatMessage>[];
    final speakerId = speaker.id;

    // The attachments of the most recent real human line. A member-only
    // bubble that gets flushed after it must keep carrying them: the send
    // pipeline reads media off the LAST user message only, so a repeated
    // member turn would otherwise lose the current human turn's upload — and
    // a new media-less human line overwrites them, so nothing leaks backwards.
    List<MessagePart> latestHumanAttachments = const [];

    void flushBufferAsUser() {
      if (buffer.isEmpty) return;
      final text = buffer.join('\n');
      out.add(
        ChatMessage(
          role: 'user',
          parts: [TextPart(text), ...latestHumanAttachments],
          conversationId: conversation.id,
        ),
      );
      buffer.clear();
    }

    for (final msg in slice) {
      if (msg.role == 'user') {
        final text = _directorCtx.contentForDirector(msg);
        buffer.add('[$userName]: $text');
        latestHumanAttachments = [
          for (final part in msg.parts)
            if (part is ImagePart || part is FilePart) part,
        ];
      } else if (msg.role == 'assistant') {
        final sid = msg.senderId;
        final content = _directorCtx.contentForDirector(msg);
        if (sid == speakerId) {
          flushBufferAsUser();
          out.add(
            ChatMessage(
              role: 'assistant',
              parts: msg.parts,
              conversationId: conversation.id,
              modelId: msg.modelId,
              providerId: msg.providerId,
              senderId: sid,
            ),
          );
        } else {
          final name = assistantsById[sid]?.name ?? sid ?? 'Assistant';
          buffer.add('[$name]: $content');
        }
      }
    }
    flushBufferAsUser();

    // Context size limit (after rewrite)
    if (speaker.limitContextMessages &&
        speaker.contextMessageSize > 0 &&
        out.length > speaker.contextMessageSize) {
      return out.sublist(out.length - speaker.contextMessageSize);
    }
    return out;
  }
}
