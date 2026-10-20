import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_data.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/services/recycle/recycle_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Recovery for user-managed rows: a deleted assistant (and every other entity
/// kind on the same path) and a setting a last-write-wins comparison replaced.
void main() {
  group('business row recovery', () {
    late Directory root;
    late AppDatabase database;
    late RecycleStore store;
    late RecycleService recycle;
    late BusinessRepository repository;
    late BusinessPreferences preferences;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kelivo_recycle_business_');
      database = AppDatabase(NativeDatabase.memory());
      store = RecycleStore(directory: () async => root);
      recycle = RecycleService(database, store: store);
      repository = BusinessRepository(database, recycle: recycle);
      preferences = BusinessPreferences(repository);
      await preferences.load();
    });

    tearDown(() async {
      await database.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    /// The bin writes *after* the operation that fed it — a delete or a merge
    /// must not wait for its own safety net — so an assertion about the bin lets
    /// that write finish first. The "stages nothing" tests go through here for
    /// the same reason and one more: without it they would pass merely because
    /// the write had not started yet.
    Future<List<RecycleEntry>> binEntries() async {
      await recycle.settle();
      return recycle.list();
    }

    Future<void> setAssistants(
      List<({String id, String name})> list,
    ) => preferences.setString(
      'assistants_v1',
      '[${[for (final item in list) '{"id":"${item.id}","name":"${item.name}"}'].join(',')}]',
    );

    test('a removed assistant is staged and can be restored', () async {
      await setAssistants([(id: 'a1', name: 'Ada'), (id: 'a2', name: 'Bob')]);

      await setAssistants([(id: 'a1', name: 'Ada')]);

      final entry = (await binEntries()).single;
      expect(entry.type, RecycleEntryType.businessEntity);
      expect(entry.kindWire, 'assistant_rows');
      expect(entry.key, 'a2');
      expect(entry.title, 'Bob');
      expect(entry.origin, RecycleOrigin.local);
      expect(entry.reason, RecycleReason.deleted);
      expect(
        (await repository.readEntities(
          BusinessEntityKind.assistant,
        )).map((row) => row.id),
        ['a1'],
      );
      final stagedClock =
          (await store.readTables(
                entry,
              ))!['assistant_rows']!.single['updated_at']!
              as int;

      expect(await recycle.restore(entry), RecycleRestoreOutcome.restored);

      expect(
        (await repository.readEntities(
          BusinessEntityKind.assistant,
        )).map((row) => row.id),
        containsAll(<String>['a1', 'a2']),
      );
      expect(await binEntries(), isEmpty);
      final clock = (await repository.syncEntityRefs())
          .firstWhere((ref) => ref.id == 'a2')
          .updatedAtUs;
      expect(
        clock,
        greaterThan(stagedClock),
        reason: 'a restored row must win the next comparison, not lose again',
      );
    });

    test('a losing local edit is staged, an identical echo is not', () async {
      await setAssistants([(id: 'a1', name: 'Mine')]);
      final mineAt = (await repository.syncEntityRefs())
          .firstWhere((ref) => ref.id == 'a1')
          .updatedAtUs;

      await repository.syncApplyBusinessRows(
        entities: {
          'assistant_rows': [
            {
              'id': 'a1',
              'sort_order': 0,
              'payload': '{"id":"a1","name":"Mine"}',
              'updated_at': mineAt,
            },
          ],
        },
        preferences: const [],
        myDeviceId: 'me',
        peerDeviceId: 'peer',
      );
      expect(
        await binEntries(),
        isEmpty,
        reason: 'an identical row coming back is not a lost edit',
      );

      final outcome = await repository.syncApplyBusinessRows(
        entities: {
          'assistant_rows': [
            {
              'id': 'a1',
              'sort_order': 0,
              'payload': '{"id":"a1","name":"Peer"}',
              'updated_at': mineAt,
            },
          ],
        },
        preferences: const [],
        myDeviceId: 'me',
        peerDeviceId: 'peer',
      );

      expect(outcome.entityRowsLost, 1);
      final entry = (await binEntries()).single;
      expect(entry.reason, RecycleReason.overwritten);
      expect(entry.origin, RecycleOrigin.remote);
      expect(entry.key, 'a1');
      expect(
        entry.title,
        'Mine',
        reason: 'the staged copy is the local row that lost',
      );
      final staged = (await store.readTables(
        entry,
      ))!['assistant_rows']!.single['payload'];
      expect(staged, contains('Mine'));
    });

    test('a preference that loses is staged and restorable', () async {
      await preferences.setString('user_name', 'Mine');
      final mineAt = (await repository.syncPreferenceRefs())
          .firstWhere((ref) => ref.key == 'user_name')
          .updatedAtUs;

      final outcome = await repository.syncApplyBusinessRows(
        entities: const {},
        preferences: [
          {'key': 'user_name', 'value': '"Peer"', 'updated_at': mineAt},
        ],
        myDeviceId: 'me',
        peerDeviceId: 'peer',
      );

      expect(outcome.preferencesLost, 1);
      final entry = (await binEntries()).single;
      expect(entry.type, RecycleEntryType.preference);
      expect(entry.key, 'user_name');
      expect(entry.reason, RecycleReason.overwritten);
      await preferences.reload();
      expect(preferences.getString('user_name'), 'Peer');

      expect(await recycle.restore(entry), RecycleRestoreOutcome.restored);

      await preferences.reload();
      expect(
        preferences.getString('user_name'),
        'Mine',
        reason: 'the value the comparison replaced is back',
      );
      final clock = (await repository.syncPreferenceRefs())
          .firstWhere((ref) => ref.key == 'user_name')
          .updatedAtUs;
      expect(clock, greaterThan(mineAt));
    });

    test('a peer deleting a row stages it before the delete', () async {
      await setAssistants([(id: 'a1', name: 'Ada')]);

      expect(await repository.syncDeleteEntity('assistant_rows', 'a1'), isTrue);

      final entry = (await binEntries()).single;
      expect(entry.origin, RecycleOrigin.remote);
      expect(entry.reason, RecycleReason.deleted);
      expect(
        await repository.readEntities(BusinessEntityKind.assistant),
        isEmpty,
      );

      expect(await recycle.restore(entry), RecycleRestoreOutcome.restored);

      expect(
        (await repository.readEntities(BusinessEntityKind.assistant)).single.id,
        'a1',
      );
    });

    test('a row this device keeps out of sync is not staged', () async {
      // A linked workspace is a folder the user already had, so sync never
      // offers it and a peer's delete naming it has nothing to remove. The
      // staging call must sit *after* that guard: placed before it, the refusal
      // still leaves a bin entry for a deletion that never happened, and the
      // bin would offer to restore a workspace this device never lost.
      await ExtensionEntityStore(database).upsert('workspace', 'linked-1', {
        'id': 'linked-1',
        'name': 'Notes',
        'kind': 'linked',
        'hostPath': '/home/me/notes',
        'shellNeedsApproval': false,
        'defaultCwd': '',
        'disabledTools': const <String>[],
        'createdAt': '2026-01-01T00:00:00.000Z',
        'updatedAt': '2026-01-01T00:00:00.000Z',
        'lastUsedAt': null,
      });

      expect(
        await repository.syncDeleteEntity('workspace', 'linked-1'),
        isFalse,
        reason:
            'a row this device never announced is not removable through sync',
      );

      expect(
        await binEntries(),
        isEmpty,
        reason: 'a refused delete removes nothing, so there is nothing to keep',
      );
      expect(
        (await repository.readEntities(BusinessEntityKind.workspace)).single.id,
        'linked-1',
      );
    });

    test('a peer deleting a preference stages it before the delete', () async {
      await preferences.setString('user_name', 'Mine');

      expect(await repository.syncDeletePreference('user_name'), isTrue);

      final entry = (await binEntries()).single;
      expect(entry.type, RecycleEntryType.preference);
      expect(entry.origin, RecycleOrigin.remote);
      expect(entry.reason, RecycleReason.deleted);

      expect(await recycle.restore(entry), RecycleRestoreOutcome.restored);

      await preferences.reload();
      expect(preferences.getString('user_name'), 'Mine');
    });

    test('a bulk clear stages nothing', () async {
      await setAssistants([(id: 'a1', name: 'Ada'), (id: 'a2', name: 'Bob')]);

      await repository.clearAll();

      expect(
        await binEntries(),
        isEmpty,
        reason: 'replacing every row is not a deletion of any one row',
      );
    });
  });
}
