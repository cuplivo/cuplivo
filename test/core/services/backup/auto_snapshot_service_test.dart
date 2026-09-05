import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Cuplivo/core/models/backup.dart';
import 'package:Cuplivo/core/services/backup/auto_snapshot_service.dart';
import 'package:Cuplivo/core/services/backup/data_sync.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getTemporaryPath() async => '$root/tmp';
}

File _buildZip(String path, Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, data) {
    archive.add(ArchiveFile.bytes(name, data));
  });
  final out = File(path);
  out.writeAsBytesSync(ZipEncoder().encode(archive));
  return out;
}

/// A controllable fake exporter: each call writes a zip whose payload is the
/// current [payload] (bumping it produces a different content hash).
class _FakeExporter {
  _FakeExporter(this.workDir);

  final Directory workDir;
  Map<String, List<int>> payload = {
    'chats_meta.json': utf8.encode(
      jsonEncode({
        'format_version': 2,
        'conversation_count': 1,
        'message_count': 2,
      }),
    ),
    'conversations.jsonl': utf8.encode('{}\n'),
  };
  int calls = 0;
  bool failNext = false;

  Future<File> export() async {
    calls++;
    if (failNext) {
      failNext = false;
      throw StateError('disk full');
    }
    final unique = 'backup_${calls}_${DateTime.now().microsecondsSinceEpoch}';
    return _buildZip('${workDir.path}/$unique.zip', payload);
  }
}

AutoSnapshotService _service(Directory root, _FakeExporter exporter) {
  return AutoSnapshotService(
    exportBackup: exporter.export,
    assistantCount: () async => 3,
    conversationCount: () async => 7,
    messageCount: () async => 42,
    rootDirectoryResolver: () async => root,
  );
}

void main() {
  group('AutoSnapshotService', () {
    late Directory root;
    late Directory workDir;
    late _FakeExporter exporter;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('auto_snapshot_test_');
      workDir = Directory('${root.path}/tmp')..createSync(recursive: true);
      PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
      exporter = _FakeExporter(workDir);
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test(
      'a sidecar with an absolute-path file_name never leaks the store',
      () async {
        final service = _service(root, exporter);
        await service.createSnapshot(); // one legit pair A

        final dir = await service.snapshotDirectory();
        // A real ZIP outside the store, plus a sidecar whose file_name is an
        // absolute path into it. Cross-platform: use POSIX-style separators
        // (invalid on both conventions) plus a fully-qualified drive path.
        final outside = File('${root.path}/outside_victim.zip');
        outside.writeAsBytesSync([1, 2, 3]);
        final malicious = File('${dir.path}/auto_snapshot_evil_abs.zip.json');
        malicious.writeAsStringSync(
          jsonEncode({
            'file_name': outside.path.replaceAll('\\', '/'),
            'created_at': '2026-01-01T00:00:00',
            'size_bytes': 0,
            'assistant_count': 0,
            'conversation_count': 0,
            'message_count': 0,
            'content_hash': 'evil',
          }),
        );

        var snapshots = await service.listSnapshots();
        expect(snapshots, hasLength(1), reason: 'evil sidecar is not listed');

        // Over-cap eviction (via 3 more real snapshots) must keep the
        // outside file intact; only in-store pairs are touched.
        exporter.payload = {
          'chats_meta.json': utf8.encode(
            jsonEncode({'format_version': 2, 'conversation_count': 1}),
          ),
          'conversations.jsonl': utf8.encode('1\n'),
        };
        await service.createSnapshot();
        exporter.payload = {
          'chats_meta.json': utf8.encode(
            jsonEncode({'format_version': 2, 'conversation_count': 2}),
          ),
          'conversations.jsonl': utf8.encode('2\n'),
        };
        await service.createSnapshot();
        exporter.payload = {
          'chats_meta.json': utf8.encode(
            jsonEncode({'format_version': 2, 'conversation_count': 3}),
          ),
          'conversations.jsonl': utf8.encode('3\n'),
        };
        await service.createSnapshot();

        expect(outside.existsSync(), isTrue);
        snapshots = await service.listSnapshots();
        expect(snapshots, hasLength(3));
        expect(
          snapshots.map((s) => s.fileName),
          isNot(contains(outside.uri.pathSegments.last)),
        );
        await expectLater(
          AutoSnapshotService.resolveSnapshotFile(
            outside.path.replaceAll('\\', '/'),
          ),
          throwsA(isA<AutoSnapshotException>()),
        );
      },
    );

    test(
      'a sidecar with a ../ traversal file_name cannot escape the store',
      () async {
        final service = _service(root, exporter);
        await service.createSnapshot(); // one legit pair A

        final dir = await service.snapshotDirectory();
        // A real ZIP just outside the store (parent of auto_snapshots), and a
        // sidecar pointing at it with a relative traversal.
        final outside = File('${root.path}/traverse_victim.zip');
        outside.writeAsBytesSync([1, 2, 3]);
        File('${dir.path}/auto_snapshot_evil_relative.zip.json').writeAsString(
          jsonEncode({
            'file_name': '../traverse_victim.zip',
            'created_at': '2026-01-01T00:00:00',
            'size_bytes': 0,
            'assistant_count': 0,
            'conversation_count': 0,
            'message_count': 0,
            'content_hash': 'evil',
          }),
        );

        var snapshots = await service.listSnapshots();
        expect(snapshots, hasLength(1), reason: 'traversal sidecar dropped');

        exporter.payload = {
          'chats_meta.json': utf8.encode(
            jsonEncode({'format_version': 2, 'conversation_count': 1}),
          ),
          'conversations.jsonl': utf8.encode('1\n'),
        };
        await service.createSnapshot();
        exporter.payload = {
          'chats_meta.json': utf8.encode(
            jsonEncode({'format_version': 2, 'conversation_count': 2}),
          ),
          'conversations.jsonl': utf8.encode('2\n'),
        };
        await service.createSnapshot();
        exporter.payload = {
          'chats_meta.json': utf8.encode(
            jsonEncode({'format_version': 2, 'conversation_count': 3}),
          ),
          'conversations.jsonl': utf8.encode('3\n'),
        };
        await service.createSnapshot();

        // Eviction happened (4 real entries → 3) but the traversal target
        // survived untouched.
        snapshots = await service.listSnapshots();
        expect(snapshots, hasLength(3));
        expect(outside.existsSync(), isTrue);
      },
    );

    test(
      'an aliasing sidecar cannot double-count or misdirect eviction',
      () async {
        final service = _service(root, exporter);
        final names = <String>[];
        for (var i = 0; i < 3; i++) {
          if (i > 0) {
            await Future<void>.delayed(const Duration(milliseconds: 1100));
          }
          exporter.payload = {
            'chats_meta.json': utf8.encode(
              jsonEncode({
                'format_version': 2,
                'conversation_count': i,
                'message_count': i * 10,
              }),
            ),
            'conversations.jsonl': utf8.encode('$i\n'),
          };
          final result = await service.createSnapshot();
          expect(result.status, AutoSnapshotStatus.created);
          names.add(result.metadata!.fileName);
        }

        final dir = await service.snapshotDirectory();
        // A sidecar whose name derives zip `auto_snapshot_alias.zip` but
        // whose JSON claims the file_name of the NEWEST real snapshot.
        File('${dir.path}/auto_snapshot_alias.zip.json').writeAsStringSync(
          jsonEncode({
            'file_name': names.last,
            'created_at': '2026-01-01T00:00:00',
            'size_bytes': 1,
            'assistant_count': 0,
            'conversation_count': 0,
            'message_count': 0,
            'content_hash': 'evil',
          }),
        );

        final snapshots = await service.listSnapshots();
        expect(snapshots, hasLength(3), reason: 'alias is not double-counted');
        expect(
          snapshots.map((s) => s.fileName).toSet(),
          names.toSet(),
          reason: 'the real newest pair keeps its own entry',
        );

        // A 4th snapshot over the cap evicts the OLDEST real pair, not the
        // aliased newest one.
        exporter.payload = {
          'chats_meta.json': utf8.encode(
            jsonEncode({'format_version': 2, 'conversation_count': 3}),
          ),
          'conversations.jsonl': utf8.encode('3\n'),
        };
        final fourth = await service.createSnapshot();
        expect(fourth.status, AutoSnapshotStatus.created);
        final after = await service.listSnapshots();
        expect(after, hasLength(3));
        expect(after.map((s) => s.fileName).toSet(), {
          ...names.sublist(1),
          fourth.metadata!.fileName,
        });
        expect(
          File('${dir.path}/auto_snapshot_alias.zip.json').existsSync(),
          isFalse,
        );
      },
    );

    test(
      'resolveSnapshotFile rejects traversal payloads and accepts real names',
      () async {
        final service = _service(root, exporter);
        final result = await service.createSnapshot();
        expect(result.status, AutoSnapshotStatus.created);

        expect(
          await AutoSnapshotService.resolveSnapshotFile(
            result.metadata!.fileName,
          ),
          isA<File>(),
        );
        await expectLater(
          AutoSnapshotService.resolveSnapshotFile('../evil.zip'),
          throwsA(isA<AutoSnapshotException>()),
        );
        await expectLater(
          AutoSnapshotService.resolveSnapshotFile('/abs/evil.zip'),
          throwsA(isA<AutoSnapshotException>()),
        );
        await expectLater(
          AutoSnapshotService.resolveSnapshotFile('C:\\evil.zip'),
          throwsA(isA<AutoSnapshotException>()),
        );
        await expectLater(
          AutoSnapshotService.resolveSnapshotFile('auto_snapshot_.._x.zip'),
          throwsA(isA<AutoSnapshotException>()),
        );
      },
    );

    test('creates a snapshot with sidecar metadata on first run', () async {
      final service = _service(root, exporter);
      final result = await service.createSnapshot();

      expect(result.status, AutoSnapshotStatus.created);
      final snapshots = await service.listSnapshots();
      expect(snapshots, hasLength(1));
      expect(snapshots.first.assistantCount, 3);
      expect(snapshots.first.conversationCount, 7);
      expect(snapshots.first.messageCount, 42);
      expect(snapshots.first.contentHash, isNotEmpty);
      expect(snapshots.first.sizeBytes, greaterThan(0));
      expect(snapshots.first.fileName, startsWith('auto_snapshot_'));
      expect(snapshots.first.fileName, endsWith('.zip'));
      final zip = await AutoSnapshotService.resolveSnapshotFile(
        snapshots.first.fileName,
      );
      expect(zip.existsSync(), isTrue);
    });

    test(
      'deduplicates when payload is identical to the newest snapshot',
      () async {
        final service = _service(root, exporter);
        await service.createSnapshot();
        final result = await service.createSnapshot();

        expect(result.status, AutoSnapshotStatus.deduplicated);
        final snapshots = await service.listSnapshots();
        expect(snapshots, hasLength(1));
        expect(exporter.calls, 2);
      },
    );

    test(
      'creates a new snapshot when payload changes, and evicts FIFO at 3',
      () async {
        final service = _service(root, exporter);
        final names = <String>[];
        for (var i = 0; i < 4; i++) {
          if (i > 0) {
            // Distinct second-precision timestamps keep the FIFO order strict.
            await Future<void>.delayed(const Duration(milliseconds: 1100));
          }
          exporter.payload = {
            'chats_meta.json': utf8.encode(
              jsonEncode({
                'format_version': 2,
                'conversation_count': i,
                'message_count': i * 10,
              }),
            ),
            'conversations.jsonl': utf8.encode('$i\n'),
          };
          final result = await service.createSnapshot();
          expect(result.status, AutoSnapshotStatus.created);
          names.add(result.metadata!.fileName);
        }

        final snapshots = await service.listSnapshots();
        expect(snapshots, hasLength(3));
        // Newest first: the first-created snapshot was evicted.
        expect(
          snapshots.map((s) => s.fileName).toSet(),
          names.sublist(1).toSet(),
        );
        // Sidecars are cleaned up together with their zips.
        final dir = await service.snapshotDirectory();
        expect(
          dir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.json'))
              .length,
          3,
        );
      },
    );

    test(
      'a sidecar delete failure mid-eviction still converges and stays stable',
      () async {
        final service = _service(root, exporter);
        final names = <String>[];
        for (var i = 0; i < 3; i++) {
          if (i > 0) {
            await Future<void>.delayed(const Duration(milliseconds: 1100));
          }
          exporter.payload = {
            'chats_meta.json': utf8.encode(
              jsonEncode({
                'format_version': 2,
                'conversation_count': i,
                'message_count': i * 10,
              }),
            ),
            'conversations.jsonl': utf8.encode('$i\n'),
          };
          final result = await service.createSnapshot();
          expect(result.status, AutoSnapshotStatus.created);
          names.add(result.metadata!.fileName);
        }

        final dir = await service.snapshotDirectory();
        // The oldest ZIP stays real (so I can inject failure mid-eviction),
        // but its sidecar path is occupied by a non-empty directory: eviction
        // deletes the ZIP and then fails on the sidecar, like a transient I/O
        // failure would.
        File('${dir.path}/${names.first}.json').deleteSync();
        Directory('${dir.path}/${names.first}.json').createSync();
        File('${dir.path}/${names.first}.json/locked').writeAsStringSync('x');

        // 4th snapshot commits; eviction hits the oldest pair, the zip goes,
        // the sidecar delete fails, and the ghost is swept in the same tick.
        exporter.payload = {
          'chats_meta.json': utf8.encode(
            jsonEncode({'format_version': 2, 'conversation_count': 3}),
          ),
          'conversations.jsonl': utf8.encode('3\n'),
        };
        final fourth = await service.createSnapshot();
        expect(fourth.status, AutoSnapshotStatus.created);
        names.add(fourth.metadata!.fileName);

        var snapshots = await service.listSnapshots();
        expect(snapshots, hasLength(3));
        expect(
          snapshots.map((s) => s.fileName).toSet(),
          names.sublist(1).toSet(),
        );
        expect(
          Directory('${dir.path}/${names.first}.json').existsSync(),
          isFalse,
          reason: 'the zip-less sidecar ghost must be swept',
        );
        expect(
          dir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.json'))
              .length,
          3,
        );

        // A repeated tick with the newest payload just dedups — the store is
        // already converged and stays that way (no resurrection, no ghosts).
        final dedup = await service.createSnapshot();
        expect(dedup.status, AutoSnapshotStatus.deduplicated);
        snapshots = await service.listSnapshots();
        expect(snapshots, hasLength(3));
        expect(
          dir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.json'))
              .length,
          3,
        );
      },
    );

    test(
      'a zip-less sidecar ghost never occupies a slot and is swept away',
      () async {
        final service = _service(root, exporter);
        final names = <String>[];
        for (var i = 0; i < 3; i++) {
          if (i > 0) {
            await Future<void>.delayed(const Duration(milliseconds: 1100));
          }
          exporter.payload = {
            'chats_meta.json': utf8.encode(
              jsonEncode({
                'format_version': 2,
                'conversation_count': i,
                'message_count': i * 10,
              }),
            ),
            'conversations.jsonl': utf8.encode('$i\n'),
          };
          final result = await service.createSnapshot();
          expect(result.status, AutoSnapshotStatus.created);
          names.add(result.metadata!.fileName);
        }

        final dir = await service.snapshotDirectory();
        // Simulate an eviction that already deleted the oldest ZIP but failed
        // on its sidecar: a usable sidecar is left behind with no zip.
        File('${dir.path}/${names.first}').deleteSync();

        exporter.payload = {
          'chats_meta.json': utf8.encode(
            jsonEncode({'format_version': 2, 'conversation_count': 3}),
          ),
          'conversations.jsonl': utf8.encode('3\n'),
        };
        final fourth = await service.createSnapshot();
        expect(fourth.status, AutoSnapshotStatus.created);
        names.add(fourth.metadata!.fileName);

        // The ghost does not count as a snapshot — the store holds exactly
        // the 3 real pairs and the ghost sidecar is gone after the sweep.
        final snapshots = await service.listSnapshots();
        expect(snapshots, hasLength(3));
        expect(
          snapshots.map((s) => s.fileName).toSet(),
          names.sublist(1).toSet(),
        );
        expect(File('${dir.path}/${names.first}.json').existsSync(), isFalse);
        final leftovers = dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList();
        expect(leftovers, hasLength(3), reason: 'no ghost sidecars remain');
      },
    );

    test(
      'a sidecar ghost occupying a directory converges with no leftovers',
      () async {
        final service = _service(root, exporter);
        final names = <String>[];
        for (var i = 0; i < 3; i++) {
          if (i > 0) {
            await Future<void>.delayed(const Duration(milliseconds: 1100));
          }
          exporter.payload = {
            'chats_meta.json': utf8.encode(
              jsonEncode({
                'format_version': 2,
                'conversation_count': i,
                'message_count': i * 10,
              }),
            ),
            'conversations.jsonl': utf8.encode('$i\n'),
          };
          final result = await service.createSnapshot();
          expect(result.status, AutoSnapshotStatus.created);
          names.add(result.metadata!.fileName);
        }

        final dir = await service.snapshotDirectory();
        // Oldest pair: zip removed and the sidecar path occupied by a
        // directory (a previously failed delete that also cannot be undone
        // via a plain File deleteSync).
        File('${dir.path}/${names.first}').deleteSync();
        File('${dir.path}/${names.first}.json').deleteSync();
        Directory('${dir.path}/${names.first}.json').createSync();
        File('${dir.path}/${names.first}.json/locked').writeAsStringSync('x');

        exporter.payload = {
          'chats_meta.json': utf8.encode(
            jsonEncode({'format_version': 2, 'conversation_count': 3}),
          ),
          'conversations.jsonl': utf8.encode('3\n'),
        };
        final fourth = await service.createSnapshot();
        expect(fourth.status, AutoSnapshotStatus.created);
        names.add(fourth.metadata!.fileName);

        final snapshots = await service.listSnapshots();
        expect(snapshots, hasLength(3));
        expect(
          snapshots.map((s) => s.fileName).toSet(),
          names.sublist(1).toSet(),
        );
        // The directory ghost was swept too: the store is fully converged.
        expect(
          Directory('${dir.path}/${names.first}.json').existsSync(),
          isFalse,
        );
        expect(
          dir.listSync(),
          hasLength(6),
        ); // 3 zips + 3 sidecars, nothing else
      },
    );

    test(
      'deleteAllSnapshots throws and keeps the restorable remainder',
      () async {
        final service = _service(root, exporter);
        await service.createSnapshot();

        final dir = await service.snapshotDirectory();
        // Make the only zip un-deletable: replace it with a non-empty
        // directory. deleteAllSnapshots deletes non-recursively, so a
        // non-empty entry fails to go on both Windows (access denied) and
        // POSIX (not empty) — the platform-faithful standing-in for a
        // transient delete failure in production.
        final zipPath = dir
            .listSync()
            .whereType<File>()
            .firstWhere((f) => f.path.endsWith('.zip'))
            .path;
        File(zipPath).deleteSync();
        Directory(zipPath).createSync();
        File('$zipPath/locked').writeAsStringSync('x');

        await expectLater(
          service.deleteAllSnapshots(),
          throwsA(isA<AutoSnapshotException>()),
        );
        // The failure is real, the ordinary sidecar still went, and the
        // un-deletable artifact is left behind — nothing reported silently.
        expect(File('$zipPath.json').existsSync(), isFalse);
        expect(Directory(zipPath).existsSync(), isTrue);
      },
    );

    test(
      'failed export leaves the snapshot store completely untouched',
      () async {
        final service = _service(root, exporter);
        await service.createSnapshot();
        final before = await service.listSnapshots();

        exporter.failNext = true;
        await expectLater(service.createSnapshot(), throwsException);

        final after = await service.listSnapshots();
        expect(after, hasLength(before.length));
        expect(after.first.fileName, before.first.fileName);
        expect(after.first.contentHash, before.first.contentHash);
        // No stray temp files inside the snapshot directory.
        final dir = await service.snapshotDirectory();
        expect(dir.listSync().whereType<File>().length, 2); // zip + sidecar
      },
    );

    test('count failure leaves the snapshot store byte-identical', () async {
      final service = AutoSnapshotService(
        exportBackup: exporter.export,
        assistantCount: () async => throw StateError('db busy'),
        conversationCount: () async => 7,
        messageCount: () async => 42,
        rootDirectoryResolver: () async => root,
      );
      final before = await service.snapshotDirectory();
      // Only the temp export and the to-be-created dir exist now.
      final preState = before.existsSync()
          ? before
                .listSync()
                .map((e) => '${e.statSync().size}:${e.uri.pathSegments.last}')
                .toList()
          : const <String>[];

      await expectLater(service.createSnapshot(), throwsException);

      final after = await service.snapshotDirectory();
      final postState = after
          .listSync()
          .map((e) => '${e.statSync().size}:${e.uri.pathSegments.last}')
          .toList();
      expect(postState, preState);
      // The failed attempt must not leave the exported temp file behind.
      expect(workDir.listSync(), isEmpty);
    });

    test('rejects a zip without the sentinel entry', () async {
      final service = _service(root, exporter);
      exporter.payload = {'conversations.jsonl': utf8.encode('{}\n')};

      await expectLater(service.createSnapshot(), throwsException);
      expect(await service.listSnapshots(), isEmpty);
    });

    test('corrupt sidecar falls back to filesystem-derived metadata', () async {
      final service = _service(root, exporter);
      await service.createSnapshot();
      final dir = await service.snapshotDirectory();
      final sidecar = dir.listSync().whereType<File>().firstWhere(
        (f) => f.path.endsWith('.json'),
      );
      await sidecar.writeAsString('{ not json');

      final snapshots = await service.listSnapshots();
      expect(snapshots, hasLength(1));
      expect(snapshots.first.contentHash, isNotEmpty);
      // Counts are unknown once the sidecar is gone.
      expect(snapshots.first.conversationCount, 0);
    });

    test('deleteAllSnapshots removes every stored snapshot', () async {
      final service = _service(root, exporter);
      await service.createSnapshot();
      exporter.payload['conversations.jsonl'] = utf8.encode('{}\n{}\n');
      await service.createSnapshot();

      final before = await service.listSnapshots();
      expect(before, hasLength(2));

      await service.deleteAllSnapshots();
      expect(await service.listSnapshots(), isEmpty);

      final dir = await service.snapshotDirectory();
      expect(
        dir.listSync().whereType<File>(),
        isEmpty,
        reason: 'No zip or sidecar should remain after deleteAllSnapshots',
      );
    });
  });

  group('Auto snapshots stay out of backups', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('auto_snapshot_reg_');
      PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('export never packs the auto_snapshots directory', () async {
      // Simulate existing snapshots on disk.
      final snapshotDir = Directory('${root.path}/auto_snapshots')
        ..createSync(recursive: true);
      await File(
        '${snapshotDir.path}/auto_snapshot_20260829T120000.zip',
      ).writeAsBytes([1, 2, 3, 4]);
      await File(
        '${snapshotDir.path}/auto_snapshot_20260829T120000.zip.json',
      ).writeAsString('{}');

      final sync = DataSync(
        preferences: BusinessPreferences.memoryForTests(),
        chatService: ChatService(),
      );
      final backupFile = await sync.prepareBackupFile(
        const WebDavConfig(
          content: BackupContentScope(
            chatsAndAssistants: false,
            attachments: true,
          ),
        ),
      );

      final archive = ZipDecoder().decodeBytes(backupFile.readAsBytesSync());
      final names = archive.map((e) => e.name).toList();
      expect(
        names.where((n) => n.contains('auto_snapshots')),
        isEmpty,
        reason: 'Snapshots must not travel with backups: $names',
      );
    });
  });
}
