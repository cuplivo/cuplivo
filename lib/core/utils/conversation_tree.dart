import '../models/chat_message.dart';

/// Pure helpers for the directed tree used by regular conversations.
///
/// A message has at most one parent. Siblings share a [ChatMessage.groupId]
/// and use [ChatMessage.version] only as their stable display order. The
/// parent link—not the chronological write order—is the authority for a
/// conversation's active context.
class ConversationTree {
  const ConversationTree._();

  static const String _rootGroupPrefix = '__conversation_tree_root__:';

  /// A stable sibling-group key for children that have no message parent.
  static String rootGroupId(String conversationId) =>
      '$_rootGroupPrefix$conversationId';

  /// Every direct child set gets one group. Existing UI controls can keep
  /// using groupId/version, while path selection is controlled by parent ids.
  static String siblingGroupId({
    required String conversationId,
    required String? parentMessageId,
  }) {
    return parentMessageId ?? rootGroupId(conversationId);
  }

  static List<ChatMessage> sortedSiblings(
    Iterable<ChatMessage> messages,
    ChatMessage message,
  ) {
    final siblings = messages
        .where(
          (candidate) =>
              candidate.conversationId == message.conversationId &&
              candidate.parentMessageId == message.parentMessageId &&
              candidate.groupId == message.groupId,
        )
        .toList(growable: false)
      ..sort(_compareVersions);
    return siblings;
  }

  static int siblingIndex(
    Iterable<ChatMessage> messages,
    ChatMessage message,
  ) {
    return sortedSiblings(messages, message).indexWhere(
      (candidate) => candidate.id == message.id,
    );
  }

  /// Returns the root-to-leaf path for [leafMessageId]. Invalid parents and
  /// cycles return no path: rendering even the surviving suffix would make an
  /// orphan look like a valid conversation branch.
  static List<ChatMessage> pathToRoot(
    Iterable<ChatMessage> messages,
    String? leafMessageId,
  ) {
    if (leafMessageId == null || leafMessageId.isEmpty) {
      return const <ChatMessage>[];
    }
    final byId = <String, ChatMessage>{
      for (final message in messages) message.id: message,
    };
    final reversed = <ChatMessage>[];
    final visited = <String>{};
    ChatMessage? current = byId[leafMessageId];
    while (current != null) {
      if (!visited.add(current.id)) return const <ChatMessage>[];
      reversed.add(current);
      final parentId = current.parentMessageId;
      if (parentId == null || parentId.isEmpty) break;
      final parent = byId[parentId];
      if (parent == null || parent.conversationId != current.conversationId) {
        return const <ChatMessage>[];
      }
      current = parent;
    }
    return reversed.reversed.toList(growable: false);
  }

  /// Follows the remembered selection at every later fork. If a selection is
  /// absent or stale, the newest direct child is used as the deterministic
  /// default. This makes switching back to a branch reveal its own continuation
  /// instead of another branch's messages.
  static ChatMessage selectLeafForBranch({
    required Iterable<ChatMessage> messages,
    required ChatMessage branchStart,
    required Map<String, int> versionSelections,
  }) {
    final all = List<ChatMessage>.of(messages);
    final visited = <String>{};
    var current = branchStart;
    while (visited.add(current.id)) {
      final children = all
          .where(
            (candidate) =>
                candidate.conversationId == current.conversationId &&
                candidate.parentMessageId == current.id,
          )
          .toList(growable: false)
        ..sort(_compareVersions);
      if (children.isEmpty) return current;

      // New tree messages deliberately give every direct child set one group.
      // If damaged/imported data has multiple groups under a parent, prefer the
      // latest group rather than silently combining incomparable choices.
      final groupId = children.last.groupId ?? children.last.id;
      final sameGroup = children
          .where((candidate) => (candidate.groupId ?? candidate.id) == groupId)
          .toList(growable: false)
        ..sort(_compareVersions);
      final selectedIndex = versionSelections[groupId];
      final safeIndex = selectedIndex != null &&
              selectedIndex >= 0 &&
              selectedIndex < sameGroup.length
          ? selectedIndex
          : sameGroup.length - 1;
      current = sameGroup[safeIndex];
    }
    return current;
  }

  static int nextSiblingVersion({
    required Iterable<ChatMessage> messages,
    required String conversationId,
    required String? parentMessageId,
  }) {
    final groupId = siblingGroupId(
      conversationId: conversationId,
      parentMessageId: parentMessageId,
    );
    var maxVersion = -1;
    for (final message in messages) {
      if (message.conversationId == conversationId &&
          message.parentMessageId == parentMessageId &&
          (message.groupId ?? message.id) == groupId) {
        if (message.version > maxVersion) maxVersion = message.version;
      }
    }
    return maxVersion + 1;
  }

  static int _compareVersions(ChatMessage a, ChatMessage b) {
    final byVersion = a.version.compareTo(b.version);
    if (byVersion != 0) return byVersion;
    final byTime = a.timestamp.compareTo(b.timestamp);
    if (byTime != 0) return byTime;
    return a.id.compareTo(b.id);
  }
}
