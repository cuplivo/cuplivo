import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/backup_portability.dart';
import 'package:Cuplivo/core/database/business_data.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/business_restore_service.dart';
import 'package:Cuplivo/core/database/business_settings_router.dart';
import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/models/backup_target.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/backup/data_sync.dart';

Map<String, Object> _workspace(String id, {bool linked = false}) => {
  'id': id,
  'name': id,
  'kind': linked ? 'linked' : 'managed',
  'hostPath': '/source/$id',
  'lastUsedAt': '2026-09-11T00:00:00Z',
};

/// Every conversation's `extras_json`, decoded, keyed by conversation id.
Future<Map<String, Map<String, dynamic>>> _conversationExtras(
  AppDatabase database,
) async {
  final rows = await database
      .customSelect('SELECT id, extras_json FROM conversation_rows')
      .get();
  return {
    for (final row in rows)
      row.read<String>('id'):
          jsonDecode(row.read<String>('extras_json')) as Map<String, dynamic>,
  };
}

void main() {
  late AppDatabase database;
  late BusinessRepository repository;
  late ExtensionEntityStore store;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    repository = BusinessRepository(database);
    store = ExtensionEntityStore(database);
    final prefs = BusinessPreferences(repository);
    for (final key in BackupPortability.devicePreferenceKeys) {
      await prefs.setString(key, 'local-$key');
    }
    await prefs.setString('environment_mirrors_v1', '{}');
    await store.upsert('workspace', 'managed', _workspace('managed'));
    await store.upsert(
      'workspace',
      'linked',
      _workspace('linked', linked: true),
    );
    await store.upsert('externalMounts', 'global', {
      'mounts': [
        {'bookmark': 'local-bookmark', 'sourcePath': '/local/folder'},
      ],
    });
  });

  tearDown(() => database.close());

  test(
    'settings export excludes device data and keeps row identities aligned',
    () async {
      final before = await repository.readSnapshot();
      final exported = await DataSync.exportBusinessSettingsFrom(repository);
      final settings =
          jsonDecode(exported.settingsJson) as Map<String, dynamic>;
      for (final key in BackupPortability.devicePreferenceKeys) {
        expect(settings, isNot(contains(key)));
      }
      expect(settings['environment_mirrors_v1'], '{}');
      final workspaces =
          jsonDecode(settings['workspaces_v1'] as String) as List;
      expect(workspaces.single['id'], 'managed');
      expect(workspaces.single, isNot(contains('hostPath')));
      expect(workspaces.single, isNot(contains('lastUsedAt')));
      expect(exported.entityRowIds['workspaces_v1'], ['managed']);
      BusinessSettingsRouter.normalizeAndRoute(
        settings,
        entityRowIds: exported.entityRowIds,
      );
      expect((await repository.readSnapshot()).preferences, before.preferences);
      expect(await store.get('workspace', 'linked'), isNotNull);
    },
  );

  for (final merge in [false, true]) {
    test(
      '${merge ? 'merge' : 'overwrite'} ignores old device state and preserves local state',
      () async {
        final service = BusinessRestoreService(repository);
        final incoming = <String, Object?>{
          for (final key in BackupPortability.devicePreferenceKeys)
            key: {'old': 'invalid-device-value'},
          'workspaces_v1': jsonEncode([
            _workspace('foreign-linked', linked: true),
            _workspace('foreign-managed'),
          ]),
          'assistants_v1': jsonEncode([
            {'id': 'assistant', 'defaultWorkspaceId': 'foreign-linked'},
          ]),
        };
        if (merge) {
          await service.merge(incoming);
        } else {
          await service.overwrite(incoming);
        }
        final snapshot = await repository.readSnapshot();
        for (final key in BackupPortability.devicePreferenceKeys) {
          expect(snapshot.preferences[key], 'local-$key');
        }
        expect(await store.get('workspace', 'linked'), isNotNull);
        expect(await store.get('workspace', 'foreign-linked'), isNull);
        expect(await store.get('workspace', 'foreign-managed'), isNotNull);
        expect(await store.get('externalMounts', 'global'), isNotNull);
        final settings = await service.exportSettings();
        expect(
          (jsonDecode(settings['assistants_v1'] as String) as List).single,
          isNot(contains('defaultWorkspaceId')),
        );
      },
    );
  }

  test(
    'raw SQLite sanitization removes grants and detaches linked chats only',
    () async {
      for (final id in ['managed', 'linked']) {
        await database.customStatement(
          'INSERT INTO conversation_rows (id, title, created_at, updated_at, extras_json) VALUES (?, ?, 0, 0, ?)',
          [
            id,
            id,
            jsonEncode({
              'workspace.id': id,
              'workspace.cwd': 'src',
              'workspace.tools_used': true,
              'workspace.allowAll': true,
              'tools.permission_mode': 'fullAccess',
              'other.feature': 'keep',
            }),
          ],
        );
      }
      await BackupPortability.sanitizeDatabase(database);
      expect(await store.get('workspace', 'linked'), isNull);
      expect(await store.get('externalMounts', 'global'), isNull);
      expect(
        (await repository.readSnapshot()).preferences.keys,
        isNot(anyElement(isIn(BackupPortability.devicePreferenceKeys))),
      );
      final rows = await database
          .customSelect('SELECT id, extras_json FROM conversation_rows')
          .get();
      for (final row in rows) {
        final extras = jsonDecode(row.read<String>('extras_json')) as Map;
        expect(extras['other.feature'], 'keep');
        expect(extras, isNot(contains('workspace.allowAll')));
        expect(extras, isNot(contains('tools.permission_mode')));
        if (row.read<String>('id') == 'managed') {
          expect(extras['workspace.id'], 'managed');
          expect(extras['workspace.cwd'], 'src');
        } else {
          expect(extras.keys, ['other.feature']);
        }
      }
    },
  );

  test(
    'a Kelivo-target sanitization drops the group rows and their chat links',
    () async {
      // The database half of a Kelivo-target archive. `_dropUnreadableKinds`
      // removes the rows of a kind that release has no name for *and* the
      // conversation link that points at them: half a repair would leave an
      // archive whose manifest names a kind its own database no longer carries.
      final kind = BusinessEntityKind.groupChat.extensionKind!;
      await store.upsert(kind, 'g1', {
        'id': 'g1',
        'name': 'topic',
        'members': ['a1', 'a2'],
      });
      for (final row in <(String, Map<String, Object?>)>[
        (
          'c-group',
          {Conversation.groupChatIdKey: 'g1', 'other.feature': 'keep'},
        ),
        ('c-plain', {'other.feature': 'keep'}),
      ]) {
        await database.customStatement(
          'INSERT INTO conversation_rows '
          '(id, title, created_at, updated_at, extras_json) VALUES (?, ?, 0, 0, ?)',
          [row.$1, row.$1, jsonEncode(row.$2)],
        );
      }

      await BackupPortability.sanitizeDatabase(
        database,
        target: BackupTarget.kelivoV1_3_4,
      );

      expect(await store.get(kind, 'g1'), isNull);
      final extras = await _conversationExtras(database);
      for (final id in ['c-group', 'c-plain']) {
        // Narrowed, not emptied: an unrelated extras key survives, and so does
        // the conversation that lost its group.
        expect(extras[id], {'other.feature': 'keep'}, reason: id);
      }
    },
  );

  test('the default target keeps the group and the link to it', () async {
    final kind = BusinessEntityKind.groupChat.extensionKind!;
    await store.upsert(kind, 'g1', {'id': 'g1', 'name': 'topic'});
    await database.customStatement(
      'INSERT INTO conversation_rows '
      '(id, title, created_at, updated_at, extras_json) VALUES (?, ?, 0, 0, ?)',
      [
        'c-group',
        'c-group',
        jsonEncode({Conversation.groupChatIdKey: 'g1'}),
      ],
    );

    await BackupPortability.sanitizeDatabase(database);

    // The guard is only a guard if the state it removes really is there.
    expect(await store.get(kind, 'g1'), isNotNull);
    expect(
      (await _conversationExtras(
        database,
      ))['c-group']![Conversation.groupChatIdKey],
      'g1',
    );
  });
}
