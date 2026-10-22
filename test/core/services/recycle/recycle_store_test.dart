import 'dart:io';

import 'package:Cuplivo/core/services/recycle/recycle_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The bin's storage rules on their own: one file per small row set, a body
/// file only for the two shapes that can be large, newest-wins listing, and
/// eviction that is bounded by age, bytes and entry count.
void main() {
  group('RecycleStore', () {
    late Directory root;
    late Directory work;
    late RecycleStore store;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kelivo_recycle_store_');
      work = await Directory.systemTemp.createTemp('kelivo_recycle_work_');
      store = RecycleStore(directory: () async => root);
    });

    tearDown(() async {
      for (final directory in [root, work]) {
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    });

    Future<RecycleEntry?> stageEntity(String id, {String title = 'Thing'}) =>
        store.stageRows(
          type: RecycleEntryType.businessEntity,
          origin: RecycleOrigin.local,
          reason: RecycleReason.deleted,
          key: id,
          title: title,
          kindWire: 'assistant_rows',
          tables: {
            'assistant_rows': [
              {
                'id': id,
                'sort_order': 0,
                'payload': '{"id":"$id"}',
                'updated_at': 1,
              },
            ],
          },
        );

    Future<RecycleEntry?> stageConversation(String id) => store.stageRows(
      type: RecycleEntryType.conversation,
      origin: RecycleOrigin.remote,
      reason: RecycleReason.deleted,
      key: id,
      title: 'Chat $id',
      tables: {
        'conversation_rows': [
          {'id': id, 'title': 'Chat $id', 'updated_at': 1},
        ],
        'message_rows': [
          {'id': '$id-m1', 'conversation_id': id, 'message_order': 0},
        ],
      },
    );

    test('a small row set is exactly one file', () async {
      final entry = await stageEntity('a1');

      expect(entry, isNotNull);
      expect(entry!.bodyKind, RecycleBodyKind.inline);
      final directories = await root.list().toList();
      expect(directories, hasLength(1));
      final files = await Directory(directories.single.path).list().toList();
      expect(files.map((file) => p.basename(file.path)), ['entry.json']);
    });

    test('the envelope records what the list shows', () async {
      final before = DateTime.now().toUtc();
      await stageEntity('a1', title: 'Ada');

      final listed = (await store.list()).single;
      expect(listed.id, isNotEmpty);
      expect(listed.type, RecycleEntryType.businessEntity);
      expect(listed.origin, RecycleOrigin.local);
      expect(listed.reason, RecycleReason.deleted);
      expect(listed.key, 'a1');
      expect(listed.title, 'Ada');
      expect(listed.kindWire, 'assistant_rows');
      expect(listed.sizeBytes, greaterThan(0));
      expect(
        listed.deletedAt.isBefore(before.subtract(const Duration(seconds: 1))),
        isFalse,
      );
    });

    test('staged tables survive the round trip', () async {
      final entry = await stageEntity('a1');

      final tables = await store.readTables(entry!);

      expect(tables, isNotNull);
      expect(tables!['assistant_rows'], hasLength(1));
      expect(tables['assistant_rows']!.single['payload'], '{"id":"a1"}');
    });

    test('a conversation keeps its subtree in a body file', () async {
      final entry = await stageConversation('c1');

      expect(entry!.bodyKind, RecycleBodyKind.jsonFile);
      final names = await Directory(
        p.join(root.path, entry.id),
      ).list().map((file) => p.basename(file.path)).toList();
      expect(names..sort(), ['body.json', 'entry.json']);
      final tables = await store.readTables(entry);
      expect(tables!['message_rows']!.single['id'], 'c1-m1');
    });

    test('a group rides the envelope, and its absence stays null', () async {
      final group = RecycleGroup(id: 'g1', label: '代码审查员');
      final grouped = await store.stageRows(
        type: RecycleEntryType.conversation,
        origin: RecycleOrigin.local,
        reason: RecycleReason.deleted,
        key: 'c1',
        title: 'Chat c1',
        group: group,
        tables: {
          'conversation_rows': [
            {'id': 'c1', 'title': 'Chat c1'},
          ],
        },
      );
      final plain = await stageEntity('a1');

      final listed = await store.list();
      final readBack = listed.firstWhere((entry) => entry.id == grouped!.id);
      expect(readBack.group, isNotNull);
      expect(readBack.group!.id, 'g1');
      expect(readBack.group!.label, '代码审查员');
      expect(listed.firstWhere((entry) => entry.id == plain!.id).group, isNull);
    });

    test('a group label that is too long is cut, like a title', () async {
      final long = 'x' * 400;
      await store.stageRows(
        type: RecycleEntryType.conversation,
        origin: RecycleOrigin.local,
        reason: RecycleReason.deleted,
        key: 'c1',
        title: 'Chat',
        group: RecycleGroup(id: 'g1', label: long),
        tables: {
          'conversation_rows': [
            {'id': 'c1'},
          ],
        },
      );

      final listed = (await store.list()).single;
      expect(listed.group!.label, hasLength(200));
    });

    test('a body that is gone reads as null, not as empty tables', () async {
      final entry = await stageConversation('c1');
      final body = File(p.join(root.path, entry!.id, 'body.json'));
      expect(await body.exists(), isTrue);

      await body.delete();

      expect(await store.readTables(entry), isNull);
      // A moved file is the other body shape, and a row entry has none.
      expect(await store.bodyFile(entry), isNull);
    });

    test('listing collapses entries that staged the same identity', () async {
      final first = await stageEntity('a1', title: 'First');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final second = await stageEntity('a1', title: 'Second');

      expect(first!.id, isNot(second!.id));
      final listed = await store.list();
      expect(listed, hasLength(1));
      expect(listed.single.id, second.id);
      expect(listed.single.title, 'Second');

      expect(await store.purgeKey(RecycleEntryType.businessEntity, 'a1'), 2);
      expect(await store.list(), isEmpty);
    });

    test('the entry just staged is never the one evicted', () async {
      final entry = await stageEntity('a1');
      final later = DateTime.now().toUtc().add(
        RecycleStore.defaultRetention + const Duration(days: 1),
      );

      expect(await store.evict(now: later, keepId: entry!.id), 0);
      // Left in place, the next pass has nothing holding it back.
      expect(await store.evict(now: later), 1);
      expect(await store.list(), isEmpty);
    });

    test('the entry cap evicts oldest first', () async {
      final bounded = RecycleStore(directory: () async => root, maxEntries: 2);
      await bounded.stageRows(
        type: RecycleEntryType.preference,
        origin: RecycleOrigin.remote,
        reason: RecycleReason.overwritten,
        key: 'first',
        title: 'first',
        tables: {
          'preference_rows': [
            {'key': 'first', 'value': '"1"', 'updated_at': 1},
          ],
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await bounded.stageRows(
        type: RecycleEntryType.preference,
        origin: RecycleOrigin.remote,
        reason: RecycleReason.overwritten,
        key: 'second',
        title: 'second',
        tables: {
          'preference_rows': [
            {'key': 'second', 'value': '"2"', 'updated_at': 2},
          ],
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await bounded.stageRows(
        type: RecycleEntryType.preference,
        origin: RecycleOrigin.remote,
        reason: RecycleReason.overwritten,
        key: 'third',
        title: 'third',
        tables: {
          'preference_rows': [
            {'key': 'third', 'value': '"3"', 'updated_at': 3},
          ],
        },
      );
      // Staging coalesces its eviction: the caps hold once the burst's sweep
      // lands, not after every write.
      await bounded.settle();

      final kept = (await bounded.list()).map((entry) => entry.key);
      expect(kept, containsAll(<String>['second', 'third']));
      expect(kept, isNot(contains('first')));
    });

    test('a burst of staging costs one sweep, not one per entry', () async {
      // The shape an assistant's cascade produces: one entry per conversation,
      // staged back to back. Each sweep reads every entry in the bin, so a sweep
      // per entry made the burst quadratic in the bin's size.
      for (var i = 0; i < 20; i++) {
        await stageEntity('burst-$i');
      }
      expect(store.scanCount, 0, reason: 'staging no longer sweeps by itself');
      expect(await store.list(), hasLength(20));

      final scansBefore = store.scanCount;
      await store.settle();
      expect(
        store.scanCount - scansBefore,
        1,
        reason: 'twenty staged entries are one sweep, not twenty',
      );
    });

    test('an unreadable entry is reclaimed by evict, not by list', () async {
      final broken = Directory(p.join(root.path, '1700000000000000-broken'));
      await broken.create(recursive: true);
      await File(p.join(broken.path, 'entry.json')).writeAsString('{');

      expect(await store.list(), isEmpty);
      expect(await broken.exists(), isTrue, reason: 'listing is read-only');
      expect(await store.evict(), greaterThanOrEqualTo(1));
      expect(await broken.exists(), isFalse);
    });

    test('an entry directory with no entry.json is reclaimed', () async {
      final bodyless = Directory(p.join(root.path, '1700000000000000-empty'));
      await bodyless.create(recursive: true);

      expect(await store.list(), isEmpty);
      expect(await store.evict(), greaterThanOrEqualTo(1));
      expect(await bodyless.exists(), isFalse);
    });

    test('a half-written staging directory is cleaned up', () async {
      final staging = Directory(
        p.join(root.path, '.tmp-1700000000000000-abcd'),
      );
      await staging.create(recursive: true);

      expect(await store.list(), isEmpty);
      expect(await store.evict(), greaterThanOrEqualTo(1));
      expect(await staging.exists(), isFalse);
    });

    test('staging a workspace file moves its bytes and its mtime', () async {
      final source = File(p.join(work.path, 'note.txt'));
      await source.writeAsString('hello');
      final mtime = await source.lastModified();

      final entry = await store.stageFile(
        workspaceId: 'w1',
        relPath: 'docs/note.txt',
        source: source,
        origin: RecycleOrigin.remote,
        reason: RecycleReason.overwritten,
      );

      expect(entry, isNotNull);
      expect(await source.exists(), isFalse, reason: 'moved, not copied');
      expect(entry!.type, RecycleEntryType.workspaceFile);
      expect(entry.bodyKind, RecycleBodyKind.byteFile);
      expect(entry.key, 'w1\u0000docs/note.txt');
      expect(entry.workspaceId, 'w1');
      expect(entry.relPath, 'docs/note.txt');
      expect(entry.mtimeMs, mtime.millisecondsSinceEpoch);
      final body = await store.bodyFile(entry);
      expect(await body!.readAsString(), 'hello');
    });

    test('a row set cannot be staged as a workspace file', () async {
      final entry = await store.stageRows(
        type: RecycleEntryType.workspaceFile,
        origin: RecycleOrigin.local,
        reason: RecycleReason.deleted,
        key: 'w1\u0000a.txt',
        title: 'a.txt',
        tables: const {},
      );

      expect(entry, isNull);
      expect(await store.list(), isEmpty);
    });

    test('concurrent writes are never reaped by each other\'s sweep', () async {
      // The shape an assistant's cascade produces: several detached writes, each
      // of which runs eviction when it lands, so one write's sweep scans while
      // its siblings are still filling their `.tmp-` directories. A sweep that
      // treats those as crash leftovers silently loses entries the bin was asked
      // to keep — so this stages a batch, sweeps in the middle of it, and
      // demands every entry in the batch.
      for (var round = 0; round < 6; round++) {
        final keys = [for (var i = 0; i < 4; i++) 'r$round-$i'];
        await Future.wait<void>([
          for (final key in keys) stageEntity(key),
          store.evict(),
        ]);

        final listed = (await store.list()).map((entry) => entry.key).toSet();
        expect(
          keys.where(listed.contains),
          keys,
          reason: 'round $round lost a write that was in flight',
        );
        await store.clear();
      }
    });
  });
}
