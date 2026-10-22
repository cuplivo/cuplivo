import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:Cuplivo/core/database/business_data.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
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
      // Read the clock straight from SQLite: the assertion is about what the
      // restore wrote, not about what a cache reports.
      final clock =
          (await database
                  .customSelect(
                    'SELECT updated_at FROM assistant_rows WHERE id = ?;',
                    variables: [const Variable<String>('a2')],
                  )
                  .getSingle())
              .read<int>('updated_at');
      expect(
        clock,
        greaterThan(stagedClock),
        reason: 'a restored row must win the next comparison, not lose again',
      );
    });

    test('a row that is back is not written over', () async {
      await setAssistants([(id: 'a1', name: 'Ada'), (id: 'a2', name: 'Bob')]);
      await setAssistants([(id: 'a1', name: 'Ada')]);
      final entry = (await binEntries()).single;

      // The same id exists again — what a peer re-sending the row, or the user
      // re-creating it, leaves behind. It is not the version this entry lost to,
      // so writing over it would discard content nothing asked to replace.
      await setAssistants([
        (id: 'a1', name: 'Ada'),
        (id: 'a2', name: 'Bob EDITED SINCE'),
      ]);

      expect(
        await recycle.restore(entry),
        RecycleRestoreOutcome.skippedExisting,
      );

      expect(
        (await repository.readEntities(
          BusinessEntityKind.assistant,
        )).firstWhere((row) => row.id == 'a2').payload,
        contains('EDITED SINCE'),
      );
      expect(
        await binEntries(),
        hasLength(1),
        reason: 'nothing was restored, so nothing is retired',
      );
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
