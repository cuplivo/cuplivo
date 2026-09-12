import 'dart:io';

import 'package:Cuplivo/core/services/network/request_logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async =>
      p.join(root, 'documents');

  @override
  Future<String?> getApplicationSupportPath() async => p.join(root, 'support');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Directory logsDir;
  late PathProviderPlatform previousPathProvider;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tempDir = await Directory.systemTemp.createTemp(
      'cuplivo_request_log_cleanup_test_',
    );
    logsDir = Directory(p.join(tempDir.path, 'support', 'logs'));
    await logsDir.create(recursive: true);
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    PathProviderPlatform.instance = previousPathProvider;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('age cleanup deletes old request logs but never app logs', () async {
    final old = DateTime.now().subtract(const Duration(days: 30));
    final requestLog = File(p.join(logsDir.path, 'logs_2026-01-01.txt'));
    final appLog = File(p.join(logsDir.path, 'flutter_logs_2026-01-01.txt'));
    await requestLog.writeAsString('request', flush: true);
    await appLog.writeAsString('app', flush: true);
    await requestLog.setLastModified(old);
    await appLog.setLastModified(old);

    await RequestLogger.cleanupLogs(autoDeleteDays: 7, maxSizeMB: 0);

    expect(await requestLog.exists(), isFalse);
    expect(await appLog.exists(), isTrue);
  });

  test('size cap counts only request logs', () async {
    final requestOld = File(p.join(logsDir.path, 'logs_2026-01-01.txt'));
    final requestNew = File(p.join(logsDir.path, 'logs_2026-06-01.txt'));
    final appLog = File(p.join(logsDir.path, 'flutter_logs.txt'));
    await requestOld.writeAsBytes(List<int>.filled(700 * 1024, 1));
    await requestNew.writeAsBytes(List<int>.filled(700 * 1024, 2));
    await appLog.writeAsBytes(List<int>.filled(2 * 1024 * 1024, 3));
    await appLog.setLastModified(DateTime(2020, 1, 1));
    await requestOld.setLastModified(DateTime(2026, 1, 1));
    await requestNew.setLastModified(DateTime(2026, 6, 1));

    await RequestLogger.cleanupLogs(autoDeleteDays: 0, maxSizeMB: 1);

    expect(await requestOld.exists(), isFalse);
    expect(await requestNew.exists(), isTrue);
    expect(await appLog.exists(), isTrue);
  });
}
