import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/business_restore_service.dart';
import 'package:Cuplivo/core/models/backup.dart';
import 'package:Cuplivo/core/services/backup/data_sync.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:Cuplivo/core/services/sync/sync_store.dart';

/// The pair whose checkpoint a bulk replacement invalidates. Named rather than
/// inlined because every assertion below is about *this* peer's entry surviving
/// or not surviving.
const _peerId = 'peer-verified';

/// A settings-only scope: no chats, so the archive carries settings and
/// business rows and nothing else.
const _settingsOnly = BackupScope(
  excluded: {
    BackupCategory.chats,
    BackupCategory.files,
    BackupCategory.skills,
    BackupCategory.workspaces,
  },
);

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

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

/// Seeds what a paired device leaves on disk: an epoch and one peer's
/// checkpoint entry describing a row both sides had agreed on.
Future<SyncStore> _seedPairedState(Directory root) async {
  final store = SyncStore(Directory('${root.path}/sync'));
  await store.writeDataEpoch(3);
  await store.saveCheckpoint(
    _peerId,
    SyncCheckpoint({
      'conversation-1': SyncCheckpointConversation(
        updatedAtUs: 111,
        digest: 'digest-1',
        rows: const {'row-1': 1},
      ),
    }),
  );
  return store;
}

/// The announcement a bulk replacement owes the pair: the epoch moves, and the
/// checkpoints that described the replaced history are gone.
///
/// The checkpoint half is the load-bearing one. A surviving entry says "the peer
/// held this row when we agreed", so a row the archive did not carry reads as a
/// deletion here and the peer is told to delete its own copy — the destructive
/// direction this whole mechanism exists to prevent.
Future<void> _expectReplacementAnnounced(SyncStore store) async {
  expect(
    await store.readDataEpoch(),
    4,
    reason: 'a bulk replacement must move the epoch so the peer re-converges',
  );
  expect(
    (await store.loadCheckpoint(_peerId)).conversations,
    isEmpty,
    reason: 'checkpoint entries describe a history this device no longer holds',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a bulk business replacement announces its sync epoch', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kelivo_sync_epoch_');
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      PackageInfo.setMockInitialValues(
        appName: 'Cuplivo',
        packageName: 'Cuplivo',
        version: '1.0.0-test',
        buildNumber: '1',
        buildSignature: 'test',
      );
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    /// A prepared versioned backup carrying settings only, built the way the
    /// app builds one.
    Future<File> prepareSettingsOnlyBackup() async {
      final database = AppDatabase.open(
        file: File('${root.path}/source.sqlite'),
      );
      try {
        final repository = BusinessRepository(database);
        await BusinessRestoreService(
          repository,
        ).overwrite({'restored_setting_v1': 'from-backup'});
        return await DataSync(
          chatService: ChatService(),
          businessRepository: repository,
        ).prepareBackupFile(const WebDavConfig(scope: _settingsOnly));
      } finally {
        await database.close();
      }
    }

    /// The archive without a manifest: the legacy shape, which reaches the same
    /// replacement through a different branch.
    Future<File> prepareLegacySettingsOnlyBackup() async {
      final database = AppDatabase.open(
        file: File('${root.path}/legacy-source.sqlite'),
      );
      try {
        final repository = BusinessRepository(database);
        final restore = BusinessRestoreService(repository);
        await restore.overwrite({'restored_setting_v1': 'from-legacy'});
        final settings = await restore.exportSettings();
        final settingsFile = File('${root.path}/legacy_settings.json');
        await settingsFile.writeAsString(jsonEncode(settings));
        final zipFile = File('${root.path}/legacy_settings_only.zip');
        final encoder = ZipFileEncoder();
        encoder.create(zipFile.path);
        encoder.addFileSync(settingsFile, 'settings.json');
        encoder.closeSync();
        return zipFile;
      } finally {
        await database.close();
      }
    }

    BusinessRepository openTarget() {
      final database = AppDatabase.open(
        file: File('${root.path}/target.sqlite'),
      );
      addTearDown(database.close);
      return BusinessRepository(database);
    }

    test(
      'a settings-only overwrite announces the epoch and drops the checkpoints',
      () async {
        final backup = await prepareSettingsOnlyBackup();
        addTearDown(() => DataSync.cleanupTemporaryBackupFile(backup));
        final repository = openTarget();
        final store = await _seedPairedState(root);

        await DataSync(
          chatService: ChatService(),
          businessRepository: repository,
        ).restoreFromLocalFile(
          backup,
          const WebDavConfig(scope: _settingsOnly),
        );

        await _expectReplacementAnnounced(store);
      },
    );

    test('a legacy settings-only overwrite announces the epoch too', () async {
      final backup = await prepareLegacySettingsOnlyBackup();
      final repository = openTarget();
      final store = await _seedPairedState(root);

      await DataSync(
        chatService: ChatService(),
        businessRepository: repository,
      ).restoreFromLocalFile(backup, const WebDavConfig(scope: _settingsOnly));

      await _expectReplacementAnnounced(store);
    });

    test('a settings-only merge announces nothing', () async {
      final backup = await prepareSettingsOnlyBackup();
      addTearDown(() => DataSync.cleanupTemporaryBackupFile(backup));
      final repository = openTarget();
      final store = await _seedPairedState(root);

      await DataSync(
        chatService: ChatService(),
        businessRepository: repository,
      ).restoreFromLocalFile(
        backup,
        const WebDavConfig(scope: _settingsOnly),
        mode: RestoreMode.merge,
      );

      // A merge adds to what is here; it replaces no history, so the pair's
      // bookkeeping still describes the same rows and must not be thrown away.
      expect(await store.readDataEpoch(), 3);
      expect(
        (await store.loadCheckpoint(_peerId)).conversations,
        contains('conversation-1'),
      );
    });
  });
}
