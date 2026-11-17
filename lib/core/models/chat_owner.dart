import 'conversation.dart';

/// One row of the sidebar's chat list: an assistant, or a group chat.
///
/// Both kinds share a single ordered list (and a single drag order), because a
/// user looking for "who do I talk to" does not care which storage shape the
/// row has. [key] is the stable identity that order is persisted under.
enum ChatOwnerKind { assistant, group }

class ChatOwner {
  const ChatOwner(this.kind, this.id);

  const ChatOwner.assistant(String id) : this(ChatOwnerKind.assistant, id);
  const ChatOwner.group(String id) : this(ChatOwnerKind.group, id);

  final ChatOwnerKind kind;
  final String id;

  bool get isGroup => kind == ChatOwnerKind.group;

  String get key => switch (kind) {
    ChatOwnerKind.assistant => 'assistant:$id',
    ChatOwnerKind.group => 'group:$id',
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatOwner && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => key;
}

/// The one answer to "who owns this conversation".
///
/// The sidebar's list scope, the owner row that is highlighted, the assistant a
/// new 1:1 remembers, and the chat's own backdrop all ask this — a second
/// derivation is how a group topic ended up listed under one owner while it was
/// painted as another.
///
/// A group row that no longer exists owns nothing: its topics fall through to
/// the assistant half and are shown, answered and painted as ordinary
/// conversations, rather than disappearing from every list. Both predicates are
/// injected because the answer has to be the same in places that have no
/// providers (tests, reduced hosts) and in places where a missing group list
/// means "unknown" rather than "gone".
ChatOwner? ownerOfConversation(
  Conversation? conversation, {
  required bool Function(String groupId) isLiveGroup,
  required String? Function(String? assistantId) resolveAssistantId,
}) => ownerOfChat(
  groupChatId: conversation?.groupChatId,
  assistantId: conversation?.assistantId,
  isLiveGroup: isLiveGroup,
  resolveAssistantId: resolveAssistantId,
);

/// [ownerOfConversation] from the two fields that decide ownership.
///
/// Callers that watch the open chat need this shape: a provider selector over
/// the whole [Conversation] notifies on *any* switch, while the list only has to
/// change when the owner does — two topics of one group are one list.
ChatOwner? ownerOfChat({
  required String? groupChatId,
  required String? assistantId,
  required bool Function(String groupId) isLiveGroup,
  required String? Function(String? assistantId) resolveAssistantId,
}) {
  if (groupChatId != null && isLiveGroup(groupChatId)) {
    return ChatOwner.group(groupChatId);
  }
  final resolvedAssistantId = resolveAssistantId(assistantId);
  return resolvedAssistantId == null
      ? null
      : ChatOwner.assistant(resolvedAssistantId);
}

/// The conversation to open once the chat being viewed is gone.
///
/// The successor comes from the same scope the list was showing, so deleting one
/// of a group's topics lands on another topic of that group. Choosing by
/// `assistantId == currentAssistantId` was a second derivation of ownership, and
/// it could never match a group topic — a group topic carries no assistant — so
/// deleting one left the group for whatever 1:1 that assistant happened to have.
///
/// Null means the scope has nothing left (or the gone chat had no owner); the
/// caller decides what starting over means.
Conversation? nextConversationAfterDelete(
  Iterable<Conversation> conversations, {
  required ChatOwner? scope,
  required Set<String> excludeIds,
  required bool Function(String groupId) isLiveGroup,
  required String? Function(String? assistantId) resolveAssistantId,
}) {
  if (scope == null) return null;
  Conversation? best;
  for (final conversation in conversations) {
    if (excludeIds.contains(conversation.id)) continue;
    final owner = ownerOfConversation(
      conversation,
      isLiveGroup: isLiveGroup,
      resolveAssistantId: resolveAssistantId,
    );
    if (owner != scope) continue;
    if (best == null || conversation.updatedAt.isAfter(best.updatedAt)) {
      best = conversation;
    }
  }
  return best;
}
