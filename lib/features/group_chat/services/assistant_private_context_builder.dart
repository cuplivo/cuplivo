import '../../../core/models/assistant.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/group_chat.dart';
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

  /// Returns logical ChatMessages for MessagePipeline (user/assistant roles
  /// from the selected speaker's POV).
  List<ChatMessage> build({
    required Conversation conversation,
    required List<ChatMessage> publicMessages,
    required Assistant speaker,
    required String userName,
    required Map<String, Assistant> assistantsById,
  }) {
    // Version collapse (canonical implementation in ChatService).
    final selected = ChatService.collapseMessageVersions(
      publicMessages,
      conversation.versionSelections,
    );

    // truncateIndex is a raw-space boundary (normal chat semantics); map it
    // to a collapsed skip count so versioned groups stay aligned.
    final skip = ChatService.rawToCollapsedSkip(
      rawMessages: publicMessages,
      collapsedMessages: selected,
      truncateIndex: conversation.truncateIndex,
    );
    var slice = skip > 0 ? selected.sublist(skip) : selected;

    final buffer = <String>[];
    final out = <ChatMessage>[];
    final speakerId = speaker.id;

    void flushBufferAsUser() {
      if (buffer.isEmpty) return;
      out.add(
        ChatMessage(
          role: 'user',
          content: buffer.join('\n'),
          conversationId: conversation.id,
        ),
      );
      buffer.clear();
    }

    for (final msg in slice) {
      if (msg.role == 'user') {
        final text = _directorCtx.contentForDirector(msg);
        buffer.add('[$userName]: $text');
      } else if (msg.role == 'assistant') {
        final sid = msg.speakerAssistantId;
        final content = _directorCtx.contentForDirector(msg);
        if (sid == speakerId) {
          flushBufferAsUser();
          out.add(
            ChatMessage(
              role: 'assistant',
              content: content,
              conversationId: conversation.id,
              modelId: msg.modelId,
              providerId: msg.providerId,
              speakerAssistantId: sid,
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
