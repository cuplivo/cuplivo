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
  }) => recycle.stageWorkspaceFile(
    workspaceId: workspaceId,
    relPath: relPath,
    source: source,
    origin: RecycleOrigin.remote,
    reason: RecycleReason.deleted,
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
}
