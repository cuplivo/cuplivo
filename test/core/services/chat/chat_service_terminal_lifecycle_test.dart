import 'dart:io';

import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/workspace/workspace_terminal_native_bridge.dart';
import 'package:Cuplivo/utils/app_directories.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temporaryDirectory;
  late PathProviderPlatform originalPathProvider;
  late ChatService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'chat-terminal-lifecycle',
    );
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(temporaryDirectory.path);
  });

  tearDown(() async {
    await service.close();
    PathProviderPlatform.instance = originalPathProvider;
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('terminal stop failure aborts a full destructive clear', () async {
    var stopCalls = 0;
    service = ChatService(
      stopWorkspaceTerminals: () async {
        stopCalls++;
        throw StateError('stop failed');
      },
    );
    await service.init();
    final workspaces = await AppDirectories.getWorkspacesDirectory();
    await workspaces.create(recursive: true);
    final marker = File('${workspaces.path}/keep.txt');
    await marker.writeAsString('keep');

    await expectLater(
      service.clearAllData(),
      throwsA(isA<WorkspaceTerminalStopException>()),
    );

    expect(stopCalls, 1);
    expect(await marker.exists(), isTrue);
  });
}
