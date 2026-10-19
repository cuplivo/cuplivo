import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:Cuplivo/core/services/sync/sync_store.dart';
import 'package:Cuplivo/core/services/sync/workspace_content_index.dart';
import 'package:Cuplivo/core/services/sync/workspace_content_sync.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The workspace content plane's own half of the story: what it advertises,
/// what it serves, where a landed file may go, and what the ledger records.
/// The wire-level behaviour (two real devices, real HTTP) lives in
/// `sync_engine_integration_test.dart`.
void main() {
  late Directory root;
  late AppDatabase database;
  late BusinessRepository businessRepository;
  late ExtensionEntityStore store;
  late WorkspaceContentSync content;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ws-content-');
    database = AppDatabase(NativeDatabase.memory());
    businessRepository = BusinessRepository(database);
    store = ExtensionEntityStore(database);
    content = WorkspaceContentSync(
      businessRepository: businessRepository,
      store: SyncStore(Directory('${root.path}/sync')),
      resolveRoot: (id) async {
        final dir = Directory('${root.path}/workspaces/$id/files');
        await dir.create(recursive: true);
        return dir;
      },
    );
  });

  tearDown(() async {
    await database.close();
    try {
      await root.delete(recursive: true);
    } catch (_) {
      // A file still locked by the OS is not what these tests are about.
    }
  });

  Future<void> putWorkspace(
    String id, {
    String kind = 'managed',
    String? name,
    String? hostPath,
  }) => store.upsert('workspace', id, {
    'id': id,
    'name': name ?? id,
    'kind': kind,
    'hostPath': hostPath,
    'shellNeedsApproval': false,
    'defaultCwd': '',
    'disabledTools': const <String>[],
    'createdAt': '2026-01-01T00:00:00.000Z',
    'updatedAt': '2026-01-01T00:00:00.000Z',
    'lastUsedAt': null,
  });

  Future<File> putFile(
    String workspaceId,
    String relPath,
    String data, {
    int? mtimeMs,
  }) async {
    final file = File('${root.path}/workspaces/$workspaceId/files/$relPath');
    await file.parent.create(recursive: true);
    await file.writeAsString(data, flush: true);
    if (mtimeMs != null) {
      await file.setLastModified(DateTime.fromMillisecondsSinceEpoch(mtimeMs));
    }
    return file;
  }

  File workspaceFile(String workspaceId, String relPath) =>
      File('${root.path}/workspaces/$workspaceId/files/$relPath');

  /// A fetch that writes [data] into the destination and reports its length —
  /// the shape `SyncClientSession.fetchWorkspaceFile` has.
  WorkspaceFileFetcher fetcher(String data) =>
      (workspaceId, relPath, destination) async {
        await destination.writeAsString(data, flush: true);
        return data.length;
      };

  group('snapshots', () {
    test(
      'indexes managed workspaces and leaves linked folders alone',
      () async {
        await putWorkspace('w1', name: 'Notes');
        await putWorkspace(
          'w2',
          kind: 'linked',
          hostPath: '${root.path}/elsewhere',
        );
        await putFile('w1', 'a.txt', 'aa');

        final snapshots = await content.snapshots();

        expect(snapshots.length, 1);
        expect(snapshots.single.id, 'w1');
        expect(snapshots.single.name, 'Notes');
        expect(snapshots.single.index.files.keys, ['a.txt']);
        expect(snapshots.single.index.totalBytes, 2);
        expect(snapshots.single.enabled, isTrue);
        expect(snapshots.single.shared, isTrue);
      },
    );

    test('a workspace past the caps is indexed but not shared', () async {
      await putWorkspace('w1');
      await putFile('w1', 'a.txt', 'a');
      await putFile('w1', 'b.txt', 'b');
      await putFile('w1', 'c.txt', 'c');
      final strict = WorkspaceContentSync(
        businessRepository: businessRepository,
        store: SyncStore(Directory('${root.path}/sync')),
        resolveRoot: content.resolveRoot,
        maxFiles: 2,
      );

      final snapshot = (await strict.snapshots()).single;

      expect(snapshot.index.truncated, isTrue);
      expect(snapshot.enabled, isTrue, reason: 'the switch is still on');
      expect(
        snapshot.shared,
        isFalse,
        reason: 'over the cap means nothing rides, switch or not',
      );
      expect(strict.tablesOf([snapshot]).tables, isEmpty);
    });

    test('a workspace the table cap drops comes back as a count', () async {
      // Past the cap a shared workspace is dropped from the advertisement, and
      // the peer reads its absence as "no opinion": it plans nothing, nothing
      // transfers, and no transfer failure names it. The drop is deterministic
      // by id, so without this count that workspace would never sync again and
      // the user would never be told why.
      await putWorkspace('w1');
      await putWorkspace('w2');
      await putFile('w1', 'a.txt', 'a');
      await putFile('w2', 'b.txt', 'b');
      final capped = WorkspaceContentSync(
        businessRepository: businessRepository,
        store: SyncStore(Directory('${root.path}/sync')),
        resolveRoot: content.resolveRoot,
        maxLedgerEntries: 1,
      );

      final advertised = capped.tablesOf(await capped.snapshots());

      expect(advertised.tables.keys, [
        'w1',
      ], reason: 'sorted by id, the first one fits');
      expect(
        advertised.droppedWorkspaces,
        1,
        reason:
            'what the peer will read as "not shared" is named to the report',
      );
    });

    test('an index that could not be read is not shared at all', () async {
      await putWorkspace('w1');
      await putFile('w1', 'a.txt', 'x');
      final walked = (await content.snapshots()).single;

      // The same workspace as the walk saw it, minus a file it could not read.
      final partial = WorkspaceContentSnapshot(
        id: walked.id,
        name: walked.name,
        root: walked.root,
        enabled: true,
        index: const WorkspaceContentIndex({}, totalBytes: 0, incomplete: true),
      );

      expect(partial.shared, isFalse);
      expect(
        content.tablesOf([partial]).tables,
        isEmpty,
        reason:
            'a table missing a file would tell the peer to delete that file',
      );

      // And it deletes nothing here either: the ledger says both sides agreed
      // on a file this index cannot see, which is exactly the reading that
      // would remove it.
      final mine = walked.index.files['a.txt']!;
      final outcome = await content.applyIncoming(
        myDeviceId: 'me',
        peerDeviceId: 'peer',
        mine: [partial],
        peerTables: const {'w1': <String, WorkspaceFileStamp>{}},
        ledger: {
          'w1': {'a.txt': SyncAgreedFile(mine, mine)},
        },
        allowDeletes: true,
        fetch: null,
      );

      expect(outcome.filesRemoved, 0);
      expect(workspaceFile('w1', 'a.txt').existsSync(), isTrue);
    });

    test('a root that cannot be resolved is reported, not dropped', () async {
      // The panel has to be able to say "this one is not syncing": a root that
      // could not even be resolved (an unwritable app data directory, a full
      // disk) still produces a row — one that shares nothing, and says so.
      await putWorkspace('w1', name: 'Notes');
      final broken = WorkspaceContentSync(
        businessRepository: businessRepository,
        store: SyncStore(Directory('${root.path}/sync')),
        resolveRoot: (id) async => throw const FileSystemException('no room'),
      );

      final snapshot = (await broken.snapshots()).single;

      expect(snapshot.id, 'w1');
      expect(snapshot.name, 'Notes');
      expect(snapshot.root, isNull);
      expect(snapshot.index.incomplete, isTrue);
      expect(snapshot.shared, isFalse);
      expect(broken.tablesOf([snapshot]).tables, isEmpty);

      // Nothing is served for it either, and the report counts it as a
      // workspace that is not syncing its files.
      broken.publish('peer', [snapshot]);
      expect(
        await broken.serve(
          peerDeviceId: 'peer',
          workspaceId: 'w1',
          relPath: 'a.txt',
        ),
        isNull,
      );
      final outcome = await broken.applyIncoming(
        myDeviceId: 'me',
        peerDeviceId: 'peer',
        mine: [snapshot],
        peerTables: const {},
        ledger: const {},
        allowDeletes: true,
        fetch: null,
      );
      expect(outcome.workspacesOmitted, 1);
    });

    test('an id that is a path never reaches the resolver', () async {
      // Defence in depth on top of the row filter: even a row written straight
      // to the store (bypassing the wire's own guard) never gets a root
      // resolved, because the id set the content plane asks for is already
      // filtered.
      await putWorkspace('..');
      final asked = <String>[];
      final guarded = WorkspaceContentSync(
        businessRepository: businessRepository,
        store: SyncStore(Directory('${root.path}/sync')),
        resolveRoot: (id) async {
          asked.add(id);
          throw StateError('the resolver must not be asked for $id');
        },
      );

      expect(await guarded.snapshots(), isEmpty);
      expect(asked, isEmpty);
    });
  });

  group('the switch', () {
    test(
      'is off-by-default-on, stored as the disabled set, written once',
      () async {
        await putWorkspace('w1');

        expect(await content.disabledWorkspaceIds(), isEmpty);
        expect((await content.snapshots()).single.enabled, isTrue);

        expect(await content.setEnabled('w1', false), isTrue);
        final settings = File('${root.path}/sync/workspaces.json');
        expect(await settings.exists(), isTrue);
        expect(await settings.readAsString(), contains('w1'));
        expect(await content.disabledWorkspaceIds(), {'w1'});
        expect((await content.snapshots()).single.enabled, isFalse);

        expect(
          await content.setEnabled('w1', false),
          isFalse,
          reason: 'nothing changed, so nothing is written',
        );
        expect(await content.setEnabled('w1', true), isTrue);
        expect(await content.disabledWorkspaceIds(), isEmpty);
        expect((await content.snapshots()).single.enabled, isTrue);
      },
    );

    test('two switches landing at once both survive', () async {
      // The set is one file holding every workspace's choice, so a read-edit-write
      // per caller is a lost update by construction: in a single isolate both
      // reads complete before either write, and the second writer's set is the
      // first one *minus* the other's id. Flipping two workspaces off in the same
      // turn — or a switch and a session's own read — must therefore go through
      // one serialized mutation, not two overlapping ones.
      await putWorkspace('w1');
      await putWorkspace('w2');

      await Future.wait([
        content.setEnabled('w1', false),
        content.setEnabled('w2', false),
      ]);

      expect(await content.disabledWorkspaceIds(), {
        'w1',
        'w2',
      }, reason: 'neither switch may erase the other');
    });

    test(
      'a switch flipped off drops what was advertised for the peer',
      () async {
        // The advertisement is a session's promise, so the one caller that can
        // invalidate it mid-session is the switch itself.
        await putWorkspace('w1');
        await putFile('w1', 'a.txt', 'x');
        content.publish('peer-1', await content.snapshots());
        expect(
          await content.serve(
            peerDeviceId: 'peer-1',
            workspaceId: 'w1',
            relPath: 'a.txt',
          ),
          isNotNull,
          reason: 'advertised while the switch was on',
        );

        await content.setEnabled('w1', false);

        expect(
          await content.serve(
            peerDeviceId: 'peer-1',
            workspaceId: 'w1',
            relPath: 'a.txt',
          ),
          isNull,
          reason: 'a promise the user just revoked is not still servable',
        );
      },
    );

    test('a session that ended serves nothing afterwards', () async {
      await putWorkspace('w1');
      await putFile('w1', 'a.txt', 'x');
      content.publish('peer-1', await content.snapshots());
      content.clearServed('peer-1');

      expect(
        await content.serve(
          peerDeviceId: 'peer-1',
          workspaceId: 'w1',
          relPath: 'a.txt',
        ),
        isNull,
        reason: 'the table belonged to the session that published it',
      );
      expect(
        await content.serve(
          peerDeviceId: 'peer-2',
          workspaceId: 'w1',
          relPath: 'a.txt',
        ),
        isNull,
        reason: 'and clearing one peer says nothing about another',
      );
    });
  });

  group('publish and serve', () {
    test(
      'serves an advertised file, and only while it is that version',
      () async {
        await putWorkspace('w1');
        await putFile('w1', 'a.txt', 'first');
        final snapshot = (await content.snapshots()).single;
        content.publish('peer-1', [snapshot]);

        final served = await content.serve(
          peerDeviceId: 'peer-1',
          workspaceId: 'w1',
          relPath: 'a.txt',
        );
        expect(served, isNotNull);
        expect(await served!.readAsString(), 'first');
        expect(
          await content.serve(
            peerDeviceId: 'peer-1',
            workspaceId: 'w1',
            relPath: 'b.txt',
          ),
          isNull,
          reason: 'never advertised',
        );
        expect(
          await content.serve(
            peerDeviceId: 'peer-2',
            workspaceId: 'w1',
            relPath: 'a.txt',
          ),
          isNull,
          reason: 'published to peer-1 only',
        );

        await putFile('w1', 'a.txt', 'second version, longer');
        expect(
          await content.serve(
            peerDeviceId: 'peer-1',
            workspaceId: 'w1',
            relPath: 'a.txt',
          ),
          isNull,
          reason: 'the bytes are no longer the version that was advertised',
        );
      },
    );

    test('a workspace that is not shared publishes nothing', () async {
      await putWorkspace('w1');
      await putFile('w1', 'a.txt', 'x');
      await content.setEnabled('w1', false);

      content.publish('peer-1', await content.snapshots());

      expect(
        await content.serve(
          peerDeviceId: 'peer-1',
          workspaceId: 'w1',
          relPath: 'a.txt',
        ),
        isNull,
      );
    });
  });

  group('applyIncoming', () {
    test(
      'fetches, stamps the file with the peer mtime, records both',
      () async {
        await putWorkspace('w1');
        const advertised = WorkspaceFileStamp(size: 5, mtimeMs: 1700000000000);

        final outcome = await content.applyIncoming(
          myDeviceId: 'me',
          peerDeviceId: 'peer',
          mine: await content.snapshots(),
          peerTables: const {
            'w1': {'a.txt': advertised},
          },
          ledger: const {},
          allowDeletes: true,
          fetch: fetcher('hello'),
        );

        expect(outcome.filesLanded, 1);
        expect(outcome.bytesLanded, 5);
        expect(outcome.filesMissing, 0);
        final file = workspaceFile('w1', 'a.txt');
        expect(await file.readAsString(), 'hello');
        expect(
          file.statSync().modified.millisecondsSinceEpoch,
          advertised.mtimeMs,
          reason: 'the landed file carries the peer\'s edit time',
        );
        final entry = outcome.ledger['w1']!['a.txt']!;
        expect(entry.peer, advertised);
        expect(entry.mine.size, 5);
      },
    );

    test('a crafted path never reaches the disk', () async {
      await putWorkspace('w1');
      const advertised = WorkspaceFileStamp(size: 4, mtimeMs: 1000);

      final outcome = await content.applyIncoming(
        myDeviceId: 'me',
        peerDeviceId: 'peer',
        mine: await content.snapshots(),
        peerTables: const {
          'w1': {
            '../escape.txt': advertised,
            'a/../../b.txt': advertised,
            'C:/absolute.txt': advertised,
            r'a\backslash.txt': advertised,
          },
        },
        ledger: const {},
        allowDeletes: true,
        fetch: fetcher('evil'),
      );

      expect(outcome.filesMissing, 4);
      expect(outcome.filesLanded, 0);
      expect(outcome.ledger, isEmpty);
      for (final path in [
        '${root.path}/workspaces/w1/escape.txt',
        '${root.path}/workspaces/escape.txt',
        '${root.path}/escape.txt',
        '${root.path}/workspaces/w1/files/b.txt',
      ]) {
        expect(File(path).existsSync(), isFalse, reason: path);
      }
    });

    test(
      'a landed size that disagrees with the advertisement is refused',
      () async {
        await putWorkspace('w1');

        final outcome = await content.applyIncoming(
          myDeviceId: 'me',
          peerDeviceId: 'peer',
          mine: await content.snapshots(),
          peerTables: const {
            'w1': {'a.txt': WorkspaceFileStamp(size: 5, mtimeMs: 1000)},
          },
          ledger: const {},
          allowDeletes: true,
          fetch: fetcher('abc'),
        );

        expect(outcome.filesMissing, 1);
        expect(outcome.filesLanded, 0);
        expect(
          outcome.unlanded,
          const {
            'w1': {'a.txt': WorkspaceFileStamp(size: 5, mtimeMs: 1000)},
          },
          reason:
              'a miss a push can repair is named, with the version to ask for',
        );
        expect(
          workspaceFile('w1', 'a.txt').existsSync(),
          isFalse,
          reason: 'a mislabelled transfer is discarded, not kept',
        );
      },
    );

    test(
      'a file the peer deleted goes, with the directory it emptied',
      () async {
        await putWorkspace('w1');
        await putFile('w1', 'deep/a.txt', 'x', mtimeMs: 5000);
        final snapshots = await content.snapshots();
        final mine = snapshots.single.index.files['deep/a.txt']!;

        final outcome = await content.applyIncoming(
          myDeviceId: 'me',
          peerDeviceId: 'peer',
          mine: snapshots,
          peerTables: const {'w1': <String, WorkspaceFileStamp>{}},
          ledger: {
            'w1': {'deep/a.txt': SyncAgreedFile(mine, mine)},
          },
          allowDeletes: true,
          fetch: fetcher('unused'),
        );

        expect(outcome.filesRemoved, 1);
        expect(workspaceFile('w1', 'deep/a.txt').existsSync(), isFalse);
        expect(
          Directory('${root.path}/workspaces/w1/files/deep').existsSync(),
          isFalse,
          reason: 'a deletion that emptied a directory takes it too',
        );
        expect(outcome.ledger, isEmpty, reason: 'nothing is left to remember');
      },
    );

    test(
      'a workspace the peer does not share is left completely alone',
      () async {
        await putWorkspace('w1');
        await putFile('w1', 'a.txt', 'keep me', mtimeMs: 5000);
        final snapshots = await content.snapshots();
        final mine = snapshots.single.index.files['a.txt']!;

        final outcome = await content.applyIncoming(
          myDeviceId: 'me',
          peerDeviceId: 'peer',
          mine: snapshots,
          // No entry at all: the peer is not sharing this workspace, which is not
          // the same statement as "it has no files".
          peerTables: const {},
          ledger: {
            'w1': {'a.txt': SyncAgreedFile(mine, mine)},
          },
          allowDeletes: true,
          fetch: fetcher('unused'),
        );

        expect(outcome.filesRemoved, 0);
        expect(outcome.filesLanded, 0);
        expect(workspaceFile('w1', 'a.txt').existsSync(), isTrue);
        expect(outcome.ledger['w1']!['a.txt']!.mine, mine);
      },
    );

    test(
      'the ledger entry survives a ledger the peer cannot confirm',
      () async {
        await putWorkspace('w1');
        await putFile('w1', 'a.txt', 'x', mtimeMs: 5000);
        final snapshots = await content.snapshots();
        final mine = snapshots.single.index.files['a.txt']!;

        // What a fetch that never made it back looks like: the peer shares the
        // workspace and needs the file, but nothing lands here.
        final outcome = await content.applyIncoming(
          myDeviceId: 'me',
          peerDeviceId: 'peer',
          mine: snapshots,
          peerTables: const {'w1': <String, WorkspaceFileStamp>{}},
          ledger: {
            'w1': {'a.txt': SyncAgreedFile(mine, mine)},
          },
          allowDeletes: false,
          fetch: null,
        );

        expect(outcome.filesRemoved, 0);
        expect(
          workspaceFile('w1', 'a.txt').existsSync(),
          isTrue,
          reason: 'a peer that was bulk-replaced proves nothing by its silence',
        );
        expect(outcome.ledger['w1']!['a.txt']!.mine, mine);
      },
    );
  });

  group('acceptPushed', () {
    test(
      'lands a requested version through the same gates as a fetch',
      () async {
        await putWorkspace('w1');
        final staged = File('${root.path}/staged.bin');
        await staged.writeAsString('hello', flush: true);
        const advertised = WorkspaceFileStamp(size: 5, mtimeMs: 1700000000000);

        final landed = await content.acceptPushed(
          workspaceId: 'w1',
          relPath: 'deep/a.txt',
          staged: staged,
          advertised: advertised,
        );

        expect(landed, isNotNull);
        expect(landed!.size, 5);
        final file = workspaceFile('w1', 'deep/a.txt');
        expect(await file.readAsString(), 'hello');
        expect(
          file.statSync().modified.millisecondsSinceEpoch,
          advertised.mtimeMs,
          reason:
              'a pushed file carries the peer\'s edit time, like a fetched one',
        );
      },
    );

    test('a workspace switched off mid-session refuses the push', () async {
      await putWorkspace('w1');
      await content.setEnabled('w1', false);
      final staged = File('${root.path}/staged.bin');
      await staged.writeAsString('aa', flush: true);

      expect(
        await content.acceptPushed(
          workspaceId: 'w1',
          relPath: 'a.txt',
          staged: staged,
          advertised: const WorkspaceFileStamp(size: 2, mtimeMs: 1000),
        ),
        isNull,
        reason: 'the switch is re-read, not trusted from the push beat',
      );
      expect(workspaceFile('w1', 'a.txt').existsSync(), isFalse);
    });

    test('a path a push may not name is refused, as for a fetch', () async {
      await putWorkspace('w1');
      final staged = File('${root.path}/staged.bin');
      await staged.writeAsString('evil', flush: true);

      expect(
        await content.acceptPushed(
          workspaceId: 'w1',
          relPath: '../escape.txt',
          staged: staged,
          advertised: const WorkspaceFileStamp(size: 4, mtimeMs: 1000),
        ),
        isNull,
      );
      expect(File('${root.path}/workspaces/escape.txt').existsSync(), isFalse);
    });

    test('a refused landing does not take the copy already there', () async {
      // The size is verified *before* the destination is touched: the file at
      // this path is, at that moment, the only copy this device has of it, so a
      // refusal that had already deleted it left the path empty — a file the
      // device never lost, gone until the next session re-fetched it.
      await putWorkspace('w1');
      await putFile('w1', 'a.txt', 'mine');
      final staged = File('${root.path}/staged.bin');
      await staged.writeAsString('other!', flush: true);

      expect(
        await content.acceptPushed(
          workspaceId: 'w1',
          relPath: 'a.txt',
          staged: staged,
          advertised: const WorkspaceFileStamp(size: 2, mtimeMs: 1000),
        ),
        isNull,
      );
      expect(
        workspaceFile('w1', 'a.txt').readAsStringSync(),
        'mine',
        reason: 'the refused transfer does not take the local copy with it',
      );
    });

    test('a push whose bytes are not the advertised size is refused', () async {
      await putWorkspace('w1');
      final staged = File('${root.path}/staged.bin');
      await staged.writeAsString('abc', flush: true);

      expect(
        await content.acceptPushed(
          workspaceId: 'w1',
          relPath: 'a.txt',
          staged: staged,
          advertised: const WorkspaceFileStamp(size: 5, mtimeMs: 1000),
        ),
        isNull,
      );
      expect(
        workspaceFile('w1', 'a.txt').existsSync(),
        isFalse,
        reason: 'the same rule a truncated fetch gets',
      );
    });
  });

  group('ledgerWithPushed', () {
    test('names the bytes that landed and the version asked for', () {
      const asked = WorkspaceFileStamp(size: 2, mtimeMs: 1000);
      const landed = WorkspaceFileStamp(size: 2, mtimeMs: 2000);

      final ledger = content.ledgerWithPushed(const {}, const {
        'w1': {'a.txt': SyncAgreedFile(landed, asked)},
      });

      expect(ledger['w1']!['a.txt']!.mine, landed);
      expect(ledger['w1']!['a.txt']!.peer, asked);
    });

    test('keeps every entry it was given', () {
      const prior = SyncAgreedFile(
        WorkspaceFileStamp(size: 1, mtimeMs: 1),
        WorkspaceFileStamp(size: 1, mtimeMs: 1),
      );
      const landed = WorkspaceFileStamp(size: 2, mtimeMs: 2000);
      const asked = WorkspaceFileStamp(size: 2, mtimeMs: 1000);

      final ledger = content.ledgerWithPushed(
        const {
          'w1': {'kept.txt': prior},
        },
        const {
          'w1': {'a.txt': SyncAgreedFile(landed, asked)},
        },
      );

      expect(ledger['w1']!.keys.toSet(), {'kept.txt', 'a.txt'});
      expect(ledger['w1']!['kept.txt'], same(prior));
    });

    test('a session that pushed nothing returns the ledger it was given', () {
      const prior = SyncAgreedFile(
        WorkspaceFileStamp(size: 1, mtimeMs: 1),
        WorkspaceFileStamp(size: 1, mtimeMs: 1),
      );
      final ledger = {
        'w1': {'a.txt': prior},
      };

      expect(content.ledgerWithPushed(ledger, const {}), same(ledger));
    });
  });

  test('deleteContent removes the workspace folder', () async {
    await putWorkspace('w1');
    await putFile('w1', 'a.txt', 'x');

    await content.deleteContent('w1');

    expect(Directory('${root.path}/workspaces/w1/files').existsSync(), isFalse);
    expect(Directory('${root.path}/workspaces/w1').existsSync(), isFalse);
  });
}
