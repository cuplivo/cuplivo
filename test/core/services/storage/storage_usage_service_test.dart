import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/services/storage/storage_usage_service.dart';
import 'package:Cuplivo/core/services/workspace/workspace_terminal_native_bridge.dart';

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

  test(
    'workspace user files and .sandbox are split into separate categories',
    () async {
      final wsDir = Directory(p.join(appDataDir.path, 'workspaces', 'default'));
      await Directory(p.join(wsDir.path, 'docs')).create(recursive: true);
      await Directory(
        p.join(wsDir.path, '.sandbox', 'linux', 'bin'),
      ).create(recursive: true);
      await _writeSizedFile(wsDir, 'notes.txt', 50);
      await _writeSizedFile(
        Directory(p.join(wsDir.path, 'docs')),
        'plan.md',
        30,
      );
      await _writeSizedFile(
        Directory(p.join(wsDir.path, '.sandbox', 'linux', 'bin')),
        'sh',
        100,
      );
      await _writeSizedFile(
        Directory(p.join(wsDir.path, '.sandbox')),
        'download.tar.gz',
        200,
      );

      final report = await StorageUsageService.computeReport();
      final ws = report.categories.singleWhere(
        (category) => category.key == StorageUsageCategoryKey.workspaces,
      );
      final sandbox = report.categories.singleWhere(
        (category) => category.key == StorageUsageCategoryKey.sandbox,
      );

      expect(ws.stats.bytes, 80);
      expect(ws.stats.fileCount, 2);
      expect(sandbox.stats.bytes, 300);
      expect(
        sandbox.subcategories
            .singleWhere((subcategory) => subcategory.id == 'sandbox_per_ws')
            .stats
            .bytes,
        300,
      );
      expect(
        sandbox.subcategories.where(
          (subcategory) => subcategory.id == 'sandbox_shared_runtime',
        ),
        isEmpty,
      );
      expect(report.totalBytes, 380);
    },
  );

  test('skills and fonts are counted in their own categories', () async {
    await Directory(p.join(appDataDir.path, 'skills')).create(recursive: true);
    await Directory(p.join(appDataDir.path, 'fonts')).create(recursive: true);
    await _writeSizedFile(
      Directory(p.join(appDataDir.path, 'skills')),
      'skill.md',
      10,
    );
    await _writeSizedFile(
      Directory(p.join(appDataDir.path, 'fonts')),
      'custom.ttf',
      20,
    );

    final report = await StorageUsageService.computeReport();

    expect(
      report.categories
          .singleWhere(
            (category) => category.key == StorageUsageCategoryKey.skills,
          )
          .stats
          .bytes,
      10,
    );
    expect(
      report.categories
          .singleWhere(
            (category) => category.key == StorageUsageCategoryKey.fonts,
          )
          .stats
          .bytes,
      20,
    );
  });

  test(
    'relocated workspaces root outside app data is counted without double-count',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final custom = Directory(p.join(tempDir.path, 'custom-ws'));
      await Directory(
        p.join(custom.path, 'default', '.sandbox', 'linux', 'bin'),
      ).create(recursive: true);
      await _writeSizedFile(
        Directory(p.join(custom.path, 'default')),
        'notes.txt',
        50,
      );
      await _writeSizedFile(
        Directory(p.join(custom.path, 'default', '.sandbox', 'linux', 'bin')),
        'sh',
        100,
      );
      SharedPreferences.setMockInitialValues({
        'workspaces_dir_v1': custom.path,
      });

      final report = await StorageUsageService.computeReport();
      final ws = report.categories.singleWhere(
        (category) => category.key == StorageUsageCategoryKey.workspaces,
      );
      final sandbox = report.categories.singleWhere(
        (category) => category.key == StorageUsageCategoryKey.sandbox,
      );

      expect(ws.stats.bytes, 50);
      expect(sandbox.stats.bytes, 100);
      expect(report.totalBytes, 150);
    },
  );

  test(
    'clearSandbox removes per-workspace .sandbox and shared runtime',
    () async {
      final wsDir = Directory(p.join(appDataDir.path, 'workspaces', 'default'));
      final sandboxDir = Directory(
        p.join(wsDir.path, '.sandbox', 'linux', 'bin'),
      );
      await sandboxDir.create(recursive: true);
      await _writeSizedFile(sandboxDir, 'sh', 10);
      final runtime = Directory(p.join(appDataDir.path, 'linux-sandbox'));
      await runtime.create(recursive: true);
      await _writeSizedFile(runtime, 'meta.db', 5);

      await StorageUsageService.clearSandbox(workspaceHostPaths: [wsDir.path]);

      expect(await Directory(p.join(wsDir.path, '.sandbox')).exists(), isFalse);
      expect(await runtime.exists(), isFalse);
    },
  );

  test('clearSandbox keeps workspace user files', () async {
    final wsDir = Directory(p.join(appDataDir.path, 'workspaces', 'default'));
    await wsDir.create(recursive: true);
    await _writeSizedFile(wsDir, 'notes.txt', 50);

    await StorageUsageService.clearSandbox(workspaceHostPaths: [wsDir.path]);

    expect(await File(p.join(wsDir.path, 'notes.txt')).exists(), isTrue);
  });

  test(
    'clearSandbox does not delete anything when terminal stop fails',
    () async {
      final wsDir = Directory(p.join(appDataDir.path, 'workspaces', 'default'));
      final sandboxDir = Directory(p.join(wsDir.path, '.sandbox', 'linux'));
      await sandboxDir.create(recursive: true);
      await _writeSizedFile(sandboxDir, 'marker', 1);

      await expectLater(
        StorageUsageService.clearSandbox(
          workspaceHostPaths: <String>[wsDir.path],
          stopTerminals: () async => throw StateError('stop failed'),
        ),
        throwsA(isA<WorkspaceTerminalStopException>()),
      );

      expect(await Directory(p.join(wsDir.path, '.sandbox')).exists(), isTrue);
    },
  );

  test(
    'customHostPath workspaces are scanned and split into categories',
    () async {
      final custom = Directory(p.join(tempDir.path, 'custom-host-ws'));
      await Directory(
        p.join(custom.path, '.sandbox', 'linux', 'bin'),
      ).create(recursive: true);
      await _writeSizedFile(custom, 'notes.txt', 50);
      await _writeSizedFile(
        Directory(p.join(custom.path, '.sandbox', 'linux', 'bin')),
        'sh',
        100,
      );

      final report = await StorageUsageService.computeReport(
        workspaceHostPaths: [custom.path],
      );
      final ws = report.categories.singleWhere(
        (category) => category.key == StorageUsageCategoryKey.workspaces,
      );
      final sandbox = report.categories.singleWhere(
        (category) => category.key == StorageUsageCategoryKey.sandbox,
      );

      expect(ws.stats.bytes, 50);
      expect(sandbox.stats.bytes, 100);
      expect(report.totalBytes, 150);
    },
  );

  test(
    'customHostPath inside an already-scanned root is not double-counted',
    () async {
      await _writeSizedFile(appDataDir, 'notes.txt', 10);
      await Directory(
        p.join(appDataDir.path, 'workspaces'),
      ).create(recursive: true);
      await _writeSizedFile(
        Directory(p.join(appDataDir.path, 'workspaces')),
        'doc.txt',
        20,
      );

      final report = await StorageUsageService.computeReport(
        workspaceHostPaths: [appDataDir.path],
      );

      expect(report.totalBytes, 30);
      expect(report.totalFiles, 2);
    },
  );

  test(
    'onProgress reports running totals and finishes at the report total',
    () async {
      await _writeSizedFile(appDataDir, 'notes.txt', 10);
      await Directory(
        p.join(appDataDir.path, 'workspaces', 'default', '.sandbox'),
      ).create(recursive: true);
      await _writeSizedFile(
        Directory(p.join(appDataDir.path, 'workspaces', 'default')),
        'doc.txt',
        20,
      );
      await _writeSizedFile(
        Directory(p.join(appDataDir.path, 'workspaces', 'default', '.sandbox')),
        'download.tar.gz',
        70,
      );

      final emissions = <({int files, int bytes})>[];
      final report = await StorageUsageService.computeReport(
        onProgress: (files, bytes) =>
            emissions.add((files: files, bytes: bytes)),
      );

      expect(emissions, isNotEmpty);
      expect(emissions.last.files, report.totalFiles);
      expect(emissions.last.bytes, report.totalBytes);
      expect(emissions.last.files, 3);
      expect(emissions.last.bytes, 100);
    },
  );

  test('clearable includes sandbox alongside cache and logs', () async {
    final wsDir = Directory(p.join(appDataDir.path, 'workspaces', 'default'));
    await Directory(
      p.join(wsDir.path, '.sandbox', 'linux', 'bin'),
    ).create(recursive: true);
    await _writeSizedFile(
      Directory(p.join(wsDir.path, '.sandbox', 'linux', 'bin')),
      'sh',
      300,
    );
    await Directory(p.join(appDataDir.path, 'logs')).create(recursive: true);
    await _writeSizedFile(
      Directory(p.join(appDataDir.path, 'logs')),
      'flutter_logs.txt',
      100,
    );

    final report = await StorageUsageService.computeReport();

    expect(report.clearable.bytes, 400);
    expect(report.clearable.fileCount, 2);
  });

  test(
    'unreadable subdirectory does not zero the rest of the scan',
    () async {
      await _writeSizedFile(appDataDir, AppDatabase.databaseFileName, 11);
      await _writeSizedFile(appDataDir, 'notes.txt', 10);

      final blocked = Directory(
        p.join(appDataDir.path, 'workspaces', 'default', '.sandbox'),
      );
      await Directory(
        p.join(blocked.path, 'linux', 'bin'),
      ).create(recursive: true);
      await _writeSizedFile(
        Directory(p.join(blocked.path, 'linux', 'bin')),
        'sh',
        100,
      );
      final chmod = await Process.run('chmod', ['000', blocked.path]);
      expect(chmod.exitCode, 0);
      addTearDown(() async {
        final restore = await Process.run('chmod', ['700', blocked.path]);
        expect(restore.exitCode, 0);
      });

      final report = await StorageUsageService.computeReport();
      final chat = report.categories.singleWhere(
        (category) => category.key == StorageUsageCategoryKey.chatData,
      );

      expect(chat.stats.bytes, 11);
      expect(chat.stats.fileCount, 1);
      expect(report.totalBytes, 21);
    },
    skip: Platform.isWindows
        ? 'chmod cannot revoke permissions on Windows; covered on POSIX CI'
        : false,
  );

  test(
    'listCacheEntries keeps listing files after an unreadable subdirectory',
    () async {
      final cacheDir = Directory(p.join(appDataDir.path, 'cache'));
      final blocked = Directory(p.join(cacheDir.path, 'a_blocked'));
      await Directory(p.join(blocked.path, 'inner')).create(recursive: true);
      await _writeSizedFile(
        Directory(p.join(blocked.path, 'inner')),
        'hidden.bin',
        10,
      );
      final readable = Directory(p.join(cacheDir.path, 'z_readable'));
      await readable.create(recursive: true);
      await _writeSizedFile(readable, 'icon.png', 5);
      final chmod = await Process.run('chmod', ['000', blocked.path]);
      expect(chmod.exitCode, 0);
      addTearDown(() async {
        final restore = await Process.run('chmod', ['700', blocked.path]);
        expect(restore.exitCode, 0);
      });

      final entries = await StorageUsageService.listCacheEntries(
        subcategoryId: 'other_cache',
      );

      // Files inside the unreadable dir are inaccessible, but the readable
      // sibling after it must still be returned instead of being dropped by
      // a terminated recursive stream.
      expect(entries.map((e) => e.name), ['icon.png']);
    },
    skip: Platform.isWindows
        ? 'chmod cannot revoke permissions on Windows; covered on POSIX CI'
        : false,
  );

  test('listCacheEntries splits avatar and other cache boundaries', () async {
    final cacheDir = Directory(p.join(appDataDir.path, 'cache'));
    await Directory(p.join(cacheDir.path, 'avatars')).create(recursive: true);
    await Directory(
      p.join(cacheDir.path, 'request-log-analysis'),
    ).create(recursive: true);
    await _writeSizedFile(
      Directory(p.join(cacheDir.path, 'avatars')),
      'av_1.png',
      10,
    );
    await _writeSizedFile(cacheDir, 'proactive_icon_1.png', 5);
    await _writeSizedFile(
      Directory(p.join(cacheDir.path, 'request-log-analysis')),
      'draft.json',
      7,
    );

    final avatars = await StorageUsageService.listCacheEntries(
      subcategoryId: 'avatar_cache',
    );
    expect(avatars.map((e) => e.name), ['av_1.png']);
    expect(avatars.single.bytes, 10);

    final other = await StorageUsageService.listCacheEntries(
      subcategoryId: 'other_cache',
    );
    expect(
      other.map((e) => e.name),
      containsAll(['proactive_icon_1.png', 'draft.json']),
    );
    expect(other.where((e) => e.name == 'av_1.png'), isEmpty);
    expect(other.length, 2);
  });

  test(
    'deleteCacheFiles validates paths against the subcategory root',
    () async {
      final cacheDir = Directory(p.join(appDataDir.path, 'cache'));
      await Directory(p.join(cacheDir.path, 'avatars')).create(recursive: true);
      await Directory(
        p.join(cacheDir.path, 'request-log-analysis'),
      ).create(recursive: true);
      await _writeSizedFile(
        Directory(p.join(cacheDir.path, 'avatars')),
        'av_1.png',
        10,
      );
      await _writeSizedFile(
        Directory(p.join(cacheDir.path, 'request-log-analysis')),
        'draft.json',
        7,
      );
      await _writeSizedFile(appDataDir, 'notes.txt', 50);

      final avatarPath = p.join(cacheDir.path, 'avatars', 'av_1.png');
      final draftPath = p.join(
        cacheDir.path,
        'request-log-analysis',
        'draft.json',
      );
      final notesPath = p.join(appDataDir.path, 'notes.txt');

      // Avatar files must be refused by other_cache.
      expect(
        await StorageUsageService.deleteCacheFiles([
          avatarPath,
        ], subcategoryId: 'other_cache'),
        0,
      );
      expect(File(avatarPath).existsSync(), isTrue);

      // Paths outside the app cache roots must be refused.
      expect(
        await StorageUsageService.deleteCacheFiles([
          notesPath,
        ], subcategoryId: 'avatar_cache'),
        0,
      );
      expect(File(notesPath).existsSync(), isTrue);

      // In-root deletions return the count of actually deleted files.
      expect(
        await StorageUsageService.deleteCacheFiles([
          draftPath,
          notesPath,
        ], subcategoryId: 'other_cache'),
        1,
      );
      expect(File(draftPath).existsSync(), isFalse);
      expect(File(notesPath).existsSync(), isTrue);
    },
  );

  test('listCacheEntries lists the system cache directory', () async {
    final sysCache = Directory(p.join(tempDir.path, 'cache'));
    await sysCache.create(recursive: true);
    await _writeSizedFile(sysCache, 'decoded.bin', 30);

    final entries = await StorageUsageService.listCacheEntries(
      subcategoryId: 'system_cache',
    );

    expect(entries.single.name, 'decoded.bin');
    expect(entries.single.bytes, 30);
  });

  test('listCacheEntries and deleteCacheFiles are no-ops for unavailable '
      'categories', () async {
    // No iOS tmp channel (equivalent to non-iOS).
    expect(
      await StorageUsageService.listCacheEntries(subcategoryId: 'tmp_cache'),
      isEmpty,
    );
    expect(
      await StorageUsageService.deleteCacheFiles([
        'x',
      ], subcategoryId: 'tmp_cache'),
      0,
    );
    expect(
      await StorageUsageService.listCacheEntries(subcategoryId: 'unknown_id'),
      isEmpty,
    );
    expect(
      await StorageUsageService.deleteCacheFiles([
        'x',
      ], subcategoryId: 'unknown_id'),
      0,
    );
  });

  test(
    'relocated workspaces root inside app data keeps its category split',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final relocated = Directory(p.join(appDataDir.path, 'my-ws-data'));
      await Directory(
        p.join(relocated.path, 'default', '.sandbox', 'linux', 'bin'),
      ).create(recursive: true);
      await _writeSizedFile(
        Directory(p.join(relocated.path, 'default')),
        'notes.txt',
        50,
      );
      await _writeSizedFile(
        Directory(
          p.join(relocated.path, 'default', '.sandbox', 'linux', 'bin'),
        ),
        'sh',
        100,
      );
      SharedPreferences.setMockInitialValues({
        'workspaces_dir_v1': relocated.path,
      });

      final report = await StorageUsageService.computeReport();
      final ws = report.categories.singleWhere(
        (category) => category.key == StorageUsageCategoryKey.workspaces,
      );
      final sandbox = report.categories.singleWhere(
        (category) => category.key == StorageUsageCategoryKey.sandbox,
      );

      expect(ws.stats.bytes, 50);
      expect(sandbox.stats.bytes, 100);
      // No byte may leak into any other reported category.
      for (final category in report.categories) {
        if (category.key != StorageUsageCategoryKey.workspaces &&
            category.key != StorageUsageCategoryKey.sandbox) {
          expect(category.stats.bytes, 0, reason: '${category.key} not empty');
        }
      }
      expect(report.totalBytes, 150);
    },
  );
}
