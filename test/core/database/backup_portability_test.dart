import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
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
import 'package:Cuplivo/core/models/compression_config.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/tool_permission_mode.dart';
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

  test('a key with a quote cannot close the SQL literal around it', () async {
    // The sanitizer interpolates key names into SQL, and the keys are constants
    // today — so this is the one property of that statement a reviewer cannot
    // check by reading it, and the one that would break silently the day a key
    // gains a quote. Two quotes, two escaping layers: `"` closes the JSON path's
    // label, `'` closes the SQL literal around the path.
    for (final key in <String>["a'b", 'a"b', 'a"b\'c']) {
      final literal = BackupPortability.extrasSqlLiteral(key);
      final row = await database
          .customSelect(
            'SELECT json_extract(?, $literal) AS value_;',
            variables: [
              Variable.withString(jsonEncode({key: 1})),
            ],
          )
          .getSingle();
      expect(row.read<int>('value_'), 1, reason: key);
    }
  });

  test(
    'grants leave every archive, and a dangling binding leaves with them',
    () async {
      // One list, two branches: the grants are the set the sync wire strips, and
      // they are derived here rather than repeated; a binding whose workspace row
      // did not travel takes its own facts with it, because the id names nothing
      // in the restored database. Both halves are asserted by behaviour, so a
      // key added to the grant set reaches the sanitizer without a second edit.
      final grants = {
        for (final key in ToolPermissionMode.grantExtrasKeys) key: 'marker',
      };
      for (final row in <(String, Map<String, Object?>)>[
        (
          'bound',
          {'workspace.id': 'managed', ...grants, 'other.feature': 'keep'},
        ),
        (
          'dangling',
          {'workspace.id': 'gone', ...grants, 'other.feature': 'keep'},
        ),
      ]) {
        await database.customStatement(
          'INSERT INTO conversation_rows (id, title, created_at, updated_at, extras_json) VALUES (?, ?, 0, 0, ?)',
          [row.$1, row.$1, jsonEncode(row.$2)],
        );
      }

      await BackupPortability.sanitizeDatabase(database);

      final extras = await _conversationExtras(database);
      for (final id in ['bound', 'dangling']) {
        expect(
          extras[id]!.keys,
          isNot(anyElement(isIn(ToolPermissionMode.grantExtrasKeys))),
          reason: id,
        );
        expect(extras[id]!['other.feature'], 'keep', reason: id);
      }
      // The live binding keeps its folder: the workspace row travels, so the
      // relative folder still names a directory in the archive.
      expect(extras['bound']!['workspace.id'], 'managed');
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
        target: BackupTarget.kelivo,
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

  test(
    'the compression library travels in settings, not in the snapshot',
    () async {
      const template = CompressionTemplate(
        id: 'custom',
        name: 'My RP',
        prompt: 'Keep secrets separate {content}',
      );
      await store.upsert(
        CompressionTemplate.entityKind,
        template.id,
        template.toJson(),
      );
      await store.upsert(
        CompressionRecipe.entityKind,
        'recipe',
        CompressionRecipe(
          id: 'recipe',
          name: 'Tight',
          template: template,
          settings: const CompressionConfig(),
        ).toJson(),
      );

      // The settings half carries the two rows as business kinds, so an archive
      // that writes it has them twice if the database keeps its copy too.
      final exported = BusinessSettingsRouter.exportSnapshotWithRowIds(
        BackupPortability.portable(await repository.readSnapshot()),
      );
      expect(
        exported.settings.keys,
        containsAll([
          BusinessEntityKind.compressionTemplate.sourceKey,
          BusinessEntityKind.compressionRecipe.sourceKey,
        ]),
      );

      // An archive from a build that exported no such keys keeps the database
      // copy: it is that archive's only carrier, which is why the caller states
      // whether its settings carry the library instead of the table implying it.
      await BackupPortability.sanitizeDatabase(database);
      expect(
        await store.listByKind(CompressionTemplate.entityKind),
        hasLength(1),
      );

      await BackupPortability.sanitizeDatabase(
        database,
        libraryInSettings: true,
      );
      expect(await store.listByKind(CompressionTemplate.entityKind), isEmpty);
      expect(await store.listByKind(CompressionRecipe.entityKind), isEmpty);
    },
  );

  test('a library the archive does not name survives its overwrite', () async {
    // The library lived only in the snapshot database before it became two
    // business kinds, so an archive from an earlier build carries every
    // template in the database half and no key in the settings half. The
    // missing key is the archive saying nothing, not the archive saying
    // "none": reading it as an empty library deletes what the archive carries.
    const template = CompressionTemplate(
      id: 'custom',
      name: 'My RP',
      prompt: 'Keep secrets separate {content}',
    );
    await store.upsert(
      CompressionTemplate.entityKind,
      template.id,
      template.toJson(),
    );

    await BusinessRestoreService(
      repository,
    ).overwrite({'theme_mode_v1': 'dark'});
    expect(
      await store.listByKind(CompressionTemplate.entityKind),
      hasLength(1),
    );

    // A key the archive does carry is still replaced, and an explicit empty
    // list is the archive saying it has none of that kind.
    await BusinessRestoreService(
      repository,
    ).overwrite({'compression_templates_v1': jsonEncode(const <Object>[])});
    expect(await store.listByKind(CompressionTemplate.entityKind), isEmpty);
  });
}
