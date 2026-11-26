import 'dart:io';

import 'package:Cuplivo/core/services/network/request_logger.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PathProviderPlatform previousPathProvider;
  late Directory logsDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('kelivo_log_cleanup_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    logsDir = Directory('${tempDir.path}/logs');
    await logsDir.create(recursive: true);
  });

  tearDown(() async {
    PathProviderPlatform.instance = previousPathProvider;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<File> writeLog(String name, {required List<int> bytes}) async {
    final file = File('${logsDir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  test('cleanupLogs does not delete active logger files by age', () async {
    final cutoffAgo = DateTime.now().subtract(const Duration(days: 10));
    final active = <File>[];
    for (final name in RequestLogger.activeLogFileNames) {
      final file = await writeLog(name, bytes: [1, 2, 3]);
      await file.setLastModified(cutoffAgo);
      active.add(file);
    }
    final oldRotated = await writeLog('logs_2020-01-01.txt', bytes: [4, 5, 6]);
    await oldRotated.setLastModified(cutoffAgo);
    final recentRotated = await writeLog(
      'context_logs_2026-08-12.txt',
      bytes: [7, 8, 9],
    );
    await recentRotated.setLastModified(DateTime.now());

    await RequestLogger.cleanupLogs(autoDeleteDays: 1, maxSizeMB: 0);

    for (final file in active) {
      expect(await file.exists(), isTrue, reason: file.path);
    }
    expect(await oldRotated.exists(), isFalse);
    expect(await recentRotated.exists(), isTrue);
  });

  test('cleanupLogs size cap skips active files', () async {
    final chunk = List<int>.filled(600 * 1024, 65);
    final active = await writeLog('logs.txt', bytes: chunk);
    await active.setLastModified(
      DateTime.now().subtract(const Duration(days: 3)),
    );
    final olderRotated = await writeLog('logs_2026-08-01.txt', bytes: chunk);
    await olderRotated.setLastModified(
      DateTime.now().subtract(const Duration(days: 2)),
    );
    final newerRotated = await writeLog('logs_2026-08-10.txt', bytes: chunk);
    await newerRotated.setLastModified(
      DateTime.now().subtract(const Duration(days: 1)),
    );

    await RequestLogger.cleanupLogs(autoDeleteDays: 0, maxSizeMB: 1);

    expect(await active.exists(), isTrue);
    expect(await olderRotated.exists(), isFalse);
    expect(await newerRotated.exists(), isTrue);
  });
}
