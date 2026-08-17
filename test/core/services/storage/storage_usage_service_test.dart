import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path/path.dart' as p;

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/services/storage/storage_usage_service.dart';

const MethodChannel _iosTmpChannel = MethodChannel('app.ios_tmp_directory');

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async =>
      p.join(path, 'documents');

  @override
  Future<String?> getApplicationSupportPath() async =>
      p.join(path, 'documents');

  @override
  Future<String?> getApplicationCachePath() async => p.join(path, 'cache');
}

Future<void> _writeSizedFile(Directory root, String name, int size) async {
  final file = File(p.join(root.path, name));
  await file.writeAsBytes(List<int>.filled(size, 1), flush: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Directory appDataDir;
  late PathProviderPlatform previousPathProvider;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'kelivo_storage_usage_test_',
    );
    // Mirrors the real container layout: app data and cache are sibling
    // directories, never nested inside each other.
    appDataDir = Directory(p.join(tempDir.path, 'documents'));
    await appDataDir.create(recursive: true);
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
  });

  tearDown(() async {
    PathProviderPlatform.instance = previousPathProvider;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_iosTmpChannel, null);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  void mockIosTmpPath(String? path) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _iosTmpChannel,
          path == null
              ? null
              : (call) async {
                  if (call.method != 'getPath') {
                    throw MissingPluginException();
                  }
                  return path;
                },
        );
  }

  test(
    'chat records size uses SQLite files instead of legacy Hive files',
    () async {
      await _writeSizedFile(appDataDir, AppDatabase.databaseFileName, 11);
      await _writeSizedFile(
        appDataDir,
        '${AppDatabase.databaseFileName}-wal',
        7,
      );
      await _writeSizedFile(
        appDataDir,
        '${AppDatabase.databaseFileName}-shm',
        5,
      );
      await _writeSizedFile(appDataDir, 'conversations.hive', 100);
      await _writeSizedFile(appDataDir, 'messages.hive', 200);
      await _writeSizedFile(appDataDir, 'tool_events_v1.hive', 300);
      await _writeSizedFile(appDataDir, 'messages.lock', 400);

      final report = await StorageUsageService.computeReport();
      final chat = report.categories.singleWhere(
        (category) => category.key == StorageUsageCategoryKey.chatData,
      );

      expect(chat.stats.bytes, 23);
      expect(chat.stats.fileCount, 3);
      expect(
        chat.subcategories.map((subcategory) => subcategory.id),
        containsAllInOrder(['sqlite_database', 'sqlite_wal', 'sqlite_shm']),
      );
      expect(
        chat.subcategories.map((subcategory) => p.basename(subcategory.path!)),
        containsAllInOrder([
          AppDatabase.databaseFileName,
          '${AppDatabase.databaseFileName}-wal',
          '${AppDatabase.databaseFileName}-shm',
        ]),
      );
      expect(report.totalBytes, 1023);
    },
  );

  test(
    'chat records size works when only the main SQLite database exists',
    () async {
      await _writeSizedFile(appDataDir, AppDatabase.databaseFileName, 19);

      final report = await StorageUsageService.computeReport();
      final chat = report.categories.singleWhere(
        (category) => category.key == StorageUsageCategoryKey.chatData,
      );

      expect(chat.stats.bytes, 19);
      expect(chat.stats.fileCount, 1);
      expect(chat.subcategories.single.id, 'sqlite_database');
      expect(
        p.basename(chat.subcategories.single.path!),
        AppDatabase.databaseFileName,
      );
    },
  );

  test('workspace files are counted in a dedicated category', () async {
    final workspaceDir = Directory(p.join(appDataDir.path, 'workspaces', 'default'));
    await workspaceDir.create(recursive: true);
    await _writeSizedFile(workspaceDir, 'main.dart', 70);
    await _writeSizedFile(workspaceDir, 'README.md', 30);

    final report = await StorageUsageService.computeReport();
    final workspace = report.categories.singleWhere(
      (category) => category.key == StorageUsageCategoryKey.workspace,
    );

    expect(workspace.stats.bytes, 100);
    expect(workspace.stats.fileCount, 2);
    final files = workspace.subcategories.singleWhere(
      (subcategory) => subcategory.id == 'files',
    );
    expect(files.stats.bytes, 100);
    expect(report.totalBytes, 100);
  });

  test(
    'iOS tmp directory is counted under cache when the channel resolves',
    () async {
      final tmp = Directory(p.join(tempDir.path, 'tmp'));
      await tmp.create(recursive: true);
      await _writeSizedFile(tmp, 'pasted_123.png', 40);
      await _writeSizedFile(tmp, 'picker_copy.pdf', 60);
      mockIosTmpPath(tmp.path);

      final report = await StorageUsageService.computeReport();
      final cache = report.categories.singleWhere(
        (category) => category.key == StorageUsageCategoryKey.cache,
      );

      expect(cache.stats.bytes, 100);
      final tmpSub = cache.subcategories.singleWhere(
        (subcategory) => subcategory.id == 'tmp_cache',
      );
      expect(tmpSub.stats.bytes, 100);
      expect(tmpSub.stats.fileCount, 2);
      expect(tmpSub.path, tmp.path);
      expect(report.totalBytes, 100);
    },
  );

  test(
    'tmp directory is not counted when the channel is unavailable',
    () async {
      // No mock handler: the channel does not exist (equivalent to non-iOS).
      final tmp = Directory(p.join(tempDir.path, 'tmp'));
      await tmp.create(recursive: true);
      await _writeSizedFile(tmp, 'pasted_123.png', 50);

      final report = await StorageUsageService.computeReport();
      final cache = report.categories.singleWhere(
        (category) => category.key == StorageUsageCategoryKey.cache,
      );

      expect(cache.stats.bytes, 0);
      expect(cache.subcategories.where((s) => s.id == 'tmp_cache'), isEmpty);
      expect(report.totalBytes, 0);
    },
  );

  test('clearTmpCache empties tmp contents but keeps the directory', () async {
    final tmp = Directory(p.join(tempDir.path, 'tmp'));
    await tmp.create(recursive: true);
    await _writeSizedFile(tmp, 'pasted_1.png', 10);
    await _writeSizedFile(tmp, 'picker_copy.bin', 20);
    mockIosTmpPath(tmp.path);

    await StorageUsageService.clearTmpCache();

    expect(await tmp.exists(), isTrue);
    expect(await tmp.list().toList(), isEmpty);
  });

  test('clearTmpCache is a no-op when the channel is unavailable', () async {
    final tmp = Directory(p.join(tempDir.path, 'tmp'));
    await tmp.create(recursive: true);
    await _writeSizedFile(tmp, 'pasted_1.png', 10);

    await StorageUsageService.clearTmpCache();

    expect(await tmp.list().toList(), hasLength(1));
  });
}
