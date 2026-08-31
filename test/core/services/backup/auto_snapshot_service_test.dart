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
      'eviction failure keeps pairs intact and a dedup tick repairs the cap',
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
        // Make the OLDEST zip un-deletable: replace the file with a
        // non-empty directory. File.deleteSync on such a path throws on both
        // Windows and POSIX, so eviction of this pair must fail.
        final oldestZip = File('${dir.path}/${names.first}');
        final oldestZipBytes = oldestZip.readAsBytesSync();
        oldestZip.deleteSync();
        Directory(oldestZip.path).createSync();
        File('${oldestZip.path}/locked').writeAsStringSync('x');

        // 4th snapshot commits fine; eviction of the oldest pair fails and
        // must leave BOTH the zip-dir and its sidecar (no orphan half).
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
        expect(snapshots, hasLength(4));
        expect(File('${dir.path}/${names.first}.json').existsSync(), isTrue);

        // The transient problem clears: restore a real zip at the oldest
        // path, then the same content as the newest snapshot triggers dedup —
        // that tick must repair the cap back down to 3 pairs.
        Directory(oldestZip.path).deleteSync(recursive: true);
        oldestZip.writeAsBytesSync(oldestZipBytes);
        final dedup = await service.createSnapshot();
        expect(dedup.status, AutoSnapshotStatus.deduplicated);

        snapshots = await service.listSnapshots();
        expect(snapshots, hasLength(3));
        expect(
          snapshots.map((s) => s.fileName).toSet(),
          names.sublist(1).toSet(),
        );
        expect(
          dir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.json'))
              .length,
          3,
        );
        expect(File('${dir.path}/${names.first}.json').existsSync(), isFalse);
        expect(File(oldestZip.path).existsSync(), isFalse);
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
