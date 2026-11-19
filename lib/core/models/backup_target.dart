/// The business vocabulary one Kelivo release reads out of a backup archive.
///
/// Two maps in an archive are keyed by business entity: `settings.json` and the
/// manifest's `businessEntityRowIds`. A reader that meets a key outside its own
/// vocabulary is not merely unable to use it — `BusinessSettingsRouter`'s row-id
/// routing throws `FormatException` on an entity source key it has no kind for,
/// which fails the restore *after* every compatibility check on the archive has
/// passed. That is what made a Cuplivo backup unreadable to Kelivo (every
/// release from v1.3.2 to the v1.3.6 baseline) once `group_chats_v1` was added:
/// neither the archive format nor the database schema moved, so nothing declined
/// the archive on its way in.
///
/// The numbers are data, one constant per release and never edited in place, so
/// an archive written for one release keeps its meaning when the next one is
/// pinned beside it. Generate a new one from that release's own tree —
/// `git show <kelivo-tag>:lib/core/database/business_data.dart` for the source
/// keys, `.../lib/core/models/backup_scope.dart` for the categories,
/// `.../lib/core/database/app_database.dart` for the schema, and
/// `.../lib/core/services/backup/restore_bundle_staging.dart` for the manifest's
/// root key set — and let `test/core/database/kelivo_vocabulary_test.dart` hold
/// the line.
final class KelivoVocabulary {
  const KelivoVocabulary._({
    required this.release,
    required this.archiveFormatVersion,
    required this.schemaVersion,
    required this.entitySourceKeys,
    required this.categories,
    required this.manifestRootKeys,
  });

  /// The release this constant was read from, and the floor the target's label
  /// names. The label is built from it, so it cannot say a version the pin does
  /// not hold.
  final String release;

  /// The newest archive format that release reads.
  final int archiveFormatVersion;

  /// The SQL schema that release opens.
  ///
  /// The target stamps every archive with the schema this build writes, so a
  /// release below this number can never restore one. It is the axis
  /// `kelivo_vocabulary_test.dart` asserts against
  /// `AppDatabase.currentSchemaVersion`: a schema bump makes the label false
  /// unless the floor moves with it.
  final int schemaVersion;

  /// Every `BusinessEntityKind.sourceKey` that release knows.
  final Set<String> entitySourceKeys;

  /// Every `BackupCategory.name` that release's manifest scope declares.
  final Set<String> categories;

  /// Every root key that release accepts in a source manifest.
  ///
  /// It is the union of two sets, because the reader stages a candidate before
  /// restoring: the keys its candidate rewrite removes (`scope`,
  /// `secretsIncluded`, `businessEntityRowIds`, `minimumReadableFormatVersion`)
  /// and the keys its candidate validator requires exactly (`format`,
  /// `formatVersion`, `payloadKind`, `createdAtUtc`, `appVersion`,
  /// `includeChats`, `includeFiles`, `assetRoots`, `database`, `entries`). A
  /// source key outside that union survives the rewrite and is then refused by
  /// the exact check — after the user has already consented to the restore.
  final Set<String> manifestRootKeys;

  bool knowsSourceKey(String key) => entitySourceKeys.contains(key);

  /// Kelivo v1.3.2 (`b1702b3a9`, 2026-10-26): the floor of the Kelivo target,
  /// and the first release that opens schema 5. v1.3.1 (`4742d2e28`) is at
  /// schema 3, so it cannot restore a database this build writes.
  ///
  /// A floor is also a range, and the range was measured rather than assumed:
  /// every release from v1.3.2 to the v1.3.6 baseline (`c2b48958d`) carries
  /// these same entity keys and categories at archive format 3 — `git diff` of
  /// `business_data.dart` and `backup_scope.dart` is empty across the whole
  /// window — so an archive built for this vocabulary imports into any of them.
  ///
  /// [manifestRootKeys] is the fourth axis and comes from the same tag's own
  /// restore code, not from the data files: the reader stages a candidate and
  /// then compares the manifest's root key set exactly, so a key outside this
  /// set is refused after the user has agreed to the restore.
  static const v1_3_2 = KelivoVocabulary._(
    release: '1.3.2',
    archiveFormatVersion: 3,
    schemaVersion: 5,
    entitySourceKeys: {
      'assistants_v1',
      'provider_configs_v1',
      'provider_groups_v1',
      'mcp_servers_v1',
      'world_books_v1',
      'assistant_memories_v1',
      'quick_phrases_v1',
      'search_services_v1',
      'tts_services_v1',
      'instruction_injections_v1',
      'assistant_tags_v1',
      'memory_entries_v1',
      'workspaces_v1',
      'skills_v1',
      'user_profile_fields_v1',
    },
    categories: {
      'chats',
      'files',
      'assistants',
      'providers',
      'mcp',
      'environmentVariables',
      'skills',
      'worldBooks',
      'memories',
      'quickPhrases',
      'instructions',
      'workspaces',
      'searchServices',
      'speechServices',
      'settings',
    },
    manifestRootKeys: {
      'format',
      'formatVersion',
      'payloadKind',
      'createdAtUtc',
      'appVersion',
      'includeChats',
      'includeFiles',
      'assetRoots',
      'database',
      'entries',
      'scope',
      'secretsIncluded',
      'businessEntityRowIds',
      'minimumReadableFormatVersion',
    },
  );
}

/// Which build a backup archive is written *for*.
///
/// A backup is not portable by default, only by declaration: the archive names
/// the entities it carries, so the set of names is a claim about the reader.
/// Writing for this build keeps every kind; writing for a Kelivo release omits
/// the kinds that release has no name for, in the archive format it accepts.
enum BackupTarget {
  /// This build: every kind, and the current archive format.
  cuplivo(null),

  /// The Kelivo line, written for the floor release [KelivoVocabulary.v1_3_2]
  /// names — and therefore readable by every release from there on.
  kelivo(KelivoVocabulary.v1_3_2);

  const BackupTarget(this.vocabulary);

  /// The release this archive must be readable by, or null for this build.
  final KelivoVocabulary? vocabulary;

  bool knowsSourceKey(String key) => vocabulary?.knowsSourceKey(key) ?? true;

  static BackupTarget? fromName(Object? name) {
    // 4.7.0 persisted the release inside the token. That choice was "the Kelivo
    // target", not "v1.3.4", so it must not read back as [cuplivo]: the next
    // archive would then carry group chats and stop importing there.
    if (name == 'kelivoV1_3_4') return kelivo;
    for (final target in values) {
      if (target.name == name) return target;
    }
    return null;
  }
}
