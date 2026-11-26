import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'app_database.dart';
import '../models/backup_scope.dart';
import '../models/backup_target.dart';
import '../models/compression_config.dart';
import '../models/tool_permission_mode.dart';
import '../models/workspace_binding.dart';
import 'backup_content_filter.dart';
import 'business_data.dart';
import 'business_repository.dart';
import 'business_settings_router.dart';

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
  static Future<void> sanitizeDatabase(
    AppDatabase database, {
    BackupScope scope = const BackupScope(),
    BackupTarget target = BackupTarget.cuplivo,
    bool libraryInSettings = false,
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
      // One fact, one carrier. The compression library travels in `settings.json`
      // as two business kinds now, so the same rows in the snapshot database are
      // a second copy of it: a merge restore imports both — the database's under
      // `merge-…` ids, the settings' under the original ids — and the user sees
      // every template twice. An archive written before those keys existed has
      // the database as its only carrier, which is why the caller states this
      // rather than it being implied by the table.
      if (libraryInSettings) {
        await database.customStatement(
          'DELETE FROM extension_entity_rows WHERE kind IN (?, ?);',
          [CompressionTemplate.entityKind, CompressionRecipe.entityKind],
        );
      }
      await _dropUnreadableKinds(database, target);
      // Chat history remains readable, but imported chats cannot inherit a
      // directory grant or silently authorize shell execution on this device.
      // The grants are stripped from every archive, from the one spelling the
      // sync wire uses; a binding whose workspace row did not travel goes with
      // its own facts, because the id names nothing in the restored database and
      // the folder, the tools-used flag and the grant have no subject left.
      final grantKeys = ToolPermissionMode.grantExtrasKeys;
      final danglingKeys = {
        ...grantKeys,
        WorkspaceBinding.keyId,
        WorkspaceBinding.keyCwd,
        WorkspaceBinding.keyToolsUsed,
      };
      // The filter is generated from the keys each branch can remove, so a key
      // added to either set reaches the WHERE as well: a `json_remove` that names
      // a key the filter never looks at returns before it runs.
      final filterKeys = {...grantKeys, WorkspaceBinding.keyId};
      final touched = [
        for (final key in filterKeys)
          'json_type(extras_json, ${extrasSqlLiteral(key)}) IS NOT NULL',
      ].join(' OR ');
      await database.customStatement('''
        UPDATE conversation_rows SET extras_json = CASE
          WHEN json_extract(extras_json, '\$."workspace.id"') IS NOT NULL
            AND NOT EXISTS (
              SELECT 1 FROM extension_entity_rows
              WHERE kind = 'workspace'
                AND id = json_extract(extras_json, '\$."workspace.id"')
            )
          THEN json_remove(extras_json, ${_jsonRemoveArguments(danglingKeys)})
          ELSE json_remove(extras_json, ${_jsonRemoveArguments(grantKeys)})
        END
        WHERE json_valid(extras_json) AND ($touched);
      ''');
    });
  }

  /// [key]'s member path in `extras_json`, as a SQL string literal.
  ///
  /// The keys are code constants naming extras members, never user data, so
  /// interpolating them follows the rule `currentSchemaColumns` does. Two quote
  /// characters still have to be escaped, and they are different ones: `"` closes
  /// the JSON path's label, `'` closes the SQL literal wrapped around that path.
  /// Missing either turns the statement into something else, which is why
  /// `backup_portability_test.dart` runs a quote-bearing key through SQLite
  /// rather than trusting the format string.
  @visibleForTesting
  static String extrasSqlLiteral(String key) =>
      _sqlStringLiteral(_jsonPath(key));

  static String _jsonPath(String key) => '\$."${key.replaceAll('"', r'\"')}"';

  /// [value] as a single-quoted SQL string literal.
  static String _sqlStringLiteral(String value) =>
      "'${value.replaceAll("'", "''")}'";

  static String _jsonRemoveArguments(Set<String> keys) =>
      [for (final key in keys) extrasSqlLiteral(key)].join(', ');

  /// Takes every kind [target] cannot read out of the archive: its rows, and
  /// every conversation link that points at them.
  ///
  /// The halves belong together — an entity row without its settings key is an
  /// archive that contradicts itself, and so is a conversation naming a row that
  /// did not travel. Both halves are derived from [unreadableKindDispositions]
  /// rather than spelled out per kind here, so a kind added to that table leaves
  /// everywhere at once; a kind the table says nothing about, or one with no
  /// extension storage to drop, throws instead of being half-stripped.
  static Future<void> _dropUnreadableKinds(
    AppDatabase database,
    BackupTarget target,
  ) async {
    final unreadable = unreadableEntitySourceKeys(target);
    if (unreadable.isEmpty) return;
    final kinds = [
      for (final kind in BusinessEntityKind.values)
        if (unreadable.contains(kind.sourceKey)) kind,
    ];
    final extensionKinds = [
      for (final kind in kinds) droppableExtensionKind(kind),
    ];
    final placeholders = List.filled(extensionKinds.length, '?').join(', ');
    await database.customStatement(
      'DELETE FROM extension_entity_rows WHERE kind IN ($placeholders);',
      extensionKinds,
    );
    final links = conversationLinksToStrip(kinds);
    if (links.isEmpty) return;
    // Each path is a JSON path in Dart and a SQL string literal in the
    // statement, so it is quoted once for itself and once for SQLite.
    final paths = [for (final link in links) '\$."$link"'];
    final removals = [for (final path in paths) "'$path'"].join(', ');
    final touched = [
      for (final path in paths) "json_type(extras_json, '$path') IS NOT NULL",
    ].join(' OR ');
    await database.customStatement(
      'UPDATE conversation_rows '
      'SET extras_json = json_remove(extras_json, $removals) '
      'WHERE json_valid(extras_json) AND ($touched);',
    );
  }
}
