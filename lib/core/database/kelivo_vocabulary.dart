import '../models/backup_target.dart';
import '../models/conversation.dart';
import 'business_data.dart';

/// The fork's side of the reverse-import contract: what this build writes that
/// a pinned Kelivo release cannot read, and what it does about it.
///
/// [KelivoVocabulary] and [BackupTarget] are the model in
/// `lib/core/models/backup_target.dart`; this file is the part that needs
/// `BusinessEntityKind`, exactly as `backup_content_filter.dart` relates to
/// `backup_scope.dart`.

/// Every entity key this build writes that [target] cannot read back.
///
/// The one list both halves of the export filter read, and the one the database
/// sanitizer reads to drop the rows those keys describe — a single rule, so an
/// archive can never carry a stripped key beside a surviving row.
Set<String> unreadableEntitySourceKeys(BackupTarget target) => {
  for (final kind in BusinessEntityKind.values)
    if (!target.knowsSourceKey(kind.sourceKey)) kind.sourceKey,
};

/// [values] without the entity keys [target] cannot read.
///
/// Applies to `settings.json` and to `businessEntityRowIds` alike — they leave
/// together, or the archive contradicts itself about which entities it holds.
/// Preference keys are untouched: only keys that name an entity are asked about.
Map<String, T> withoutUnreadableEntityKeys<T>(
  Map<String, T> values,
  BackupTarget target,
) {
  final unreadable = unreadableEntitySourceKeys(target);
  if (unreadable.isEmpty) return values;
  return {
    for (final entry in values.entries)
      if (!unreadable.contains(entry.key)) entry.key: entry.value,
  };
}

/// What happens to one kind a pinned release cannot read, and what its users
/// lose.
typedef UnreadableKindDisposition = ({
  /// What the user gives up, in their terms.
  String loss,

  /// The `conversation.extras` key that points at a row of this kind, or null
  /// when no chat points at one.
  String? conversationLink,
});

/// How a kind a pinned release cannot read leaves the archive — by hand, one
/// entry per kind.
///
/// The pin test refuses a `BusinessEntityKind` that is neither in a vocabulary
/// nor in this table, which is how a new kind is forced to make its
/// reverse-import decision instead of discovering it on a user's device. The
/// record forces both halves of that decision: what the user loses, and whether
/// a chat points at the row. Both halves leave the archive together — a dropped
/// row whose link survived is the self-contradicting archive this rule exists to
/// end — so the sanitizer reads them from here rather than spelling one kind out.
const unreadableKindDispositions = <String, UnreadableKindDisposition>{
  'group_chats_v1': (
    loss:
        'Group chats have no Kelivo equivalent. A Kelivo-target archive drops '
        'the rows and the conversation link; the conversations themselves still '
        'travel, so the topics survive as ordinary chats.',
    conversationLink: Conversation.groupChatIdKey,
  ),
};

/// The extension storage [kind]'s rows live in, for a kind that must be dropped.
///
/// Throws when the kind has none: its rows would survive while its settings key
/// was stripped, which is the failure this rule exists to prevent. A kind stored
/// in its own table needs its own handling before it can be dispositioned, so
/// reaching this is a missing decision, not user input — and a loud stop is the
/// only honest answer, because the half-repair cannot be seen once it ships.
String droppableExtensionKind(BusinessEntityKind kind) {
  final extensionKind = kind.extensionKind;
  if (extensionKind == null) {
    throw StateError('unreadable_extension_kind:${kind.sourceKey}');
  }
  return extensionKind;
}

/// The `conversation.extras` keys that must leave the archive with [kinds].
///
/// Throws for a kind [unreadableKindDispositions] says nothing about: answering
/// "no links" would strip its rows and its settings key while leaving every chat
/// pointing at a row that is no longer there.
List<String> conversationLinksToStrip(Iterable<BusinessEntityKind> kinds) {
  final links = <String>[];
  for (final kind in kinds) {
    final disposition = unreadableKindDispositions[kind.sourceKey];
    if (disposition == null) {
      throw StateError('unreadable_kind_disposition:${kind.sourceKey}');
    }
    final link = disposition.conversationLink;
    if (link != null) links.add(link);
  }
  return links;
}
