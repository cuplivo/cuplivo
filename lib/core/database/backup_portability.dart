import 'dart:convert';

import 'app_database.dart';
import '../models/backup_scope.dart';
import '../models/backup_target.dart';
import '../models/conversation.dart';
import 'backup_content_filter.dart';
import 'business_data.dart';
import 'business_repository.dart';
import 'business_settings_router.dart';
import 'kelivo_vocabulary.dart';

/// Device state stays in SQLite at runtime, but must not travel in a backup.
final class BackupPortability {
  BackupPortability._();

  /// The keys a travelling backup leaves behind.
  ///
  /// Membership belongs to the registry (`KeyPolicy.deviceLocal`), not here: this
  /// list used to be the second authority on the same question, so a key could be
  /// added to the registry and left out of backups (or the reverse) without
  /// anything noticing.
  static final Set<String> devicePreferenceKeys = {
    for (final entry in BusinessKeyRegistry.rules.entries)
      if (entry.value.policy == KeyPolicy.deviceLocal) entry.key,
  };

  static bool _isLinked(BusinessEntityValue row) =>
      isLinkedWorkspace(row.payload);

  static BusinessSnapshot portable(BusinessSnapshot source) {
    final workspaces = source.entities[BusinessEntityKind.workspace]!;
    final linkedIds = {for (final row in workspaces.where(_isLinked)) row.id};
    final entities = {...source.entities};
    entities[BusinessEntityKind.workspace] = [
      for (final row in workspaces)
        if (!_isLinked(row))
          row.copyWith(
            payload: jsonEncode(
              Map<String, dynamic>.from(jsonDecode(row.payload) as Map)
                ..remove('hostPath')
                ..remove('lastUsedAt'),
            ),
          ),
    ];
    entities[BusinessEntityKind.assistant] = [
      for (final row in source.entities[BusinessEntityKind.assistant]!)
        _withoutLinkedDefault(row, linkedIds),
    ];
    return BusinessSnapshot(
      entities: entities,
      preferences: {...source.preferences}
        ..removeWhere((key, _) => devicePreferenceKeys.contains(key)),
    );
  }

  static BusinessEntityValue _withoutLinkedDefault(
    BusinessEntityValue row,
    Set<String> linkedIds,
  ) {
    final payload = Map<String, dynamic>.from(jsonDecode(row.payload) as Map);
    if (!linkedIds.contains(payload['defaultWorkspaceId'])) return row;
    payload.remove('defaultWorkspaceId');
    return row.copyWith(payload: jsonEncode(payload));
  }

  /// Preserve the target's environment and linked folders during overwrite.
  static BusinessSnapshot preserveDeviceState(
    BusinessSnapshot incoming,
    BusinessSnapshot local,
  ) {
    final linked = local.entities[BusinessEntityKind.workspace]!
        .where(_isLinked)
        .toList();
    final linkedIds = {for (final row in linked) row.id};
    return BusinessSnapshot(
      entities: {
        ...incoming.entities,
        BusinessEntityKind.workspace: [
          ...linked,
          for (final row in incoming.entities[BusinessEntityKind.workspace]!)
            if (!linkedIds.contains(row.id)) row,
        ],
      },
      preferences: {
        ...incoming.preferences,
        for (final key in devicePreferenceKeys)
          if (local.preferences.containsKey(key)) key: local.preferences[key]!,
      },
    );
  }

  /// Only call on a temporary database, never the live database. This also
  /// handles old backups whose raw SQLite payload still has device-only rows.
  ///
  /// [target] decides which business kinds the archive may still name. A backup
  /// written for a Kelivo release drops every kind that release has no word for,
  /// because the settings export already dropped those keys — leaving the rows
  /// would make the archive contradict its own manifest, and leaving the
  /// conversation link would land chats that point at an entity the reader will
  /// never have.
  static Future<void> sanitizeDatabase(
    AppDatabase database, {
    BackupScope scope = const BackupScope(),
    BackupTarget target = BackupTarget.cuplivo,
  }) async {
    // Erase removed payloads from SQLite cells as well as its logical rows.
    await database.customStatement('PRAGMA secure_delete = ON;');
    await database.transaction(() async {
      await BusinessRepository(database).transformSnapshot(
        (snapshot) =>
            portable(BackupContentFilter.selectSnapshot(snapshot, scope)),
      );
      await database.customStatement(
        "DELETE FROM extension_entity_rows WHERE kind IN ('externalMounts', 'composerDraft', 'composerNewEntry', 'composerShareReceipt', 'composerPrivateFile');",
      );
      await _dropUnreadableKinds(database, target);
      // Chat history remains readable, but imported chats cannot inherit a
      // directory grant or silently authorize shell execution on this device.
      await database.customStatement('''
        UPDATE conversation_rows SET extras_json = CASE
          WHEN json_extract(extras_json, '\$."workspace.id"') IS NOT NULL
            AND NOT EXISTS (
              SELECT 1 FROM extension_entity_rows
              WHERE kind = 'workspace'
                AND id = json_extract(extras_json, '\$."workspace.id"')
            )
          THEN json_remove(extras_json, '\$."workspace.id"',
            '\$."workspace.cwd"', '\$."workspace.tools_used"',
            '\$."workspace.allowAll"', '\$."tools.permission_mode"')
          ELSE json_remove(extras_json, '\$."workspace.allowAll"', '\$."tools.permission_mode"')
        END
        WHERE json_valid(extras_json)
          AND (json_type(extras_json, '\$."workspace.id"') IS NOT NULL
            OR json_type(extras_json, '\$."workspace.allowAll"') IS NOT NULL
            OR json_type(extras_json, '\$."tools.permission_mode"') IS NOT NULL);
      ''');
    });
  }

  /// Removes the rows, and the conversation links, of every kind [target] cannot
  /// read.
  ///
  /// The two halves belong together: an entity row without its settings key is an
  /// archive that contradicts itself, and a conversation naming a group that did
  /// not travel is a link the reader would have to guess about. Only extension
  /// kinds are handled here, which is why
  /// `test/core/database/kelivo_vocabulary_test.dart` refuses a disposition for a
  /// kind that is not one.
  static Future<void> _dropUnreadableKinds(
    AppDatabase database,
    BackupTarget target,
  ) async {
    final unreadable = unreadableEntitySourceKeys(target);
    if (unreadable.isEmpty) return;
    final extensionKinds = <String>[
      for (final kind in BusinessEntityKind.values)
        if (unreadable.contains(kind.sourceKey) && kind.extensionKind != null)
          kind.extensionKind!,
    ];
    if (extensionKinds.isNotEmpty) {
      final placeholders = List.filled(extensionKinds.length, '?').join(', ');
      await database.customStatement(
        'DELETE FROM extension_entity_rows WHERE kind IN ($placeholders);',
        extensionKinds,
      );
    }
    if (!target.knowsSourceKey(BusinessEntityKind.groupChat.sourceKey)) {
      final path = '\$."${Conversation.groupChatIdKey}"';
      await database.customStatement(
        'UPDATE conversation_rows '
        "SET extras_json = json_remove(extras_json, '$path') "
        'WHERE json_valid(extras_json) '
        "AND json_type(extras_json, '$path') IS NOT NULL;",
      );
    }
  }
}
