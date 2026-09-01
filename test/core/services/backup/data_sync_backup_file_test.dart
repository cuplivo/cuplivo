import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/backup.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/incremental_backup.dart';
import 'package:Cuplivo/core/services/backup/data_sync.dart';
import 'package:Cuplivo/core/services/backup/kelivo_v2_exception.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/search/search_service.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

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

/// An initialized [ChatService] backed by an in-memory database, for restore
/// paths that require `chatService.initialized`.
class _InMemoryChatService extends ChatService {
  late final AppDatabase db;
  late final ChatDatabaseRepository _testRepo;

  _InMemoryChatService() {
    db = AppDatabase(NativeDatabase.memory());
    _testRepo = ChatDatabaseRepository(db);
  }

  @override
  bool get initialized => true;

  @override
  ChatDatabaseRepository get repo => _testRepo;

  @override
  Future<List<Assistant>> getAllAssistants() => _testRepo.getAllAssistants();

  @override
  Future<void> putAssistants(List<Assistant> list) =>
      _testRepo.putAssistants(list);

  @override
  Future<void> reloadCachesFromDb() async {}

  Future<void> closeDb() async {
    await _testRepo.close();
  }
}

void main() {
  group('DataSync backup file', () {
    late Directory root;

    setUp(() async {
      businessPrefs = BusinessPreferences.memoryForTests();
      root = await Directory.systemTemp.createTemp('kelivo_data_sync_test_');
      PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
      businessPrefs = BusinessPreferences.memoryForTests({
        'backup_test_key': 'value',
      });
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test(
      'packs files as deflated zip entries and removes staging files',
      () async {
        final uploadDir = Directory('${root.path}/upload');
        await uploadDir.create(recursive: true);
        final uploadFile = File('${uploadDir.path}/large.bin');
        await uploadFile.writeAsBytes(List<int>.filled(1024 * 1024, 7));
        final fontsDir = Directory('${root.path}/fonts');
        await fontsDir.create(recursive: true);
        final fontFile = File('${fontsDir.path}/custom.ttf');
        await fontFile.writeAsBytes(List<int>.filled(256, 9));

        final tmpDir = Directory('${root.path}/tmp');
        final staleWorkDir = Directory('${tmpDir.path}/kelivo_backup_stale');
        await staleWorkDir.create(recursive: true);
        await File('${staleWorkDir.path}/orphan.zip').writeAsString('old');
        await File('${tmpDir.path}/kelivo_backup_old.zip').writeAsString('old');
        await File('${tmpDir.path}/_bk_chats.json').writeAsString('{}');
        await File('${tmpDir.path}/_bk_chats_meta.json').writeAsString('{}');
        await File('${tmpDir.path}/_bk_conversations.jsonl').writeAsString('');
        await File('${tmpDir.path}/_bk_messages.jsonl').writeAsString('');
        await File('${tmpDir.path}/_bk_settings_meta.json').writeAsString('{}');

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: ChatService(),
        );
        final backupFile = await sync.prepareBackupFile(
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: true,
              workspaces: true,
              fontsAndAvatars: true,
              settings: true,
              skills: true,
            ),
          ),
        );

        expect(await staleWorkDir.exists(), isFalse);
        expect(
          await File('${tmpDir.path}/kelivo_backup_old.zip').exists(),
          isFalse,
        );
        expect(await File('${tmpDir.path}/_bk_chats.json').exists(), isFalse);
        expect(
          await File('${tmpDir.path}/_bk_chats_meta.json').exists(),
          isFalse,
        );
        expect(
          await File('${tmpDir.path}/_bk_conversations.jsonl').exists(),
          isFalse,
        );
        expect(
          await File('${tmpDir.path}/_bk_messages.jsonl').exists(),
          isFalse,
        );
        expect(
          await File('${tmpDir.path}/_bk_settings_meta.json').exists(),
          isFalse,
        );

        final input = InputFileStream(backupFile.path);
        Archive? archive;
        try {
          archive = ZipDecoder().decodeStream(input);
          final settingsEntry = archive.findFile('settings.json');
          final uploadEntry = archive.findFile('upload/large.bin');
          final fontEntry = archive.findFile('fonts/custom.ttf');

          expect(settingsEntry, isNotNull);
          expect(uploadEntry, isNotNull);
          expect(fontEntry, isNotNull);
          expect(settingsEntry!.compression, CompressionType.deflate);
          expect(uploadEntry!.compression, CompressionType.deflate);
          expect(fontEntry!.compression, CompressionType.deflate);
          expect(uploadEntry.readBytes(), List<int>.filled(1024 * 1024, 7));
          expect(fontEntry.readBytes(), List<int>.filled(256, 9));
        } finally {
          archive?.clearSync();
          input.closeSync();
        }

        expect(
          await File('${backupFile.parent.path}/_bk_settings.json').exists(),
          isFalse,
        );

        await DataSync.cleanupTemporaryBackupFile(backupFile);

        expect(await backupFile.exists(), isFalse);
        expect(await backupFile.parent.exists(), isFalse);
      },
    );

    test('restores managed font files in overwrite and merge modes', () async {
      final sourceDir = Directory('${root.path}/source_fonts');
      await sourceDir.create(recursive: true);
      final sourceFile = File('${sourceDir.path}/custom.ttf');
      await sourceFile.writeAsBytes(List<int>.filled(128, 5));

      final zipFile = File('${root.path}/fonts_backup.zip');
      final encoder = ZipFileEncoder();
      encoder.create(zipFile.path);
      encoder.addFileSync(sourceFile, 'fonts/custom.ttf');
      encoder.closeSync();

      final fontsDir = Directory('${root.path}/fonts');
      await fontsDir.create(recursive: true);
      final existingFile = File('${fontsDir.path}/existing.ttf');
      await existingFile.writeAsBytes(List<int>.filled(64, 3));

      final sync = DataSync(
        preferences: businessPrefs,
        chatService: ChatService(),
      );
      await sync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(
          content: BackupContentScope(
            chatsAndAssistants: false,
            attachments: true,
            workspaces: true,
            fontsAndAvatars: true,
            settings: true,
            skills: true,
          ),
        ),
        mode: RestoreMode.merge,
      );

      expect(await existingFile.exists(), isTrue);
      expect(
        await File('${fontsDir.path}/custom.ttf').readAsBytes(),
        List<int>.filled(128, 5),
      );

      await sync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(
          content: BackupContentScope(
            chatsAndAssistants: false,
            attachments: true,
            workspaces: true,
            fontsAndAvatars: true,
            settings: true,
            skills: true,
          ),
        ),
        mode: RestoreMode.overwrite,
      );

      expect(await existingFile.exists(), isFalse);
      expect(
        await File('${fontsDir.path}/custom.ttf').readAsBytes(),
        List<int>.filled(128, 5),
      );
    });

    test('restores skill files in overwrite and merge modes', () async {
      final sourceDir = Directory('${root.path}/source_skills');
      await sourceDir.create(recursive: true);
      final sourceFile = File('${sourceDir.path}/pdf-processing/SKILL.md');
      await sourceFile.create(recursive: true);
      await sourceFile.writeAsString('---\nname: pdf-processing\n---\nbody');

      final zipFile = File('${root.path}/skills_backup.zip');
      final encoder = ZipFileEncoder();
      encoder.create(zipFile.path);
      encoder.addFileSync(sourceFile, 'skills/pdf-processing/SKILL.md');
      encoder.closeSync();

      final skillsDir = Directory('${root.path}/skills');
      await skillsDir.create(recursive: true);
      final existingFile = File('${skillsDir.path}/local-skill/SKILL.md');
      await existingFile.create(recursive: true);
      await existingFile.writeAsString('---\nname: local-skill\n---\nbody');

      final sync = DataSync(
        preferences: businessPrefs,
        chatService: ChatService(),
      );
      await sync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(
          content: BackupContentScope(
            chatsAndAssistants: false,
            attachments: true,
            workspaces: true,
            fontsAndAvatars: true,
            settings: true,
            skills: true,
          ),
        ),
        mode: RestoreMode.merge,
      );

      expect(await existingFile.exists(), isTrue);
      expect(
        await File('${skillsDir.path}/pdf-processing/SKILL.md').readAsString(),
        contains('name: pdf-processing'),
      );

      await sync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(
          content: BackupContentScope(
            chatsAndAssistants: false,
            attachments: true,
            workspaces: true,
            fontsAndAvatars: true,
            settings: true,
            skills: true,
          ),
        ),
        mode: RestoreMode.overwrite,
      );

      expect(await existingFile.exists(), isFalse);
      expect(
        await File('${skillsDir.path}/pdf-processing/SKILL.md').readAsString(),
        contains('name: pdf-processing'),
      );
    });

    test(
      'merge restore replaces skills only when the backup entry is newer',
      () async {
        final sourceDir = Directory('${root.path}/source_skills');
        await sourceDir.create(recursive: true);
        final sourceFile = File('${sourceDir.path}/pdf-processing/SKILL.md');
        await sourceFile.create(recursive: true);
        await sourceFile.writeAsString(
          '---\nname: pdf-processing\n---\nbackup version',
        );
        // Even seconds: ZIP DOS timestamps round down to 2s granularity.
        await sourceFile.setLastModified(DateTime(2026, 1, 2));

        final zipFile = File('${root.path}/skills_backup.zip');
        final encoder = ZipFileEncoder();
        encoder.create(zipFile.path);
        encoder.addFileSync(sourceFile, 'skills/pdf-processing/SKILL.md');
        encoder.closeSync();

        final skillsDir = Directory('${root.path}/skills');
        await skillsDir.create(recursive: true);
        final localFile = File('${skillsDir.path}/pdf-processing/SKILL.md');
        await localFile.create(recursive: true);
        await localFile.writeAsString(
          '---\nname: pdf-processing\n---\nlocal version',
        );
        await localFile.setLastModified(DateTime(2026, 1, 1));

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: ChatService(),
        );
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: true,
              workspaces: true,
              fontsAndAvatars: true,
              settings: true,
              skills: true,
            ),
          ),
          mode: RestoreMode.merge,
        );

        // Backup entry (Jan 2) is newer than the local copy (Jan 1) → replaced.
        expect(await localFile.readAsString(), contains('backup version'));

        // Local copy becomes newer than the backup entry (Jan 3) → kept.
        await localFile.writeAsString(
          '---\nname: pdf-processing\n---\nlocal version',
        );
        await localFile.setLastModified(DateTime(2026, 1, 3));
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: true,
              workspaces: true,
              fontsAndAvatars: true,
              settings: true,
              skills: true,
            ),
          ),
          mode: RestoreMode.merge,
        );

        expect(await localFile.readAsString(), contains('local version'));
      },
    );

    test('merge restore replaces workspaces files only when the backup entry '
        'is newer', () async {
      final sourceDir = Directory('${root.path}/source_ws');
      await sourceDir.create(recursive: true);
      final sourceFile = File('${sourceDir.path}/default/report.md');
      await sourceFile.create(recursive: true);
      await sourceFile.writeAsString('backup version');
      // Even seconds: ZIP DOS timestamps round down to 2s granularity.
      await sourceFile.setLastModified(DateTime(2026, 1, 2));

      final zipFile = File('${root.path}/ws_backup.zip');
      final encoder = ZipFileEncoder();
      encoder.create(zipFile.path);
      encoder.addFileSync(sourceFile, 'workspaces/default/report.md');
      encoder.closeSync();

      final wsDir = Directory('${root.path}/workspaces');
      await wsDir.create(recursive: true);
      final localFile = File('${wsDir.path}/default/report.md');
      await localFile.create(recursive: true);
      await localFile.writeAsString('local version');
      await localFile.setLastModified(DateTime(2026, 1, 1));

      final sync = DataSync(
        preferences: businessPrefs,
        chatService: ChatService(),
      );
      await sync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(
          content: BackupContentScope(
            chatsAndAssistants: false,
            attachments: true,
            workspaces: true,
            fontsAndAvatars: true,
            settings: true,
            skills: true,
          ),
        ),
        mode: RestoreMode.merge,
      );

      // Backup entry (Jan 2) is newer than the local copy (Jan 1) →
      // replaced (newer-wins, same rule as skills).
      expect(await localFile.readAsString(), contains('backup version'));

      // Local copy becomes newer than the backup entry (Jan 3) → kept.
      await localFile.writeAsString('local version');
      await localFile.setLastModified(DateTime(2026, 1, 3));
      await sync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(
          content: BackupContentScope(
            chatsAndAssistants: false,
            attachments: true,
            workspaces: true,
            fontsAndAvatars: true,
            settings: true,
            skills: true,
          ),
        ),
        mode: RestoreMode.merge,
      );

      expect(await localFile.readAsString(), contains('local version'));
    });

    test(
      'countFilesForSince mirrors pack rules (mtime, dot, skills)',
      () async {
        final since = DateTime(2026, 1, 1, 12);
        // upload/: one file before since (excluded), one after (included).
        final uploadDir = Directory('${root.path}/upload');
        await uploadDir.create(recursive: true);
        final oldFile = File('${uploadDir.path}/old.bin');
        await oldFile.writeAsBytes(List<int>.filled(10, 1));
        await oldFile.setLastModified(DateTime(2026, 1, 1, 11));
        final newFile = File('${uploadDir.path}/new.bin');
        await newFile.writeAsBytes(List<int>.filled(20, 2));
        await newFile.setLastModified(DateTime(2026, 1, 2));

        // workspaces/: visible file after since (included), dot-prefixed file
        // after since (excluded — one dotfile rule, mirrors _packZipSync).
        final wsDir = Directory('${root.path}/workspaces/default');
        await wsDir.create(recursive: true);
        final wsFile = File('${wsDir.path}/note.md');
        await wsFile.writeAsBytes(List<int>.filled(30, 3));
        await wsFile.setLastModified(DateTime(2026, 1, 2));
        final dotFile = File('${wsDir.path}/.fetch_cache/x.md');
        await dotFile.create(recursive: true);
        await dotFile.writeAsBytes(List<int>.filled(40, 4));
        await dotFile.setLastModified(DateTime(2026, 1, 2));

        // skills/: one file after since (always counted).
        final skillsDir = Directory('${root.path}/skills');
        await skillsDir.create(recursive: true);
        final skillFile = File('${skillsDir.path}/pdf-processing/SKILL.md');
        await skillFile.create(recursive: true);
        await skillFile.writeAsBytes(List<int>.filled(50, 5));
        await skillFile.setLastModified(DateTime(2026, 1, 2));

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: ChatService(),
        );
        final result = await sync.countFilesForSince(since);

        // upload new.bin (20) + workspaces note.md (30) + skill (50).
        expect(result.fileCount, 3);
        expect(result.totalBytes, 100);
      },
    );

    test(
      'pack prunes dot directories at walk time (same output set)',
      () async {
        // One visible file plus deep dot trees (.sandbox rootfs style and a
        // .github dir). The pruned walk must pack exactly the visible file —
        // identical to the old full-recursive walk + per-file dot filter.
        final wsDir = Directory('${root.path}/workspaces/default');
        await wsDir.create(recursive: true);
        await File('${wsDir.path}/note.md').writeAsString('hello');
        await File(
          '${wsDir.path}/.github/workflows/release.yml',
        ).create(recursive: true);
        await File(
          '${wsDir.path}/.sandbox/linux/usr/bin/python3',
        ).create(recursive: true);
        await File(
          '${wsDir.path}/.sandbox/linux/usr/lib/libpython.so',
        ).create(recursive: true);
        final dotFile = File('${wsDir.path}/.gitignore');
        await dotFile.writeAsString('ignored');

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: ChatService(),
        );
        final zipFile = await sync.prepareBackupFile(
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: true,
              workspaces: true,
              fontsAndAvatars: true,
              settings: true,
              skills: true,
            ),
          ),
        );

        final input = InputFileStream(zipFile.path);
        final Archive archive;
        try {
          archive = ZipDecoder().decodeStream(input);
        } finally {
          await input.close();
        }
        expect(archive.findFile('workspaces/default/note.md'), isNotNull);
        expect(
          archive.findFile('workspaces/default/.github/workflows/release.yml'),
          isNull,
        );
        expect(
          archive.findFile('workspaces/default/.sandbox/linux/usr/bin/python3'),
          isNull,
        );
        expect(
          archive.findFile(
            'workspaces/default/.sandbox/linux/usr/lib/libpython.so',
          ),
          isNull,
        );
        expect(archive.findFile('workspaces/default/.gitignore'), isNull);

        // The count preview must agree (dots excluded, visible file counted).
        final counted = await sync.countFilesForSince(DateTime(2026, 1, 1));
        expect(counted.fileCount, 1);
        expect(counted.totalBytes, 5);
      },
    );

    test(
      'prepareBackupFile reports stages in order (generating, packing)',
      () async {
        final uploadDir = Directory('${root.path}/upload');
        await uploadDir.create(recursive: true);
        await File(
          '${uploadDir.path}/a.bin',
        ).writeAsBytes(List<int>.filled(16, 7));

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: ChatService(),
        );
        final stages = <BackupStage>[];
        final zipFile = await sync.prepareBackupFile(
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: true,
              workspaces: true,
              fontsAndAvatars: true,
              settings: true,
              skills: true,
            ),
          ),
          onStage: stages.add,
        );

        expect(stages, [BackupStage.generating, BackupStage.packing]);

        final input = InputFileStream(zipFile.path);
        try {
          final archive = ZipDecoder().decodeStream(input);
          expect(archive.findFile('upload/a.bin'), isNotNull);
        } finally {
          await input.close();
        }
      },
    );

    test(
      'merge restore newer-wins survives odd-second mtimes (UT timestamp)',
      () async {
        // Round-trip through the PRODUCTION writer + extractor: a genuinely
        // newer peer copy whose mtime is an odd second (2026-01-02 00:00:57)
        // must win over a local copy 500 ms older. DOS timestamps round down
        // to even seconds (56) and would lose to 56.5; the UT (0x5455) extra
        // field must carry the true second.
        final wsDir = Directory('${root.path}/workspaces/default');
        await wsDir.create(recursive: true);
        final liveFile = File('${wsDir.path}/report.md');
        await liveFile.create(recursive: true);
        await liveFile.writeAsString('backup version');
        await liveFile.setLastModified(DateTime(2026, 1, 2, 0, 0, 57));

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: ChatService(),
        );
        final zipFile = await sync.prepareBackupFile(
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: true,
              workspaces: true,
              fontsAndAvatars: true,
              settings: true,
              skills: true,
            ),
          ),
          incremental: IncrementalBackupConfig(
            since: DateTime(2026, 1, 1),
            includeSettings: false,
            includeFiles: true,
            updateBackupTime: false,
          ),
        );

        // The live copy now becomes device B's genuinely older copy (56.5s,
        // inside the 2s DOS rounding window).
        await liveFile.writeAsString('local version');
        await liveFile.setLastModified(DateTime(2026, 1, 2, 0, 0, 56, 500));

        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: true,
              workspaces: true,
              fontsAndAvatars: true,
              settings: true,
              skills: true,
            ),
          ),
          mode: RestoreMode.merge,
        );

        // Odd-second backup mtime must win (57 > 56.5).
        expect(await liveFile.readAsString(), contains('backup version'));

        // Local copy becomes genuinely newer (57.5s) → kept.
        await liveFile.writeAsString('local version');
        await liveFile.setLastModified(DateTime(2026, 1, 2, 0, 0, 57, 500));
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: true,
              workspaces: true,
              fontsAndAvatars: true,
              settings: true,
              skills: true,
            ),
          ),
          mode: RestoreMode.merge,
        );

        expect(await liveFile.readAsString(), contains('local version'));
      },
    );

    test(
      'LAN-sync manifest restores ms-precision mtimes (sync_manifest.json wins)',
      () async {
        // The LAN-sync delta flow packs via includeFilePaths and rides a
        // sync_manifest.json with ms mtimes. After a restore the file's mtime
        // must equal the sender's exact stored value — otherwise the next
        // sync's delta comparison sees drift and re-sends it forever. On a
        // sub-second filesystem the manifest value (with the .789ms) also
        // proves the manifest path wins over the ZIP's second-granularity UT
        // field; on a whole-second filesystem (some CI runners) both values
        // collapse to the same whole second and the round-trip equality is
        // the meaningful assertion.
        final uploadDir = Directory('${root.path}/upload');
        await uploadDir.create(recursive: true);
        final sourceFile = File('${uploadDir.path}/a.bin');
        await sourceFile.writeAsBytes(List<int>.filled(16, 7));
        await sourceFile.setLastModified(DateTime(2026, 1, 2, 12, 34, 56, 789));
        final srcMtimeMs = sourceFile
            .statSync()
            .modified
            .millisecondsSinceEpoch;

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: ChatService(),
        );
        final zipFile = await sync.prepareBackupFile(
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: true,
              workspaces: true,
              fontsAndAvatars: true,
              settings: true,
              skills: true,
            ),
          ),
          incremental: IncrementalBackupConfig(
            since: DateTime(2026, 1, 1),
            includeSettings: false,
            includeFiles: true,
            updateBackupTime: false,
            includeFilePaths: {'upload/a.bin'},
          ),
        );

        // Peer lacks the file entirely → merge copies it (absent → copied).
        await sourceFile.delete();

        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: true,
              workspaces: true,
              fontsAndAvatars: true,
              settings: true,
              skills: true,
            ),
          ),
          mode: RestoreMode.merge,
        );

        expect(await sourceFile.exists(), isTrue);
        final restoredMs = sourceFile
            .statSync()
            .modified
            .millisecondsSinceEpoch;
        expect(restoredMs, srcMtimeMs);
        await DataSync.cleanupTemporaryBackupFile(zipFile);
      },
    );

    test(
      'LAN-sync delta: upload merge is newer-wins at ms precision',
      () async {
        // A delta sync sends an upload file only when the sender's ms mtime is
        // strictly newer. The receiver's merge must therefore replace the local
        // copy using the SAME ms-precision manifest mtime — otherwise a
        // same-second newer sender (.800) loses to a same-second older local
        // (.200) because the ZIP's UT field rounds down to whole seconds, and
        // the file would re-send forever without ever being applied. Some CI
        // filesystems store only whole-second mtimes, which collapses this
        // scenario into a tie — the conservative keep-local is then correct.
        final uploadDir = Directory('${root.path}/upload');
        await uploadDir.create(recursive: true);
        final target = File('${uploadDir.path}/a.bin');
        final packed = List<int>.filled(16, 7);
        await target.writeAsBytes(packed);
        await target.setLastModified(DateTime(2026, 1, 2, 12, 34, 56, 800));
        final srcMs = target.statSync().modified.millisecondsSinceEpoch;

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: ChatService(),
        );
        final zipFile = await sync.prepareBackupFile(
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: true,
              workspaces: true,
              fontsAndAvatars: true,
              settings: true,
              skills: true,
            ),
          ),
          incremental: IncrementalBackupConfig(
            since: DateTime(2026, 1, 1),
            includeSettings: false,
            includeFiles: true,
            updateBackupTime: false,
            includeFilePaths: {'upload/a.bin'},
          ),
        );

        // Local copy becomes the OLDER one within the same second — the exact
        // scenario where the delta (ms) and a second-precision merge disagree.
        await target.writeAsString('local version');
        await target.setLastModified(DateTime(2026, 1, 2, 12, 34, 56, 200));
        final localMs = target.statSync().modified.millisecondsSinceEpoch;

        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: true,
              workspaces: true,
              fontsAndAvatars: true,
              settings: true,
              skills: true,
            ),
          ),
          mode: RestoreMode.merge,
        );

        if (srcMs > localMs) {
          // Sub-second filesystem: the strictly-newer backup wins and its
          // ms mtime is applied.
          expect(await target.readAsBytes(), packed);
          expect(target.statSync().modified.millisecondsSinceEpoch, srcMs);
        } else {
          // Whole-second filesystem: the same-second tie collapsed to equal
          // mtimes — conservative keep-local is correct.
          expect(await target.readAsString(), 'local version');
        }

        // Local becomes genuinely newer (clearly later whole second) → kept
        // (never regressed).
        await target.writeAsString('local version 2');
        await target.setLastModified(DateTime(2026, 1, 2, 12, 34, 58));
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: true,
              workspaces: true,
              fontsAndAvatars: true,
              settings: true,
              skills: true,
            ),
          ),
          mode: RestoreMode.merge,
        );
        expect(await target.readAsString(), 'local version 2');

        await DataSync.cleanupTemporaryBackupFile(zipFile);
      },
    );

    test(
      'restore progress fraction never regresses across directories',
      () async {
        // Three trees so the cumulative totalFiles jumps at directory
        // boundaries (upload → images → workspaces). The raw fraction would
        // dip to 0.5 after upload/ completes; the reported fraction must be
        // monotonic non-decreasing.
        final zipFile = File('${root.path}/progress.zip');
        final encoder = ZipFileEncoder();
        encoder.create(zipFile.path);
        final src = Directory('${root.path}/progress_src');
        for (final name in [
          'upload/a.txt',
          'images/b.txt',
          'workspaces/c.txt',
        ]) {
          final f = File('${src.path}/$name');
          await f.create(recursive: true);
          await f.writeAsString(name);
          encoder.addFileSync(f, name);
        }
        encoder.closeSync();

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: ChatService(),
        );
        final fractions = <double>[];
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: true,
              workspaces: true,
              fontsAndAvatars: true,
              settings: true,
              skills: true,
            ),
          ),
          mode: RestoreMode.merge,
          onProgress: (p) {
            if (p.stage == RestoreStage.copyingFiles && p.fraction != null) {
              fractions.add(p.fraction!);
            }
          },
        );

        expect(fractions, isNotEmpty);
        for (var i = 1; i < fractions.length; i++) {
          expect(
            fractions[i],
            greaterThanOrEqualTo(fractions[i - 1]),
            reason:
                'fraction regressed at index $i: ${fractions[i - 1]} -> '
                '${fractions[i]}',
          );
        }
      },
    );

    test(
      'skills are exported and restored regardless of includeFiles',
      () async {
        final skillsDir = Directory('${root.path}/skills');
        await skillsDir.create(recursive: true);
        final skillFile = File('${skillsDir.path}/pdf-processing/SKILL.md');
        await skillFile.create(recursive: true);
        await skillFile.writeAsString('---\nname: pdf-processing\n---\nbody');

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: ChatService(),
        );
        final backupFile = await sync.prepareBackupFile(
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: false,
              workspaces: false,
              fontsAndAvatars: false,
              settings: true,
              skills: true,
            ),
          ),
        );

        final input = InputFileStream(backupFile.path);
        Archive? archive;
        try {
          archive = ZipDecoder().decodeStream(input);
          expect(archive.findFile('skills/pdf-processing/SKILL.md'), isNotNull);
        } finally {
          archive?.clearSync();
          input.closeSync();
        }

        await skillsDir.delete(recursive: true);
        await sync.restoreFromLocalFile(
          backupFile,
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: false,
              workspaces: false,
              fontsAndAvatars: false,
              settings: true,
              skills: true,
            ),
          ),
          mode: RestoreMode.overwrite,
        );

        expect(await skillFile.exists(), isTrue);
        expect(
          await skillFile.readAsString(),
          contains('name: pdf-processing'),
        );

        await DataSync.cleanupTemporaryBackupFile(backupFile);
      },
    );

    test(
      'incremental: analyzeIncrementalScope counts skills unconditionally',
      () async {
        final chatService = ChatService();
        await chatService.init();

        final since = DateTime.now().subtract(const Duration(days: 30));
        final skillsDir = Directory('${root.path}/skills');
        await skillsDir.create(recursive: true);
        final skillFile = File('${skillsDir.path}/pdf-processing/SKILL.md');
        await skillFile.create(recursive: true);
        await skillFile.writeAsString('---\nname: pdf-processing\n---\nbody');

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: chatService,
        );
        final scope = await sync.analyzeIncrementalScope(
          IncrementalBackupConfig(since: since, includeFiles: false),
        );

        expect(scope.newFileCount, 1);

        await chatService.close();
      },
    );

    test('merge restore gates settings.json by scope: settings-only admits mcp '
        'but excludes assistant memories', () async {
      businessPrefs = BusinessPreferences.memoryForTests({
        'assistant_memories_v1': jsonEncode([
          {'id': 1, 'assistantId': 'local', 'content': 'keep local'},
          {'id': 2, 'assistantId': 'dup', 'content': 'same memory'},
        ]),
        'mcp_servers_v1': jsonEncode([
          {
            'id': 'local-server',
            'enabled': true,
            'name': 'Local Server',
            'transport': 'sse',
            'url': 'http://local.example/sse',
            'tools': [],
          },
          {
            'id': 'shared-server',
            'enabled': true,
            'name': 'Local Shared Server',
            'transport': 'sse',
            'url': 'http://local-shared.example/sse',
            'tools': [],
          },
        ]),
      });

      final settingsFile = File('${root.path}/settings.json');
      await settingsFile.writeAsString(
        jsonEncode({
          'assistant_memories_v1': jsonEncode([
            {'id': 1, 'assistantId': 'remote', 'content': 'remote memory'},
            {'id': 2, 'assistantId': 'dup', 'content': 'same memory'},
            {'id': 4, 'assistantId': 'new', 'content': 'new memory'},
          ]),
          'mcp_servers_v1': jsonEncode([
            {
              'id': 'shared-server',
              'enabled': false,
              'name': 'Imported Shared Server',
              'transport': 'sse',
              'url': 'http://imported-shared.example/sse',
              'tools': [],
            },
            {
              'id': 'remote-server',
              'enabled': true,
              'name': 'Remote Server',
              'transport': 'http',
              'url': 'http://remote.example/mcp',
              'tools': [],
            },
          ]),
        }),
      );

      final zipFile = File('${root.path}/settings_merge_backup.zip');
      final encoder = ZipFileEncoder();
      encoder.create(zipFile.path);
      encoder.addFileSync(settingsFile, 'settings.json');
      encoder.closeSync();

      final sync = DataSync(
        preferences: businessPrefs,
        chatService: ChatService(),
      );
      await sync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(
          content: BackupContentScope(
            chatsAndAssistants: false,
            attachments: false,
            workspaces: false,
            fontsAndAvatars: false,
            settings: true,
            skills: true,
          ),
        ),
        mode: RestoreMode.merge,
      );

      final prefs = businessPrefs;
      // chats bit OFF: assistant memories stay untouched (local-only).
      final memories =
          jsonDecode(prefs.getString('assistant_memories_v1')!) as List;
      expect(memories, hasLength(2));
      expect(
        memories.any(
          (e) =>
              (e as Map)['assistantId'] == 'remote' ||
              e['assistantId'] == 'new',
        ),
        isFalse,
      );
      // settings bit ON: mcp servers still merge.
      final servers = jsonDecode(prefs.getString('mcp_servers_v1')!) as List;
      expect(servers, hasLength(3));
      expect(
        servers.any(
          (e) =>
              (e as Map)['id'] == 'remote-server' &&
              e['name'] == 'Remote Server',
        ),
        isTrue,
      );
    });

    test('merge restore gates settings.json by scope: chats-only admits '
        'assistant memories but excludes normal settings', () async {
      businessPrefs = BusinessPreferences.memoryForTests({
        'mcp_servers_v1': jsonEncode([
          {
            'id': 'local-server',
            'enabled': true,
            'name': 'Local Server',
            'transport': 'sse',
            'url': 'http://local.example/sse',
            'tools': [],
          },
        ]),
      });

      final settingsFile = File('${root.path}/settings.json');
      await settingsFile.writeAsString(
        jsonEncode({
          'assistant_memories_v1': jsonEncode([
            {'id': 1, 'assistantId': 'remote', 'content': 'remote memory'},
          ]),
          'mcp_servers_v1': jsonEncode([
            {
              'id': 'remote-server',
              'enabled': true,
              'name': 'Remote Server',
              'transport': 'http',
              'url': 'http://remote.example/mcp',
              'tools': [],
            },
          ]),
        }),
      );

      final zipFile = File('${root.path}/settings_chats_merge_backup.zip');
      final encoder = ZipFileEncoder();
      encoder.create(zipFile.path);
      encoder.addFileSync(settingsFile, 'settings.json');
      encoder.closeSync();

      final sync = DataSync(
        preferences: businessPrefs,
        chatService: ChatService(),
      );
      await sync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(
          content: BackupContentScope(
            chatsAndAssistants: true,
            attachments: false,
            workspaces: false,
            fontsAndAvatars: false,
            settings: false,
            skills: true,
          ),
        ),
        mode: RestoreMode.merge,
      );

      final prefs = businessPrefs;
      // chats bit ON: assistant memories imported.
      final memories =
          jsonDecode(prefs.getString('assistant_memories_v1')!) as List;
      expect(memories, hasLength(1));
      expect(
        memories.any(
          (e) =>
              (e as Map)['assistantId'] == 'remote' &&
              e['content'] == 'remote memory',
        ),
        isTrue,
      );
      // settings bit OFF: normal settings untouched.
      final servers = jsonDecode(prefs.getString('mcp_servers_v1')!) as List;
      expect(servers, hasLength(1));
      expect(servers.any((e) => (e as Map)['id'] == 'remote-server'), isFalse);
    });

    group('merge restore: provider proxy is device-local (issue #512)', () {
      Future<void> restoreMerge(Map<String, dynamic> backupSettings) async {
        final settingsFile = File('${root.path}/proxy_settings.json');
        await settingsFile.writeAsString(jsonEncode(backupSettings));

        final zipFile = File('${root.path}/proxy_merge_backup.zip');
        final encoder = ZipFileEncoder();
        encoder.create(zipFile.path);
        encoder.addFileSync(settingsFile, 'settings.json');
        encoder.closeSync();

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: ChatService(),
        );
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: false,
              workspaces: false,
              fontsAndAvatars: false,
              settings: true,
              skills: true,
            ),
          ),
          mode: RestoreMode.merge,
        );
      }

      Map<String, dynamic> providerConfig(
        String id,
        String baseUrl,
        Map<String, dynamic> proxy,
      ) => {
        'id': id,
        'type': 'openai',
        'name': id,
        'baseUrl': baseUrl,
        'apiKey': 'key-$id',
        'models': <String>[],
        ...proxy,
      };

      const localProxy = {
        'proxyEnabled': true,
        'proxyType': 'socks5',
        'proxyHost': '127.0.0.1',
        'proxyPort': '1080',
        'proxyUsername': 'local-user',
        'proxyPassword': 'local-pass',
      };

      const backupProxy = {
        'proxyEnabled': false,
        'proxyType': 'http',
        'proxyHost': 'proxy.backup.example',
        'proxyPort': '3128',
        'proxyUsername': '',
        'proxyPassword': '',
      };

      test(
        'existing provider keeps local proxy, backup updates other fields',
        () async {
          businessPrefs = BusinessPreferences.memoryForTests({
            'provider_configs_v1': jsonEncode({
              'MyProvider': providerConfig(
                'MyProvider',
                'https://local.example/v1',
                localProxy,
              ),
            }),
          });

          await restoreMerge({
            'provider_configs_v1': jsonEncode({
              'MyProvider': providerConfig(
                'MyProvider',
                'https://backup.example/v1',
                backupProxy,
              ),
            }),
          });

          final prefs = businessPrefs;
          final configs =
              jsonDecode(prefs.getString('provider_configs_v1')!)
                  as Map<String, dynamic>;
          final merged = configs['MyProvider'] as Map<String, dynamic>;

          // Non-proxy fields come from the backup.
          expect(merged['baseUrl'], 'https://backup.example/v1');
          expect(merged['apiKey'], 'key-MyProvider');

          // Proxy fields stay local.
          expect(merged['proxyEnabled'], isTrue);
          expect(merged['proxyType'], 'socks5');
          expect(merged['proxyHost'], '127.0.0.1');
          expect(merged['proxyPort'], '1080');
          expect(merged['proxyUsername'], 'local-user');
          expect(merged['proxyPassword'], 'local-pass');
        },
      );

      test('new provider imported from backup keeps its proxy', () async {
        businessPrefs = BusinessPreferences.memoryForTests({
          'provider_configs_v1': jsonEncode({
            'Existing': providerConfig(
              'Existing',
              'https://local.example/v1',
              localProxy,
            ),
          }),
        });

        await restoreMerge({
          'provider_configs_v1': jsonEncode({
            'Existing': providerConfig(
              'Existing',
              'https://backup.example/v1',
              backupProxy,
            ),
            'NewProvider': providerConfig(
              'NewProvider',
              'https://new.example/v1',
              backupProxy,
            ),
          }),
        });

        final prefs = businessPrefs;
        final configs =
            jsonDecode(prefs.getString('provider_configs_v1')!)
                as Map<String, dynamic>;

        // Existing provider: proxy preserved locally, other fields updated.
        final existing = configs['Existing'] as Map<String, dynamic>;
        expect(existing['baseUrl'], 'https://backup.example/v1');
        expect(existing['proxyHost'], '127.0.0.1');

        // New provider: proxy imported as-is.
        final added = configs['NewProvider'] as Map<String, dynamic>;
        expect(added['proxyEnabled'], isFalse);
        expect(added['proxyHost'], 'proxy.backup.example');
        expect(added['proxyPort'], '3128');
      });

      test(
        'legacy local provider without a proxy block gets no-proxy defaults',
        () async {
          businessPrefs = BusinessPreferences.memoryForTests({
            'provider_configs_v1': jsonEncode({
              'Legacy': {
                'id': 'Legacy',
                'type': 'openai',
                'name': 'Legacy',
                'baseUrl': 'https://local.example/v1',
                'apiKey': 'legacy-key',
                'models': <String>[],
              },
            }),
          });

          await restoreMerge({
            'provider_configs_v1': jsonEncode({
              'Legacy': providerConfig(
                'Legacy',
                'https://backup.example/v1',
                backupProxy,
              ),
            }),
          });

          final prefs = businessPrefs;
          final configs =
              jsonDecode(prefs.getString('provider_configs_v1')!)
                  as Map<String, dynamic>;
          final merged = configs['Legacy'] as Map<String, dynamic>;

          // Other fields still come from the backup.
          expect(merged['baseUrl'], 'https://backup.example/v1');

          // But the backup's proxy is replaced by the no-proxy defaults.
          expect(merged['proxyEnabled'], isFalse);
          expect(merged['proxyType'], 'http');
          expect(merged['proxyHost'], '');
          expect(merged['proxyPort'], '8080');
          expect(merged['proxyUsername'], '');
          expect(merged['proxyPassword'], '');
        },
      );

      test(
        'partial local proxy block never blends backup proxy fields',
        () async {
          // A local config imported from a third-party tool may carry only part
          // of the proxy block (e.g. no password fields at all).
          businessPrefs = BusinessPreferences.memoryForTests({
            'provider_configs_v1': jsonEncode({
              'Partial': {
                'id': 'Partial',
                'type': 'openai',
                'name': 'Partial',
                'baseUrl': 'https://local.example/v1',
                'apiKey': 'partial-key',
                'models': <String>[],
                'proxyEnabled': true,
                'proxyType': 'socks5',
                'proxyHost': '127.0.0.1',
                'proxyPort': '1080',
              },
            }),
          });

          await restoreMerge({
            'provider_configs_v1': jsonEncode({
              'Partial': providerConfig(
                'Partial',
                'https://backup.example/v1',
                backupProxy,
              ),
            }),
          });

          final prefs = businessPrefs;
          final configs =
              jsonDecode(prefs.getString('provider_configs_v1')!)
                  as Map<String, dynamic>;
          final merged = configs['Partial'] as Map<String, dynamic>;

          // Present local fields win.
          expect(merged['proxyEnabled'], isTrue);
          expect(merged['proxyHost'], '127.0.0.1');

          // Missing local fields fall to the no-proxy defaults, never the
          // backup's values (backup had username/password empty, host
          // proxy.backup.example — none of it may survive).
          expect(merged['proxyUsername'], '');
          expect(merged['proxyPassword'], '');
        },
      );

      test('malformed provider entry does not abort the whole merge', () async {
        businessPrefs = BusinessPreferences.memoryForTests({
          'provider_configs_v1': jsonEncode({
            'LocalOnly': providerConfig(
              'LocalOnly',
              'https://local.example/v1',
              localProxy,
            ),
          }),
        });

        await restoreMerge({
          'provider_configs_v1': jsonEncode({
            'GoodProvider': providerConfig(
              'GoodProvider',
              'https://backup.example/v1',
              backupProxy,
            ),
            // Non-object provider value (hand-edited or legacy data).
            'BrokenProvider': 'not-a-config',
          }),
        });

        final prefs = businessPrefs;
        final configs =
            jsonDecode(prefs.getString('provider_configs_v1')!)
                as Map<String, dynamic>;

        // The malformed entry is carried over verbatim and the merge of the
        // valid entries still completes.
        expect(configs['BrokenProvider'], 'not-a-config');
        expect(configs.keys, containsAll(['LocalOnly', 'GoodProvider']));
        final added = configs['GoodProvider'] as Map<String, dynamic>;
        expect(added['proxyHost'], 'proxy.backup.example');
      });

      test('local providers absent from the backup survive merge', () async {
        businessPrefs = BusinessPreferences.memoryForTests({
          'provider_configs_v1': jsonEncode({
            'LocalOnly': providerConfig(
              'LocalOnly',
              'https://local.example/v1',
              localProxy,
            ),
          }),
        });

        await restoreMerge({
          'provider_configs_v1': jsonEncode({
            'BackupOnly': providerConfig(
              'BackupOnly',
              'https://backup.example/v1',
              backupProxy,
            ),
          }),
        });

        final prefs = businessPrefs;
        final configs =
            jsonDecode(prefs.getString('provider_configs_v1')!)
                as Map<String, dynamic>;

        expect(configs.keys, containsAll(['LocalOnly', 'BackupOnly']));
        final local = configs['LocalOnly'] as Map<String, dynamic>;
        expect(local['baseUrl'], 'https://local.example/v1');
        expect(local['proxyHost'], '127.0.0.1');
      });
    });

    test('cleans temporary restore files after a file-copy failure', () async {
      final sourceDir = Directory('${root.path}/source_upload');
      await sourceDir.create(recursive: true);
      final sourceFile = File('${sourceDir.path}/file.txt');
      await sourceFile.writeAsString('payload');

      final zipFile = File('${root.path}/restore_source.zip');
      final encoder = ZipFileEncoder();
      encoder.create(zipFile.path);
      encoder.addFileSync(sourceFile, 'upload/file.txt');
      encoder.closeSync();

      // A file occupying the upload target makes the files-restore step throw
      // (EEXIST). Since #475, that failure is logged-and-continued — the
      // restore completes and the downloaded temp file is still cleaned up.
      await File('${root.path}/upload').writeAsString('not a directory');

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        request.response.statusCode = HttpStatus.ok;
        await request.response.addStream(zipFile.openRead());
        await request.response.close();
      });

      final sync = DataSync(
        preferences: businessPrefs,
        chatService: ChatService(),
      );
      final tmpDir = Directory('${root.path}/tmp');
      final item = BackupFileItem(
        href: Uri.parse('http://127.0.0.1:${server.port}/restore_source.zip'),
        displayName: 'restore_source.zip',
        size: await zipFile.length(),
        lastModified: null,
      );

      await sync.restoreFromWebDav(
        const WebDavConfig(
          content: BackupContentScope(
            chatsAndAssistants: false,
            attachments: true,
            workspaces: true,
            fontsAndAvatars: true,
            settings: true,
            skills: true,
          ),
        ),
        item,
      );

      expect(await File('${tmpDir.path}/restore_source.zip').exists(), isFalse);
      expect(await tmpDir.list().toList(), isEmpty);
    });

    test(
      'incremental: since param produces cuplivo_incr_ prefix and includeSettings=false excludes settings.json',
      () async {
        final sync = DataSync(
          preferences: businessPrefs,
          chatService: ChatService(),
        );
        final backupFile = await sync.prepareBackupFile(
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: false,
              workspaces: false,
              fontsAndAvatars: false,
              settings: true,
              skills: true,
            ),
          ),
          incremental: IncrementalBackupConfig(
            since: DateTime.now().subtract(const Duration(days: 30)),
            includeSettings: false,
          ),
        );

        expect(p.basename(backupFile.path).startsWith('cuplivo_incr_'), isTrue);

        final input = InputFileStream(backupFile.path);
        Archive? archive;
        try {
          archive = ZipDecoder().decodeStream(input);
          expect(archive.findFile('settings.json'), isNull);
        } finally {
          archive?.clearSync();
          input.closeSync();
        }

        await DataSync.cleanupTemporaryBackupFile(backupFile);
      },
    );

    test(
      'incremental: no since param produces normal filename without cuplivo_incr_',
      () async {
        final sync = DataSync(
          preferences: businessPrefs,
          chatService: ChatService(),
        );
        final backupFile = await sync.prepareBackupFile(
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: false,
              workspaces: false,
              fontsAndAvatars: false,
              settings: true,
              skills: true,
            ),
          ),
        );

        expect(
          p.basename(backupFile.path).startsWith('cuplivo_incr_'),
          isFalse,
        );
        expect(
          p.basename(backupFile.path),
          matches(RegExp(r'kelivo_backup_\d{8}T\d{6}\.\d{6}\.zip')),
        );

        await DataSync.cleanupTemporaryBackupFile(backupFile);
      },
    );

    test(
      'incremental: cuplivo_incr_ filename forces merge mode on restore',
      () async {
        final zipFile = File(
          '${root.path}/cuplivo_incr_20260703-123456-123456_20260701-000000.zip',
        );
        final encoder = ZipFileEncoder();
        encoder.create(zipFile.path);
        final settingsTmp = File('${root.path}/tmp_settings.json');
        await settingsTmp.writeAsString('{}');
        encoder.addFileSync(settingsTmp, 'settings.json');
        encoder.closeSync();

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: ChatService(),
        );
        // Should not throw: overwrite mode is silently degraded to merge
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: false,
              workspaces: false,
              fontsAndAvatars: false,
              settings: true,
              skills: true,
            ),
          ),
          mode: RestoreMode.overwrite,
        );
      },
    );

    test('incremental: includeFiles=true packs upload and fonts', () async {
      final uploadDir = Directory('${root.path}/upload');
      await uploadDir.create(recursive: true);
      await File('${uploadDir.path}/doc.txt').writeAsString('hello');
      final fontsDir = Directory('${root.path}/fonts');
      await fontsDir.create(recursive: true);
      await File(
        '${fontsDir.path}/custom.ttf',
      ).writeAsBytes(List<int>.filled(64, 9));

      final sync = DataSync(
        preferences: businessPrefs,
        chatService: ChatService(),
      );
      final backupFile = await sync.prepareBackupFile(
        const WebDavConfig(
          content: BackupContentScope(
            chatsAndAssistants: false,
            attachments: true,
            workspaces: true,
            fontsAndAvatars: true,
            settings: true,
            skills: true,
          ),
        ),
        incremental: IncrementalBackupConfig(
          since: DateTime.now().subtract(const Duration(days: 30)),
          includeFiles: true,
        ),
      );

      final input = InputFileStream(backupFile.path);
      Archive? archive;
      try {
        archive = ZipDecoder().decodeStream(input);
        expect(archive.findFile('settings.json'), isNotNull);
        expect(archive.findFile('upload/doc.txt'), isNotNull);
        expect(archive.findFile('fonts/custom.ttf'), isNotNull);
      } finally {
        archive?.clearSync();
        input.closeSync();
      }

      await DataSync.cleanupTemporaryBackupFile(backupFile);
    });

    test('incremental: includeFiles=false excludes files', () async {
      final uploadDir = Directory('${root.path}/upload');
      await uploadDir.create(recursive: true);
      await File('${uploadDir.path}/doc.txt').writeAsString('hello');

      final sync = DataSync(
        preferences: businessPrefs,
        chatService: ChatService(),
      );
      final backupFile = await sync.prepareBackupFile(
        const WebDavConfig(
          content: BackupContentScope(
            chatsAndAssistants: false,
            attachments: true,
            workspaces: true,
            fontsAndAvatars: true,
            settings: true,
            skills: true,
          ),
        ),
        incremental: IncrementalBackupConfig(
          since: DateTime.now().subtract(const Duration(days: 30)),
          includeSettings: false,
          includeFiles: false,
        ),
      );

      final input = InputFileStream(backupFile.path);
      Archive? archive;
      try {
        archive = ZipDecoder().decodeStream(input);
        expect(archive.findFile('settings.json'), isNull);
        expect(archive.findFile('upload/doc.txt'), isNull);
      } finally {
        archive?.clearSync();
        input.closeSync();
      }

      await DataSync.cleanupTemporaryBackupFile(backupFile);
    });

    test(
      'incremental: message-level filtering captures old conversation with new messages',
      () async {
        final chatService = ChatService();
        await chatService.init();

        final oldDate = DateTime.now().subtract(const Duration(days: 60));
        final recentDate = DateTime.now().subtract(const Duration(days: 1));
        final since = DateTime.now().subtract(const Duration(days: 30));

        final conv = Conversation(
          id: 'test-conv-1',
          title: 'Old Conversation',
          createdAt: oldDate,
          updatedAt: recentDate,
          messageIds: ['msg-old', 'msg-recent'],
        );
        final oldMsg = ChatMessage(
          id: 'msg-old',
          role: 'user',
          content: 'old message',
          timestamp: oldDate,
          conversationId: conv.id,
          isStreaming: false,
        );
        final recentMsg = ChatMessage(
          id: 'msg-recent',
          role: 'assistant',
          content: 'recent message',
          timestamp: recentDate,
          conversationId: conv.id,
          isStreaming: false,
        );
        await chatService.restoreConversation(conv, [oldMsg, recentMsg]);

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: chatService,
        );
        final backupFile = await sync.prepareBackupFile(
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: true,
              attachments: false,
              workspaces: false,
              fontsAndAvatars: false,
              settings: true,
              skills: true,
            ),
          ),
          incremental: IncrementalBackupConfig(
            since: since,
            includeSettings: false,
            includeFiles: false,
          ),
        );

        final input = InputFileStream(backupFile.path);
        Archive? archive;
        try {
          archive = ZipDecoder().decodeStream(input);
          final chatsMeta = archive.findFile('chats_meta.json');
          expect(chatsMeta, isNotNull);
          final convs = _readJsonlRecords(
            archive,
            'conversations.jsonl',
            'conversation',
          );
          final msgs = _readJsonlRecords(archive, 'messages.jsonl', 'message');

          expect(convs, hasLength(1));
          expect(convs[0]['id'], 'test-conv-1');
          expect(msgs, hasLength(1));
          expect(msgs[0]['id'], 'msg-recent');
          expect(msgs[0]['toolEvents'], isNull);
        } finally {
          archive?.clearSync();
          input.closeSync();
        }

        await DataSync.cleanupTemporaryBackupFile(backupFile);
        await chatService.close();
      },
    );

    test(
      'incremental: message-level filtering skips old conversation with no new messages',
      () async {
        final chatService = ChatService();
        await chatService.init();

        final oldDate = DateTime.now().subtract(const Duration(days: 60));
        final since = DateTime.now().subtract(const Duration(days: 30));

        final conv = Conversation(
          id: 'test-conv-2',
          title: 'Stale Conversation',
          createdAt: oldDate,
          updatedAt: oldDate,
          messageIds: ['msg-old-only'],
        );
        final oldMsg = ChatMessage(
          id: 'msg-old-only',
          role: 'user',
          content: 'old message',
          timestamp: oldDate,
          conversationId: conv.id,
          isStreaming: false,
        );
        await chatService.restoreConversation(conv, [oldMsg]);

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: chatService,
        );
        final backupFile = await sync.prepareBackupFile(
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: true,
              attachments: false,
              workspaces: false,
              fontsAndAvatars: false,
              settings: true,
              skills: true,
            ),
          ),
          incremental: IncrementalBackupConfig(
            since: since,
            includeSettings: false,
            includeFiles: false,
          ),
        );

        final input = InputFileStream(backupFile.path);
        Archive? archive;
        try {
          archive = ZipDecoder().decodeStream(input);
          expect(archive.findFile('chats_meta.json'), isNotNull);
          final convs = _readJsonlRecords(
            archive,
            'conversations.jsonl',
            'conversation',
          );
          final msgs = _readJsonlRecords(archive, 'messages.jsonl', 'message');

          expect(convs, isEmpty);
          expect(msgs, isEmpty);
        } finally {
          archive?.clearSync();
          input.closeSync();
        }

        await DataSync.cleanupTemporaryBackupFile(backupFile);
        await chatService.close();
      },
    );

    test(
      'incremental: edit-only activity exports the conversation with its full version chain',
      () async {
        final chatService = ChatService();
        await chatService.init();

        final oldDate = DateTime.now().subtract(const Duration(days: 60));
        final since = DateTime.now().subtract(const Duration(days: 30));
        const gid = 'test-group-1';

        final conv = Conversation(
          id: 'test-conv-3',
          title: 'Edited Conversation',
          createdAt: oldDate,
          updatedAt: DateTime.now(),
          messageIds: ['msg-v0', 'msg-v1'],
          versionSelections: {gid: 1},
        );
        final v0 = ChatMessage(
          id: 'msg-v0',
          role: 'assistant',
          content: 'original answer',
          timestamp: oldDate,
          conversationId: conv.id,
          isStreaming: false,
          groupId: gid,
          version: 0,
        );
        final v1 = ChatMessage(
          id: 'msg-v1',
          role: 'assistant',
          content: 'edited answer',
          // Edited versions preserve the ORIGINAL timestamp.
          timestamp: oldDate,
          conversationId: conv.id,
          isStreaming: false,
          groupId: gid,
          version: 1,
        );
        await chatService.restoreConversation(conv, [v0, v1]);

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: chatService,
        );
        final backupFile = await sync.prepareBackupFile(
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: true,
              attachments: false,
              workspaces: false,
              fontsAndAvatars: false,
              settings: true,
              skills: true,
            ),
          ),
          incremental: IncrementalBackupConfig(
            since: since,
            includeSettings: false,
            includeFiles: false,
          ),
        );

        final input = InputFileStream(backupFile.path);
        Archive? archive;
        try {
          archive = ZipDecoder().decodeStream(input);
          expect(archive.findFile('chats_meta.json'), isNotNull);
          final convs = _readJsonlRecords(
            archive,
            'conversations.jsonl',
            'conversation',
          );
          final msgs = _readJsonlRecords(archive, 'messages.jsonl', 'message');

          expect(convs, hasLength(1));
          expect(convs[0]['id'], 'test-conv-3');
          expect((convs[0]['versionSelections'] as Map)[gid], 1);
          expect(msgs, hasLength(2));
          expect(msgs.map((m) => m['id']), containsAll(['msg-v0', 'msg-v1']));
        } finally {
          archive?.clearSync();
          input.closeSync();
        }

        await DataSync.cleanupTemporaryBackupFile(backupFile);
        await chatService.close();
      },
    );

    test(
      'incremental: version groups export atomically when the selected version is the original',
      () async {
        final chatService = ChatService();
        await chatService.init();

        final oldDate = DateTime.now().subtract(const Duration(days: 60));
        final since = DateTime.now().subtract(const Duration(days: 30));
        const gid = 'test-group-2';

        final conv = Conversation(
          id: 'test-conv-4',
          title: 'Reverted Conversation',
          createdAt: oldDate,
          updatedAt: DateTime.now(),
          messageIds: ['msg-rv0', 'msg-rv1'],
          // User edited to v1 but switched the selection back to v0.
          versionSelections: {gid: 0},
        );
        final v0 = ChatMessage(
          id: 'msg-rv0',
          role: 'user',
          content: 'original prompt',
          timestamp: oldDate,
          conversationId: conv.id,
          isStreaming: false,
          groupId: gid,
          version: 0,
        );
        final v1 = ChatMessage(
          id: 'msg-rv1',
          role: 'user',
          content: 'edited prompt',
          timestamp: oldDate,
          conversationId: conv.id,
          isStreaming: false,
          groupId: gid,
          version: 1,
        );
        await chatService.restoreConversation(conv, [v0, v1]);

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: chatService,
        );
        final backupFile = await sync.prepareBackupFile(
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: true,
              attachments: false,
              workspaces: false,
              fontsAndAvatars: false,
              settings: true,
              skills: true,
            ),
          ),
          incremental: IncrementalBackupConfig(
            since: since,
            includeSettings: false,
            includeFiles: false,
          ),
        );

        final input = InputFileStream(backupFile.path);
        Archive? archive;
        try {
          archive = ZipDecoder().decodeStream(input);
          expect(archive.findFile('chats_meta.json'), isNotNull);
          final convs = _readJsonlRecords(
            archive,
            'conversations.jsonl',
            'conversation',
          );
          final msgs = _readJsonlRecords(archive, 'messages.jsonl', 'message');

          expect(convs, hasLength(1));
          expect(msgs, hasLength(2));
          expect(msgs.map((m) => m['id']), containsAll(['msg-rv0', 'msg-rv1']));
        } finally {
          archive?.clearSync();
          input.closeSync();
        }

        await DataSync.cleanupTemporaryBackupFile(backupFile);
        await chatService.close();
      },
    );

    test(
      'incremental: analyzeIncrementalScope returns correct counts',
      () async {
        final chatService = ChatService();
        await chatService.init();

        final since = DateTime.now().subtract(const Duration(days: 30));
        final oldDate = DateTime.now().subtract(const Duration(days: 60));
        final recentDate = DateTime.now().subtract(const Duration(days: 1));

        // New conversation (created after since)
        final newConv = Conversation(
          id: 'new-conv',
          title: 'New Chat',
          createdAt: since.add(const Duration(hours: 1)),
          updatedAt: since.add(const Duration(hours: 1)),
          messageIds: ['msg-n1', 'msg-n2'],
        );
        await chatService.restoreConversation(newConv, [
          ChatMessage(
            id: 'msg-n1',
            role: 'user',
            content: 'hello',
            timestamp: since.add(const Duration(hours: 1)),
            conversationId: newConv.id,
            isStreaming: false,
          ),
          ChatMessage(
            id: 'msg-n2',
            role: 'assistant',
            content: 'hi',
            timestamp: since.add(const Duration(hours: 2)),
            conversationId: newConv.id,
            isStreaming: false,
          ),
        ]);

        // Old conversation with new message
        final oldConv = Conversation(
          id: 'old-conv',
          title: 'Old Chat',
          createdAt: oldDate,
          updatedAt: recentDate,
          messageIds: ['msg-o1', 'msg-o2'],
        );
        await chatService.restoreConversation(oldConv, [
          ChatMessage(
            id: 'msg-o1',
            role: 'user',
            content: 'old msg',
            timestamp: oldDate,
            conversationId: oldConv.id,
            isStreaming: false,
          ),
          ChatMessage(
            id: 'msg-o2',
            role: 'user',
            content: 'recent msg',
            timestamp: recentDate,
            conversationId: oldConv.id,
            isStreaming: false,
          ),
        ]);

        // Stale conversation (no new messages)
        final staleConv = Conversation(
          id: 'stale-conv',
          title: 'Stale Chat',
          createdAt: oldDate,
          updatedAt: oldDate,
          messageIds: ['msg-s1'],
        );
        await chatService.restoreConversation(staleConv, [
          ChatMessage(
            id: 'msg-s1',
            role: 'user',
            content: 'stale',
            timestamp: oldDate,
            conversationId: staleConv.id,
            isStreaming: false,
          ),
        ]);

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: chatService,
        );
        final scope = await sync.analyzeIncrementalScope(
          IncrementalBackupConfig(since: since, includeFiles: false),
        );

        expect(scope.newConversations.count, 1);
        expect(scope.newConversations.messageCount, 2);
        expect(scope.newConversations.oldestTitle, 'New Chat');
        expect(scope.updatedConversations.count, 1);
        expect(scope.updatedConversations.messageCount, 1);
        expect(scope.updatedConversations.oldestTitle, 'Old Chat');
        expect(scope.newFileCount, 0);

        await chatService.close();
      },
    );

    test(
      'incremental: analyzeIncrementalScope counts edit-only activity as whole version groups',
      () async {
        final chatService = ChatService();
        await chatService.init();

        final since = DateTime.now().subtract(const Duration(days: 30));
        final oldDate = DateTime.now().subtract(const Duration(days: 60));
        const gid = 'scope-group-1';

        // Edit-only conversation: all message timestamps predate since, but
        // updatedAt is fresh and a version was appended.
        final conv = Conversation(
          id: 'scope-conv',
          title: 'Edit Only',
          createdAt: oldDate,
          updatedAt: DateTime.now(),
          messageIds: ['scope-v0', 'scope-v1'],
          versionSelections: {gid: 1},
        );
        await chatService.restoreConversation(conv, [
          ChatMessage(
            id: 'scope-v0',
            role: 'assistant',
            content: 'original',
            timestamp: oldDate,
            conversationId: conv.id,
            isStreaming: false,
            groupId: gid,
            version: 0,
          ),
          ChatMessage(
            id: 'scope-v1',
            role: 'assistant',
            content: 'edited',
            timestamp: oldDate,
            conversationId: conv.id,
            isStreaming: false,
            groupId: gid,
            version: 1,
          ),
        ]);

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: chatService,
        );
        final scope = await sync.analyzeIncrementalScope(
          IncrementalBackupConfig(since: since, includeFiles: false),
        );

        expect(scope.newConversations.count, 0);
        expect(scope.updatedConversations.count, 1);
        expect(scope.updatedConversations.oldestTitle, 'Edit Only');
        // Whole version group counts, matching the atomic export.
        expect(scope.updatedConversations.messageCount, 2);

        await chatService.close();
      },
    );
  });

  group('DataSync legacy OCR restore', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kelivo_ocr_restore_');
      PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
      businessPrefs = BusinessPreferences.memoryForTests({});
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    Future<File> makeSettingsZip(Map<String, dynamic> settings) async {
      final settingsFile = File('${root.path}/settings.json');
      await settingsFile.writeAsString(jsonEncode(settings));
      final zipFile = File('${root.path}/backup.zip');
      final encoder = ZipFileEncoder();
      encoder.create(zipFile.path);
      encoder.addFileSync(settingsFile, 'settings.json');
      encoder.closeSync();
      return zipFile;
    }

    test(
      'pre-v15 backup with ocr_enabled_v1=false restores assistants to never '
      'and never resurrects the key',
      () async {
        final chatService = _InMemoryChatService();
        addTearDown(chatService.closeDb);
        final zipFile = await makeSettingsZip({
          'assistants_v1': jsonEncode([
            {'id': 'a1', 'name': 'Legacy A'},
            {'id': 'a2', 'name': 'Legacy B'},
          ]),
          'ocr_enabled_v1': false,
        });

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: chatService,
        );
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: true,
              attachments: false,
              workspaces: false,
              fontsAndAvatars: false,
              settings: true,
              skills: true,
            ),
          ),
          mode: RestoreMode.overwrite,
        );

        final assistants = await chatService.getAllAssistants();
        expect(assistants, hasLength(2));
        expect(assistants.every((a) => a.ocrMode == 'never'), isTrue);

        final prefs = businessPrefs;
        expect(prefs.containsKey('ocr_enabled_v1'), isFalse);
      },
    );

    test(
      'pre-v15 backup with ocr_enabled_v1=true restores assistants to auto',
      () async {
        final chatService = _InMemoryChatService();
        addTearDown(chatService.closeDb);
        final zipFile = await makeSettingsZip({
          'assistants_v1': jsonEncode([
            {'id': 'a1', 'name': 'Legacy A'},
          ]),
          'ocr_enabled_v1': true,
        });

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: chatService,
        );
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: true,
              attachments: false,
              workspaces: false,
              fontsAndAvatars: false,
              settings: true,
              skills: true,
            ),
          ),
          mode: RestoreMode.overwrite,
        );

        final assistants = await chatService.getAllAssistants();
        expect(assistants.single.ocrMode, 'auto');
      },
    );

    test(
      'old backup defaults the proactive-care decision limit to unlimited',
      () async {
        final chatService = _InMemoryChatService();
        addTearDown(chatService.closeDb);
        final zipFile = await makeSettingsZip({
          'assistants_v1': jsonEncode([
            {'id': 'a1', 'name': 'Legacy A'},
          ]),
        });

        await DataSync(
          preferences: businessPrefs,
          chatService: chatService,
        ).restoreFromLocalFile(
          zipFile,
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: true,
              attachments: false,
              workspaces: false,
              fontsAndAvatars: false,
              settings: true,
              skills: true,
            ),
          ),
          mode: RestoreMode.overwrite,
        );

        expect(
          (await chatService.getAllAssistants())
              .single
              .proactiveCareDecisionHistoryMessageLimit,
          isNull,
        );
      },
    );

    test(
      'merge with an old backup preserves the local decision limit',
      () async {
        final chatService = _InMemoryChatService();
        addTearDown(chatService.closeDb);
        await chatService.putAssistants([
          Assistant(
            id: 'a1',
            name: 'Local Alpha',
            proactiveCareDecisionHistoryMessageLimit: 17,
          ),
        ]);
        final zipFile = await makeSettingsZip({
          'assistants_v1': jsonEncode([
            {'id': 'a1', 'name': 'Incoming Alpha'},
          ]),
        });

        await DataSync(
          preferences: businessPrefs,
          chatService: chatService,
        ).restoreFromLocalFile(
          zipFile,
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: true,
              attachments: false,
              workspaces: false,
              fontsAndAvatars: false,
              settings: true,
              skills: true,
            ),
          ),
          mode: RestoreMode.merge,
        );

        expect(
          (await chatService.getAllAssistants())
              .single
              .proactiveCareDecisionHistoryMessageLimit,
          17,
        );
      },
    );

    test('merge restore keeps existing per-assistant ocrMode and maps only new '
        'incoming assistants', () async {
      final chatService = _InMemoryChatService();
      addTearDown(chatService.closeDb);
      await chatService.putAssistants([
        Assistant(id: 'a1', name: 'Local Alpha', ocrMode: 'always'),
      ]);
      final zipFile = await makeSettingsZip({
        'assistants_v1': jsonEncode([
          {'id': 'a1', 'name': 'Incoming Alpha'},
          {'id': 'a2', 'name': 'New Beta'},
        ]),
        'ocr_enabled_v1': false,
      });

      final sync = DataSync(
        preferences: businessPrefs,
        chatService: chatService,
      );
      await sync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(
          content: BackupContentScope(
            chatsAndAssistants: true,
            attachments: false,
            workspaces: false,
            fontsAndAvatars: false,
            settings: true,
            skills: true,
          ),
        ),
        mode: RestoreMode.merge,
      );

      final byId = {
        for (final a in await chatService.getAllAssistants()) a.id: a,
      };
      expect(byId['a1']!.ocrMode, 'always');
      expect(byId['a2']!.ocrMode, 'never');
    });

    test(
      'v15-format backup preserves per-assistant ocrMode untouched',
      () async {
        final chatService = _InMemoryChatService();
        addTearDown(chatService.closeDb);
        final zipFile = await makeSettingsZip({
          'assistants_v1': jsonEncode([
            {'id': 'a1', 'name': 'Modern A', 'ocrMode': 'always'},
            {'id': 'a2', 'name': 'Modern B', 'ocrMode': 'never'},
          ]),
        });

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: chatService,
        );
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: true,
              attachments: false,
              workspaces: false,
              fontsAndAvatars: false,
              settings: true,
              skills: true,
            ),
          ),
          mode: RestoreMode.overwrite,
        );

        final byId = {
          for (final a in await chatService.getAllAssistants()) a.id: a,
        };
        expect(byId['a1']!.ocrMode, 'always');
        expect(byId['a2']!.ocrMode, 'never');
      },
    );

    test(
      'overwrite restore keeps assistants when a later file-copy step fails',
      () async {
        // Real initialized service: the chats restore path self-initializes
        // (restoreConversationsBatch → init), which opens a real SQLite file
        // under the fake app-data dir. Using an in-memory fake here would
        // leave that file handle open and break the teardown delete.
        final chatService = ChatService();
        await chatService.init();
        addTearDown(chatService.close);

        // Occupy root/fonts with a FILE: the files-restore step's
        // Directory.create then throws (EEXIST) mid-restore. The restore
        // must log-and-continue instead of losing the assistants that were
        // already committed before the file copying (issue #475).
        final fontsBlocker = File('${root.path}/fonts');
        await fontsBlocker.writeAsString('blocker');

        final zipFile = File('${root.path}/full-with-files.zip');
        final encoder = ZipFileEncoder();
        encoder.create(zipFile.path);
        final settingsFile = File('${root.path}/settings.json');
        await settingsFile.writeAsString(
          jsonEncode({
            'assistants_v1': jsonEncode([
              {'id': 'a1', 'name': 'Alpha'},
              {'id': 'a2', 'name': 'Beta'},
            ]),
          }),
        );
        encoder.addFileSync(settingsFile, 'settings.json');
        final conv = Conversation(
          id: 'c1',
          title: 'Chat 1',
          createdAt: DateTime(2025, 1, 1),
          updatedAt: DateTime(2025, 1, 2),
          messageIds: const ['m1'],
        );
        final msg = ChatMessage(
          id: 'm1',
          role: 'user',
          content: 'hello',
          conversationId: 'c1',
          timestamp: DateTime(2025, 1, 2),
          isStreaming: false,
        );
        final chatsFile = File('${root.path}/chats.json');
        await chatsFile.writeAsString(
          jsonEncode({
            'version': 2,
            'conversations': [conv.toJson()],
            'messages': [msg.toJson()],
            'toolEvents': <String, dynamic>{},
            'geminiThoughtSigs': <String, dynamic>{},
            'groupChats': <dynamic>[],
            'groupMembers': <dynamic>[],
          }),
        );
        encoder.addFileSync(chatsFile, 'chats.json');
        final fontEntry = File('${root.path}/font.ttf');
        await fontEntry.writeAsBytes(List<int>.filled(64, 7));
        encoder.addFileSync(fontEntry, 'fonts/font.ttf');
        encoder.closeSync();

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: chatService,
        );
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: true,
              attachments: true,
              workspaces: true,
              fontsAndAvatars: true,
              settings: true,
              skills: true,
            ),
          ),
          mode: RestoreMode.overwrite,
        );

        final assistants = await chatService.getAllAssistants();
        expect(assistants, hasLength(2));
        expect(assistants.map((a) => a.id), containsAll(['a1', 'a2']));
        expect(chatService.getAllCompleteConversations(), hasLength(1));
      },
    );

    test(
      'Kelivo v2 backup (manifest.json) throws typed exception before any write',
      () async {
        final chatService = _InMemoryChatService();
        addTearDown(chatService.closeDb);

        final zipFile = File('${root.path}/kelivo-v2.zip');
        final encoder = ZipFileEncoder();
        encoder.create(zipFile.path);
        final manifestFile = File('${root.path}/manifest.json');
        await manifestFile.writeAsString(
          jsonEncode({
            'format': 'kelivo-backup',
            'formatVersion': 2,
            'payloadKind': 'sqlite',
          }),
        );
        encoder.addFileSync(manifestFile, 'manifest.json');
        encoder.closeSync();

        final sync = DataSync(
          preferences: businessPrefs,
          chatService: chatService,
        );
        await expectLater(
          sync.restoreFromLocalFile(
            zipFile,
            const WebDavConfig(
              content: BackupContentScope(
                chatsAndAssistants: true,
                attachments: true,
                workspaces: true,
                fontsAndAvatars: true,
                settings: true,
                skills: true,
              ),
            ),
            mode: RestoreMode.overwrite,
          ),
          throwsA(isA<KelivoV2BackupException>()),
        );

        // No side effects: prefs untouched, DB untouched.
        final prefs = businessPrefs;
        expect(prefs.containsKey('assistants_v1'), isFalse);
        expect(await chatService.getAllAssistants(), isEmpty);
        expect(chatService.getAllCompleteConversations(), isEmpty);
      },
    );
  });

  group('DataSync Kelivo image-settings interop', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kelivo_imgset_');
      PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
      businessPrefs = BusinessPreferences.memoryForTests({});
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    Future<File> makeSettingsZip(Map<String, dynamic> settings) async {
      final settingsFile = File('${root.path}/settings.json');
      await settingsFile.writeAsString(jsonEncode(settings));
      final zipFile = File('${root.path}/backup.zip');
      final encoder = ZipFileEncoder();
      encoder.create(zipFile.path);
      encoder.addFileSync(settingsFile, 'settings.json');
      encoder.closeSync();
      return zipFile;
    }

    test(
      'Kelivo zip overwrite translates upstream keys and strips them from prefs',
      () async {
        final sync = DataSync(
          preferences: businessPrefs,
          chatService: ChatService(),
        );
        final zipFile = await makeSettingsZip({
          'image_upload_quality_v1': 'saver',
          'image_compress_transparent_enabled_v1': true,
        });

        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: false,
              workspaces: false,
              fontsAndAvatars: false,
              settings: true,
              skills: true,
            ),
          ),
          mode: RestoreMode.overwrite,
        );

        final prefs = businessPrefs;
        expect(prefs.getBool('one_click_compress_enabled_v1'), isTrue);
        expect(prefs.getInt('one_click_compress_max_long_edge_v1'), 1024);
        expect(prefs.getInt('one_click_compress_quality_v1'), 70);
        expect(prefs.getBool('one_click_compress_always_jpg_v1'), isTrue);
        expect(prefs.containsKey('image_upload_quality_v1'), isFalse);
        expect(prefs.containsKey('image_compress_custom_quality_v1'), isFalse);
        expect(
          prefs.containsKey('image_compress_transparent_enabled_v1'),
          isFalse,
        );
      },
    );

    test(
      'Kelivo zip overwrite with unknown enum falls back to balanced',
      () async {
        final sync = DataSync(
          preferences: businessPrefs,
          chatService: ChatService(),
        );
        final zipFile = await makeSettingsZip({
          'image_upload_quality_v1': 'future-quality-mode',
        });

        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: false,
              workspaces: false,
              fontsAndAvatars: false,
              settings: true,
              skills: true,
            ),
          ),
          mode: RestoreMode.overwrite,
        );

        final prefs = businessPrefs;
        expect(prefs.getBool('one_click_compress_enabled_v1'), isTrue);
        expect(prefs.getInt('one_click_compress_max_long_edge_v1'), 1568);
        expect(prefs.getInt('one_click_compress_quality_v1'), 85);
      },
    );

    test('Kelivo zip merge keeps existing local one_click_* values', () async {
      businessPrefs = BusinessPreferences.memoryForTests({
        'one_click_compress_enabled_v1': true,
        'one_click_compress_max_long_edge_v1': 2048,
        'one_click_compress_quality_v1': 90,
        'one_click_compress_always_jpg_v1': false,
      });
      final sync = DataSync(
        preferences: businessPrefs,
        chatService: ChatService(),
      );
      final zipFile = await makeSettingsZip({
        'image_upload_quality_v1': 'saver',
      });

      await sync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(
          content: BackupContentScope(
            chatsAndAssistants: false,
            attachments: false,
            workspaces: false,
            fontsAndAvatars: false,
            settings: true,
            skills: true,
          ),
        ),
        mode: RestoreMode.merge,
      );

      final prefs = businessPrefs;
      expect(prefs.getBool('one_click_compress_enabled_v1'), isTrue);
      expect(prefs.getInt('one_click_compress_max_long_edge_v1'), 2048);
      expect(prefs.getInt('one_click_compress_quality_v1'), 90);
      expect(prefs.containsKey('image_upload_quality_v1'), isFalse);
    });

    test(
      'Cuplivo-style zip (both key sets) restores its own long edge verbatim',
      () async {
        // A Cuplivo export carries BOTH key sets. The import must NOT
        // re-translate it: the file's own maxLongEdge (2048) wins over the
        // upstream-pinned 1568.
        final sync = DataSync(
          preferences: businessPrefs,
          chatService: ChatService(),
        );
        final zipFile = await makeSettingsZip({
          'image_upload_quality_v1': 'custom',
          'image_compress_custom_quality_v1': 90,
          'one_click_compress_enabled_v1': true,
          'one_click_compress_max_long_edge_v1': 2048,
          'one_click_compress_quality_v1': 90,
          'one_click_compress_always_jpg_v1': false,
        });

        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: false,
              workspaces: false,
              fontsAndAvatars: false,
              settings: true,
              skills: true,
            ),
          ),
          mode: RestoreMode.overwrite,
        );

        final prefs = businessPrefs;
        expect(prefs.getInt('one_click_compress_max_long_edge_v1'), 2048);
        expect(prefs.getInt('one_click_compress_quality_v1'), 90);
        expect(prefs.containsKey('image_upload_quality_v1'), isFalse);
      },
    );

    test(
      'export derives upstream keys from current one_click_* values',
      () async {
        businessPrefs = BusinessPreferences.memoryForTests({
          'one_click_compress_enabled_v1': true,
          'one_click_compress_max_long_edge_v1': 1536,
          'one_click_compress_quality_v1': 75,
          'one_click_compress_always_jpg_v1': false,
        });
        final sync = DataSync(
          preferences: businessPrefs,
          chatService: ChatService(),
        );
        final backupFile = await sync.prepareBackupFile(
          WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: false,
              workspaces: false,
              fontsAndAvatars: false,
              settings: true,
              skills: true,
            ),
          ),
        );

        final input = InputFileStream(backupFile.path);
        Archive? archive;
        try {
          archive = ZipDecoder().decodeStream(input);
          final settingsEntry = archive.findFile('settings.json');
          expect(settingsEntry, isNotNull);
          final settings =
              jsonDecode(utf8.decode(settingsEntry!.readBytes()!))
                  as Map<String, dynamic>;
          expect(settings['image_upload_quality_v1'], 'custom');
          expect(settings['image_compress_custom_quality_v1'], 75);
          expect(settings['image_compress_transparent_enabled_v1'], false);
        } finally {
          archive?.clearSync();
          input.closeSync();
        }

        await DataSync.cleanupTemporaryBackupFile(backupFile);
      },
    );

    test('export of a disabled config emits original', () async {
      businessPrefs = BusinessPreferences.memoryForTests({
        'one_click_compress_enabled_v1': false,
        'one_click_compress_quality_v1': 95,
      });
      final sync = DataSync(
        preferences: businessPrefs,
        chatService: ChatService(),
      );
      final backupFile = await sync.prepareBackupFile(
        WebDavConfig(
          content: BackupContentScope(
            chatsAndAssistants: false,
            attachments: false,
            workspaces: false,
            fontsAndAvatars: false,
            settings: true,
            skills: true,
          ),
        ),
      );

      final input = InputFileStream(backupFile.path);
      Archive? archive;
      try {
        archive = ZipDecoder().decodeStream(input);
        final settings =
            jsonDecode(
                  utf8.decode(archive.findFile('settings.json')!.readBytes()!),
                )
                as Map<String, dynamic>;
        expect(settings['image_upload_quality_v1'], 'original');
      } finally {
        archive?.clearSync();
        input.closeSync();
      }

      await DataSync.cleanupTemporaryBackupFile(backupFile);
    });

    test(
      'export converts search_services_v1 apiKeys to Kelivo string list',
      () async {
        businessPrefs = BusinessPreferences.memoryForTests({
          'search_services_v1': jsonEncode([
            {
              'type': 'tavily',
              'id': 'tavily-1',
              'url': 'https://api.tavily.com/search',
              'apiKey': 'primary-key',
              'apiKeys': [
                {
                  'id': 'k1',
                  'key': 'primary-key',
                  'isEnabled': true,
                  'priority': 5,
                },
                {
                  'id': 'k2',
                  'key': 'backup-key',
                  'isEnabled': true,
                  'priority': 6,
                },
              ],
            },
          ]),
        });
        final sync = DataSync(
          preferences: businessPrefs,
          chatService: ChatService(),
        );
        final backupFile = await sync.prepareBackupFile(
          WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: false,
              workspaces: false,
              fontsAndAvatars: false,
              settings: true,
              skills: true,
            ),
          ),
        );

        final input = InputFileStream(backupFile.path);
        Archive? archive;
        try {
          archive = ZipDecoder().decodeStream(input);
          final settings =
              jsonDecode(
                    utf8.decode(
                      archive.findFile('settings.json')!.readBytes()!,
                    ),
                  )
                  as Map<String, dynamic>;
          final services =
              jsonDecode(settings['search_services_v1'] as String) as List;
          final service = services.single as Map<String, dynamic>;
          expect(service['type'], 'tavily');
          expect(service['apiKey'], 'primary-key');
          expect(service['apiKeys'], ['primary-key', 'backup-key']);
          expect(service['keyConfigs'], isA<List>());
          expect(service['keyConfigs'], hasLength(2));
        } finally {
          archive?.clearSync();
          input.closeSync();
        }

        await DataSync.cleanupTemporaryBackupFile(backupFile);
      },
    );

    test('round-trip restores full keyConfigs for search services', () async {
      businessPrefs = BusinessPreferences.memoryForTests({
        'search_services_v1': jsonEncode([
          {
            'type': 'tavily',
            'id': 'tavily-1',
            'url': 'https://api.tavily.com/search',
            'apiKey': 'primary-key',
            'apiKeys': [
              {
                'id': 'k1',
                'key': 'primary-key',
                'isEnabled': true,
                'priority': 5,
              },
              {
                'id': 'k2',
                'key': 'backup-key',
                'isEnabled': true,
                'priority': 6,
              },
            ],
          },
        ]),
      });
      final sync = DataSync(
        preferences: businessPrefs,
        chatService: ChatService(),
      );
      final backupFile = await sync.prepareBackupFile(
        WebDavConfig(
          content: BackupContentScope(
            chatsAndAssistants: false,
            attachments: false,
            workspaces: false,
            fontsAndAvatars: false,
            settings: true,
            skills: true,
          ),
        ),
      );

      final input = InputFileStream(backupFile.path);
      Archive? archive;
      try {
        archive = ZipDecoder().decodeStream(input);
        final settings =
            jsonDecode(
                  utf8.decode(archive.findFile('settings.json')!.readBytes()!),
                )
                as Map<String, dynamic>;
        final services =
            jsonDecode(settings['search_services_v1'] as String) as List;
        final service = services.single as Map<String, dynamic>;

        final restored = SearchServiceOptions.fromJson(service);
        expect(restored.apiKeys, hasLength(2));
        expect(restored.apiKeys.first.key, 'primary-key');
        expect(restored.apiKeys.last.key, 'backup-key');
        expect(restored.apiKeys.last.isEnabled, isTrue);
      } finally {
        archive?.clearSync();
        input.closeSync();
      }

      await DataSync.cleanupTemporaryBackupFile(backupFile);
    });

    test(
      'export splits apiKeys to Kelivo string list for all new providers',
      () async {
        businessPrefs = BusinessPreferences.memoryForTests({
          'search_services_v1': jsonEncode([
            {
              'type': 'doubao',
              'id': 'doubao-1',
              'apiKey': 'primary-key',
              'apiKeys': [
                {'id': 'k1', 'key': 'primary-key', 'isEnabled': true},
                {'id': 'k2', 'key': 'backup-key', 'isEnabled': true},
              ],
            },
            {
              'type': 'stepfun',
              'id': 'stepfun-1',
              'url': '',
              'category': 'research',
              'apiKey': 'sf-key',
              'apiKeys': [
                {'id': 'k1', 'key': 'sf-key', 'isEnabled': true},
                {'id': 'k2', 'key': 'sf-extra', 'isEnabled': true},
              ],
            },
            {
              'type': 'firecrawl',
              'id': 'firecrawl-1',
              'url': '',
              'apiKey': '',
              'apiKeys': [
                {'id': 'k1', 'key': 'fc-key', 'isEnabled': true},
              ],
            },
            {
              'type': 'tinyfish',
              'id': 'tinyfish-1',
              'url': '',
              'apiKey': 'tf-key',
              'apiKeys': [
                {'id': 'k1', 'key': 'tf-key', 'isEnabled': true},
              ],
            },
          ]),
        });
        final sync = DataSync(
          preferences: businessPrefs,
          chatService: ChatService(),
        );
        final backupFile = await sync.prepareBackupFile(
          WebDavConfig(
            content: BackupContentScope(
              chatsAndAssistants: false,
              attachments: false,
              workspaces: false,
              fontsAndAvatars: false,
              settings: true,
              skills: true,
            ),
          ),
        );

        final input = InputFileStream(backupFile.path);
        Archive? archive;
        try {
          archive = ZipDecoder().decodeStream(input);
          final settings =
              jsonDecode(
                    utf8.decode(
                      archive.findFile('settings.json')!.readBytes()!,
                    ),
                  )
                  as Map<String, dynamic>;
          final services =
              jsonDecode(settings['search_services_v1'] as String) as List;
          final byType = <String, Map<String, dynamic>>{
            for (final e in services)
              (e as Map<String, dynamic>)['type'] as String: e,
          };
          final doubao = byType['doubao']!;
          expect(doubao['apiKeys'], ['primary-key', 'backup-key']);
          expect(doubao['keyConfigs'], hasLength(2));

          final stepfun = byType['stepfun']!;
          expect(stepfun['apiKeys'], ['sf-key', 'sf-extra']);
          expect(stepfun['keyConfigs'], hasLength(2));

          final firecrawl = byType['firecrawl']!;
          expect(firecrawl['apiKeys'], ['fc-key']);
          expect(firecrawl['keyConfigs'], hasLength(1));

          final tinyfish = byType['tinyfish']!;
          expect(tinyfish['apiKeys'], ['tf-key']);
          expect(tinyfish['keyConfigs'], hasLength(1));
        } finally {
          archive?.clearSync();
          input.closeSync();
        }

        await DataSync.cleanupTemporaryBackupFile(backupFile);
      },
    );

    test('round-trip restores all new provider types from backup', () async {
      businessPrefs = BusinessPreferences.memoryForTests({
        'search_services_v1': jsonEncode([
          {
            'type': 'doubao',
            'id': 'doubao-1',
            'apiKey': 'primary-key',
            'apiKeys': ['primary-key', 'backup-key'],
          },
          {
            'type': 'stepfun',
            'id': 'stepfun-1',
            'url': 'https://api.stepfun.com/v1/search',
            'category': 'research',
            'apiKey': 'sf-key',
            'apiKeys': ['sf-key', 'sf-extra'],
          },
          {
            'type': 'firecrawl',
            'id': 'firecrawl-1',
            'url': '',
            'apiKey': 'fc-key',
            'apiKeys': ['fc-key'],
          },
          {
            'type': 'tinyfish',
            'id': 'tinyfish-1',
            'url': '',
            'apiKey': 'tf-key',
            'apiKeys': ['tf-key'],
          },
        ]),
      });
      final sync = DataSync(
        preferences: businessPrefs,
        chatService: ChatService(),
      );
      final backupFile = await sync.prepareBackupFile(
        WebDavConfig(
          content: BackupContentScope(
            chatsAndAssistants: false,
            attachments: false,
            workspaces: false,
            fontsAndAvatars: false,
            settings: true,
            skills: true,
          ),
        ),
      );

      final input = InputFileStream(backupFile.path);
      Archive? archive;
      try {
        archive = ZipDecoder().decodeStream(input);
        final settings =
            jsonDecode(
                  utf8.decode(archive.findFile('settings.json')!.readBytes()!),
                )
                as Map<String, dynamic>;
        final services =
            jsonDecode(settings['search_services_v1'] as String) as List;
        final restored = services
            .map(
              (e) => SearchServiceOptions.fromJson(e as Map<String, dynamic>),
            )
            .toList();

        expect(restored, hasLength(4));
        expect(restored[0], isA<DoubaoOptions>());
        expect(restored[0].apiKeys.map((k) => k.key), [
          'primary-key',
          'backup-key',
        ]);
        expect(restored[1], isA<StepFunOptions>());
        expect((restored[1] as StepFunOptions).category, 'research');
        expect(restored[1].apiKeys.map((k) => k.key), ['sf-key', 'sf-extra']);
        expect(restored[2], isA<FirecrawlOptions>());
        expect(restored[2].apiKeys.map((k) => k.key), ['fc-key']);
        expect(restored[3], isA<TinyFishOptions>());
        expect(restored[3].apiKeys.map((k) => k.key), ['tf-key']);
      } finally {
        archive?.clearSync();
        input.closeSync();
      }

      await DataSync.cleanupTemporaryBackupFile(backupFile);
    });
  });
}

/// Reads {table}'s JSONL records (v2 backup format) from [archive],
/// returning the wrapped-object payloads (the `{key}` field of each line).
List<Map<String, dynamic>> _readJsonlRecords(
  Archive archive,
  String table,
  String key,
) {
  final entry = archive.findFile(table);
  expect(entry, isNotNull);
  final lines = utf8.decode(entry!.readBytes() ?? <int>[]).split('\n');
  final records = <Map<String, dynamic>>[];
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final obj = jsonDecode(trimmed) as Map<String, dynamic>;
    final payload = obj[key] as Map?;
    if (payload != null) {
      records.add(payload.cast<String, dynamic>());
    }
  }
  return records;
}
