import 'conversation.dart';

/// One row of the sidebar's chat list: a local assistant, a group chat, or a
/// remote DeepSeek Harness.
///
/// All kinds share a single ordered list (and a single drag order), because a
/// user looking for "who do I talk to" does not care which storage shape the
/// row has. [key] is the stable identity that order is persisted under.
///
/// ## `harness` owner audit
///
/// A `harness` owner is a remote DeepSeek Harness connection record
/// (`DshRemote`): listed, ordered, renamed and deleted like a local owner, but
/// never treated as one — it has no model, prompt, memory or local
/// conversation, and its credential is a server cookie rather than an assistant
/// payload. Every site that answers "which owner is this" or "what does a tap
/// do" was audited when the kind was added:
///
/// - `ChatOwnersProvider` — the third source is a narrow `HarnessOwnerSource`
///   so `lib/core` never imports the feature; `chat_owner_order_v1` gains
///   `harness:<id>` keys, so drag order stays one system.
/// - `ChatOwnerSettingsPage` and `_DesktopAssistantsBody` — rows resolve a
///   harness owner through the DSH state, render the remote card, and both
///   create menus gain the third row.
/// - `SideDrawer` — renders the remote row (whale mark, name) and routes the
///   pencil to the DSH assistant settings page; a row tap goes through the
///   existing `onOpenOwner` seam.
/// - `HomePageController.openOwner` — branches on [isHarness] before any
///   conversation logic; a remote owns no local conversation.
/// - `HomePageController._syncDefaultAssistant` — unchanged: a harness owner
///   never owns the open local conversation, so it never becomes the fallback
///   assistant.
/// - `ownerOfConversation` / `ChatFrostedBackdrop` — unchanged: a remote is
///   never a conversation owner, so it never paints a chat backdrop.
/// - `assistant_select_sheet.dart` and `group_member_list.dart` — unchanged by
///   construction: both are built from `Assistant` objects, and a harness owner
///   is not an Assistant, so it can be neither a move target nor a group member.
/// - Tag sections — unchanged: tags file assistants only; a harness owner is
///   not taggable and sorts in the ungrouped part of the shared order.
enum ChatOwnerKind { assistant, group, harness }

class ChatOwner {
  const ChatOwner(this.kind, this.id);

  const ChatOwner.assistant(String id) : this(ChatOwnerKind.assistant, id);
  const ChatOwner.group(String id) : this(ChatOwnerKind.group, id);
  const ChatOwner.harness(String id) : this(ChatOwnerKind.harness, id);

  final ChatOwnerKind kind;
  final String id;

  bool get isGroup => kind == ChatOwnerKind.group;

  /// A local assistant — the only kind that carries a model, a prompt and a
  /// local conversation.
  bool get isAssistant => kind == ChatOwnerKind.assistant;

  /// A remote DeepSeek Harness connection record.
  bool get isHarness => kind == ChatOwnerKind.harness;

  String get key => switch (kind) {
    ChatOwnerKind.assistant => 'assistant:$id',
    ChatOwnerKind.group => 'group:$id',
    ChatOwnerKind.harness => 'harness:$id',
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
