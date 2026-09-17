/// Conversation-extras conventions for group chats.
///
/// A group chat's public transcript is an ordinary conversation; this class
/// holds the feature-prefixed extras keys that mark and describe it. Fields
/// that need an index, foreign key, or CHECK live in real columns instead
/// (`group_chat_rows` / `group_chat_member_rows`, schema v5).
class GroupChatConversations {
  static const String extrasKindKey = 'group.kind';

  /// Value of [extrasKindKey] on a group conversation.
  static const String kindGroup = 'group';

  const GroupChatConversations._();

  static bool isGroupConversation(Map<String, dynamic> extras) =>
      extras[extrasKindKey] == kindGroup;
}
