/// Which turns in a request are not the user's own words.
///
/// A group chat hands every speaker its peers' turns as `user` messages, so the
/// last user-role message is not necessarily the user's. Images, the built-in
/// search query and the video attachment all hang off the user's own turn, so
/// they ask for this index instead of scanning for `role == 'user'`.
///
/// The marker below only exists in memory: every provider strips it where it
/// already strips the other internal keys, before the body goes on the wire.
library;

/// Set on a `user` message that carries another group member's words.
const String groupPeerSenderKey = '_groupPeerSender';

/// Index of the last message the user wrote, or `-1` when there is none.
int lastHumanUserIndex(List<Map<String, dynamic>> messages) {
  for (var i = messages.length - 1; i >= 0; i--) {
    final message = messages[i];
    if (message['role'] != 'user') continue;
    if (message[groupPeerSenderKey] != null) continue;
    return i;
  }
  return -1;
}
