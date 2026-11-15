import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/services/recycle/recycle_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Restoring a file out of the bin.
///
/// The staging side lives in the sync plane and is proved next to it
/// (`workspace_content_sync_test.dart`); what is tested here is the way back —
/// the workspace root, the path gates, and the one rule that makes a recovered
/// file survive the next sync round instead of losing the same comparison again.
void main() {
  late Directory root;
  late AppDatabase database;
  late RecycleService recycle;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('kelivo_recycle_file_');
    database = AppDatabase(NativeDatabase.memory());
    recycle = RecycleService(
      database,
      store: RecycleStore(directory: () async => Directory('${root.path}/bin')),
      workspaceRoot: (id) async {
        final dir = Directory('${root.path}/workspaces/$id/files');
        await dir.create(recursive: true);
        return dir;
      },
    );
  });

  tearDown(() async {
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> putWorkspace(String id) =>
      ExtensionEntityStore(database).upsert('workspace', id, {
        'id': id,
        'name': id,
        'kind': 'managed',
        'hostPath': null,
        'shellNeedsApproval': false,
        'defaultCwd': '',
        'disabledTools': const <String>[],
        'createdAt': '2026-01-01T00:00:00.000Z',
        'updatedAt': '2026-01-01T00:00:00.000Z',
        'lastUsedAt': null,
      });

  /// A file with a *known old* modification time, so "the restore stamped it as
  /// a fresh local write" is a comparison rather than a guess about the clock.
  Future<File> putFile(String workspaceId, String relPath, String data) async {
    final file = File('${root.path}/workspaces/$workspaceId/files/$relPath');
    await file.parent.create(recursive: true);
    await file.writeAsString(data, flush: true);
    await file.setLastModified(DateTime.utc(2001, 2, 3, 4, 5, 6));
    return file;
  }

  File inWorkspace(String workspaceId, String relPath) =>
      File('${root.path}/workspaces/$workspaceId/files/$relPath');

  Future<RecycleEntry?> stage(
    File source, {
    String workspaceId = 'w1',
    String relPath = 'notes/a.md',
    RecycleReason reason = RecycleReason.deleted,
    RecycleService? service,
  }) => (service ?? recycle).stageWorkspaceFile(
    workspaceId: workspaceId,
    relPath: relPath,
    source: source,
    origin: RecycleOrigin.remote,
    reason: reason,
  );

  test('a staged file goes back where it came from, stamped as new', () async {
    await putWorkspace('w1');
    final entry = (await stage(await putFile('w1', 'notes/a.md', 'the text')))!;
    expect(
      inWorkspace('w1', 'notes/a.md').existsSync(),
      isFalse,
      reason: 'staging moves the file out of the workspace',
    );

    expect(await recycle.restore(entry), RecycleRestoreOutcome.restored);

    final restored = inWorkspace('w1', 'notes/a.md');
    expect(await restored.readAsString(), 'the text');
    expect(
      restored.statSync().modified.millisecondsSinceEpoch,
      greaterThan(DateTime.utc(2001, 2, 3, 4, 5, 6).millisecondsSinceEpoch),
      reason:
          'a restore is a fresh local write: keeping the staged stamp would hand '
          'the file back to the comparison that removed it',
    );
    expect(
      await recycle.list(),
      isEmpty,
      reason: 'the entry is retired once the file is back',
    );
  });

  test('a workspace that is gone is refused, not recreated', () async {
    await putWorkspace('w1');
    final entry = (await stage(await putFile('w1', 'notes/a.md', 'x')))!;
    // The workspace itself was deleted after the file was staged: the whole
    // folder is gone, and a file restored into it would be an orphan the next
    // sync round removes.
    await ExtensionEntityStore(database).delete('workspace', 'w1');
    // Staging moves the file out and leaves the directory behind, so the folder
    // has to go too for this to be the state a deleted workspace is in.
    await Directory('${root.path}/workspaces/w1/files').delete(recursive: true);

    expect(
      await recycle.restore(entry),
      RecycleRestoreOutcome.workspaceGone,
      reason: 'the row that owns the folder is the condition for writing in it',
    );
    expect(
      Directory('${root.path}/workspaces/w1/files').existsSync(),
      isFalse,
      reason: 'nothing is recreated for a workspace that no longer exists',
    );
  });

  test('a file that is there again is not overwritten', () async {
    await putWorkspace('w1');
    final entry = (await stage(await putFile('w1', 'notes/a.md', 'old')))!;
    await inWorkspace('w1', 'notes/a.md').writeAsString('written since');

    expect(await recycle.restore(entry), RecycleRestoreOutcome.skippedExisting);

    expect(
      await inWorkspace('w1', 'notes/a.md').readAsString(),
      'written since',
    );
  });

  // The other reason, and the case the feature exists for: a merge that replaces
  // a file stages the version it replaced and then re-occupies the path, so a
  // restore that refused an occupied path could never bring anything back. The
  // rows have taken this split since decision 5; a file takes it too.
  test(
    'a file a losing comparison replaced goes back over the live copy',
    () async {
      await putWorkspace('w1');
      final entry = (await stage(
        await putFile('w1', 'notes/a.md', 'the old bytes'),
        reason: RecycleReason.overwritten,
      ))!;
      expect(
        inWorkspace('w1', 'notes/a.md').existsSync(),
        isFalse,
        reason:
            'staging moves the loser out, and the landing puts the winner in',
      );
      // What the landing does next: the peer's newer version takes the path.
      await inWorkspace('w1', 'notes/a.md').writeAsString('the newer bytes');
      await inWorkspace(
        'w1',
        'notes/a.md',
      ).setLastModified(DateTime.utc(2002, 3, 4, 5, 6, 7));

      expect(await recycle.restore(entry), RecycleRestoreOutcome.restored);

      final restored = inWorkspace('w1', 'notes/a.md');
      expect(await restored.readAsString(), 'the old bytes');
      expect(
        restored.statSync().modified.millisecondsSinceEpoch,
        greaterThan(DateTime.utc(2002, 3, 4, 5, 6, 7).millisecondsSinceEpoch),
        reason:
            'a restore is a fresh local write, so it beats the version it lost to',
      );

      final displaced = (await recycle.list()).single;
      expect(
        displaced.id,
        isNot(entry.id),
        reason: 'the entry that was restored is retired',
      );
      expect(displaced.reason, RecycleReason.overwritten);
      expect(displaced.origin, RecycleOrigin.local);
      final body = await recycle.bodyFile(displaced);
      expect(
        await body!.readAsString(),
        'the newer bytes',
        reason:
            'the live version goes into the bin, which is what makes it undoable',
      );
    },
  );

  test(
    'a replaced file whose live copy cannot be staged is not written over',
    () async {
      await putWorkspace('w1');
      final entry = (await stage(
        await putFile('w1', 'notes/a.md', 'the old bytes'),
        reason: RecycleReason.overwritten,
      ))!;
      await inWorkspace('w1', 'notes/a.md').writeAsString('the newer bytes');

      // The same forced-id seam as the staging test below: the bin cannot publish
      // an entry, so the move cannot take the live file.
      final binRoot = Directory('${root.path}/bin');
      await binRoot.create(recursive: true);
      await File(
        '${binRoot.path}/forced',
      ).writeAsString('in the way', flush: true);
      final blocked = RecycleService(
        database,
        store: RecycleStore(
          directory: () async => binRoot,
          entryId: (deletedAt) => 'forced',
        ),
        workspaceRoot: (id) async =>
            Directory('${root.path}/workspaces/$id/files'),
      );

      expect(await blocked.restore(entry), RecycleRestoreOutcome.failed);

      expect(
        await inWorkspace('w1', 'notes/a.md').readAsString(),
        'the newer bytes',
        reason: 'a bin that cannot take the live copy must not be written over',
      );
      expect(
        (await recycle.list()).single.id,
        entry.id,
        reason: 'nothing was restored, so nothing was retired',
      );
    },
  );

  test('a path that leaves the workspace is refused', () async {
    await putWorkspace('w1');
    final entry = (await stage(
      await putFile('w1', 'notes/a.md', 'payload'),
      relPath: '../escape.md',
    ))!;

    expect(await recycle.restore(entry), RecycleRestoreOutcome.unsupported);
    expect(
      File('${root.path}/workspaces/w1/escape.md').existsSync(),
      isFalse,
      reason: 'the same relative-path gate a sync landing goes through',
    );
  });

  test('an id that is not a path segment is refused', () async {
    await putWorkspace('w1');
    final source = await putFile('w1', 'notes/a.md', 'payload');
    final entry = (await stage(source, workspaceId: '..'))!;

    expect(await recycle.restore(entry), RecycleRestoreOutcome.unsupported);
    expect(
      File('${root.path}/workspaces/notes/a.md').existsSync(),
      isFalse,
      reason: 'an id from the wire must never name a directory',
    );
  });

  test('a staging that cannot publish its entry hands the file back', () async {
    // The failure the move creates: by the time the rename that would publish
    // the entry runs, the body is already inside the staging directory. The id
    // is forced onto a path a *file* occupies, because a directory cannot be
    // renamed over one on any platform — this is the only seam that reaches the
    // path, and it is a failure injection like `directory` is.
    final binRoot = Directory('${root.path}/bin');
    await binRoot.create(recursive: true);
    await File(
      '${binRoot.path}/forced',
    ).writeAsString('in the way', flush: true);
    final forced = RecycleService(
      database,
      store: RecycleStore(
        directory: () async => binRoot,
        entryId: (deletedAt) => 'forced',
      ),
    );

    final source = await putFile('w1', 'notes/b.md', 'the local bytes');

    final entry = await forced.stageWorkspaceFile(
      workspaceId: 'w1',
      relPath: 'notes/b.md',
      source: source,
      origin: RecycleOrigin.remote,
      reason: RecycleReason.deleted,
    );

    expect(entry, isNull);
    expect(
      await source.exists(),
      isTrue,
      reason: 'false means "not preserved", not "already taken"',
    );
    expect(await source.readAsString(), 'the local bytes');
    expect(
      await Directory('${binRoot.path}/.tmp-forced').exists(),
      isFalse,
      reason: 'the file came back, so the staging directory can go',
    );
  });
}
