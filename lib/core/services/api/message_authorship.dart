/// Which turns in a request are not the user's own words.
///
/// A group chat hands every speaker its peers' turns as `user` messages, so the
/// last user-role message is not necessarily the user's. Images, the built-in
/// search query and the video attachment all hang off the user's own turn, so
/// they ask `lastUserInputIndex()` (in `request_image_context.dart`) instead of
/// scanning for `role == 'user'`.
///
/// The marker below only exists in memory: every provider strips it where it
/// already strips the other internal keys, before the body goes on the wire.
library;

/// Set on a `user` message that carries another group member's words.
///
/// `isUserInputMessage` reads it, so the one answer to "is this the user's own
/// turn" covers injected lore and a peer's turn alike — two predicates that a
/// second helper would have to repeat at every call site.
const String groupPeerSenderKey = '_groupPeerSender';

/// Set on the one `user` message a finished subagent writes into its parent.
///
/// It travels as `user` because that is what the parent model should read, but
/// it is not something the user typed: carried images, the built-in search query
/// and the video attachment all hang off the human's last turn, and a subagent's
/// conclusion landing after that turn must not become "the last user input" and
/// take them over. Same reason as a group peer, same predicate.
const String subagentResultKey = '_subagentResult';
