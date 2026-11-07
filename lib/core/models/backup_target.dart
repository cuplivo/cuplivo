/// The business vocabulary one Kelivo release reads out of a backup archive.
///
/// Two maps in an archive are keyed by business entity: `settings.json` and the
/// manifest's `businessEntityRowIds`. A reader that meets a key outside its own
/// vocabulary is not merely unable to use it — `BusinessSettingsRouter`'s row-id
/// routing throws `FormatException` on an entity source key it has no kind for,
/// which fails the restore *after* every compatibility check on the archive has
/// passed. That is what made a Cuplivo backup unreadable to Kelivo v1.3.4 once
/// `group_chats_v1` was added: neither the archive format nor the database
/// schema moved, so nothing declined the archive on its way in.
///
/// The numbers are data, one constant per release and never edited in place, so
/// an archive written for one release keeps its meaning when the next one is
/// pinned beside it. Generate a new one from that release's own tree —
/// `git show <kelivo-tag>:lib/core/database/business_data.dart` for the source
/// keys and `.../lib/core/models/backup_scope.dart` for the categories — and let
/// `test/core/database/kelivo_vocabulary_test.dart` hold the line.
final class KelivoVocabulary {
  const KelivoVocabulary._({
    required this.archiveFormatVersion,
    required this.entitySourceKeys,
    required this.categories,
  });

  /// The newest archive format that release reads.
  final int archiveFormatVersion;

  /// Every `BusinessEntityKind.sourceKey` that release knows.
  final Set<String> entitySourceKeys;

  /// Every `BackupCategory.name` that release's manifest scope declares.
  final Set<String> categories;

  bool knowsSourceKey(String key) => entitySourceKeys.contains(key);

  /// Kelivo v1.3.4 (`4a7da9b6f`, 2026-11-02): the baseline this line sits on,
  /// and the release a Cuplivo user would go back to.
  static const v1_3_4 = KelivoVocabulary._(
    archiveFormatVersion: 3,
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

  /// The last Kelivo release, for a user taking their data back.
  kelivoV1_3_4(KelivoVocabulary.v1_3_4);

  const BackupTarget(this.vocabulary);

  /// The release this archive must be readable by, or null for this build.
  final KelivoVocabulary? vocabulary;

  bool knowsSourceKey(String key) => vocabulary?.knowsSourceKey(key) ?? true;

  static BackupTarget? fromName(Object? name) {
    for (final target in values) {
      if (target.name == name) return target;
    }
    return null;
  }
}
