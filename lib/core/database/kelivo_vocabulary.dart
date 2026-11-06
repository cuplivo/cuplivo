import '../models/backup_target.dart';
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

/// What a pinned Kelivo release loses, and why — by hand, one entry per kind.
///
/// The pin test refuses a `BusinessEntityKind` that is neither in a vocabulary
/// nor in this table, which is how a new kind is forced to make its
/// reverse-import decision instead of discovering it on a user's device. Every
/// entry must be an *extension* kind: those are the ones the sanitizer can drop
/// without leaving a table behind, and a kind stored in its own table needs its
/// own handling there before it can be declared here.
const unreadableKindDispositions = <String, String>{
  'group_chats_v1':
      'Group chats have no Kelivo equivalent. A Kelivo-target archive drops the '
      'rows and the conversation link; the conversations themselves still '
      'travel, so the topics survive as ordinary chats.',
};
