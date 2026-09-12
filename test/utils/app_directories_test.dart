import 'dart:io';

import 'package:Cuplivo/utils/app_directories.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform({
    required this.supportPath,
    required this.documentsPath,
  });

  final String supportPath;
  final String documentsPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PathProviderPlatform previousPathProvider;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'cuplivo_app_directories_test_',
    );
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(
      supportPath: p.join(tempDir.path, 'support'),
      documentsPath: p.join(tempDir.path, 'documents'),
    );
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    PathProviderPlatform.instance = previousPathProvider;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('getLogsDirectory resolves under the support dir on desktop', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final dir = await AppDirectories.getLogsDirectory();
    expect(dir.path, p.join(tempDir.path, 'support', 'logs'));
  });

  test('getLogsDirectory resolves under the documents dir on mobile', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final dir = await AppDirectories.getLogsDirectory();
    expect(dir.path, p.join(tempDir.path, 'documents', 'logs'));
  });
}
