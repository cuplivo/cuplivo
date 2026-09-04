import 'dart:io';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/workspace.dart';
import 'package:Cuplivo/core/providers/workspace_provider.dart';
import 'package:Cuplivo/core/services/workspace/linux_sandbox_service.dart';
import 'package:Cuplivo/core/services/workspace/workspace_terminal_native_bridge.dart';
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
}

class _StopOnlyTerminal implements WorkspaceTerminalPort {
  bool failStops = false;
  final List<String> stopped = <String>[];

  @override
  Future<WorkspaceTerminalSessionState> getSessionState(String workspaceId) {
    return Future<WorkspaceTerminalSessionState>.value(
      WorkspaceTerminalSessionState.absent(workspaceId),
    );
  }

  @override
  Future<WorkspaceTerminalSessionState> setDurable(
    String workspaceId,
    bool durable, {
    required WorkspaceTerminalNotificationStrings notificationStrings,
  }) => throw UnimplementedError();

  @override
  Future<WorkspaceTerminalSessionState> startSession({
    required String workspaceId,
    required String workspaceHostPath,
    required SandboxPtyLaunchSpec launchSpec,
    required bool durable,
    required bool autoStarted,
    required WorkspaceTerminalNotificationStrings notificationStrings,
  }) => throw UnimplementedError();

  @override
  Future<void> stopAllSessions() async {}

  @override
  Future<void> stopAutoSessionIfDetached(String workspaceId) async {}

  @override
  Future<void> stopSession(String workspaceId) async {
    stopped.add(workspaceId);
    if (failStops) throw StateError('stop failed');
  }

  @override
  Future<void> stopSessionForWorkspacePath(String workspaceHostPath) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temporaryDirectory;
  late PathProviderPlatform originalPathProvider;
  late _StopOnlyTerminal terminal;
  late BusinessPreferences preferences;
  late WorkspaceProvider provider;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'workspace-terminal-lifecycle',
    );
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(temporaryDirectory.path);
    terminal = _StopOnlyTerminal();
    preferences = BusinessPreferences.memoryForTests();
    provider = WorkspaceProvider(preferences: preferences, terminal: terminal);
    await provider.init();
  });

  tearDown(() async {
    provider.dispose();
    PathProviderPlatform.instance = originalPathProvider;
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('delete stops the terminal before removing workspace data', () async {
    final workspace = await provider.createWorkspace(displayName: 'Second');
    final hostPath = provider.hostPathFor(workspace)!;
    await File('$hostPath/marker').writeAsString('keep');

    expect(await provider.deleteWorkspace(workspace.id), isNull);

    expect(terminal.stopped, <String>[workspace.id]);
    expect(provider.getById(workspace.id), isNull);
    expect(await Directory(hostPath).exists(), isFalse);
  });

  test(
    'three terminal flags are persisted in one workspace meta write',
    () async {
      await provider.setTerminalPersistenceSettings(
        Workspace.defaultId,
        keepTerminalAfterExit: true,
        terminalPersistentKeepAlive: true,
        autoStartLinuxSandbox: true,
      );

      final raw = preferences.getString(WorkspaceProvider.metaPrefsKey)!;
      expect(raw, contains('"keepTerminalAfterExit":true'));
      expect(raw, contains('"terminalPersistentKeepAlive":true'));
      expect(raw, contains('"autoStartLinuxSandbox":true'));
    },
  );

  test('failed stop cancels deletion and keeps workspace data', () async {
    final workspace = await provider.createWorkspace(displayName: 'Second');
    final hostPath = provider.hostPathFor(workspace)!;
    await File('$hostPath/marker').writeAsString('keep');
    terminal.failStops = true;

    expect(
      await provider.deleteWorkspace(workspace.id),
      WorkspaceProvider.errorTerminalStopFailed,
    );

    expect(provider.getById(workspace.id), isNotNull);
    expect(await File('$hostPath/marker').exists(), isTrue);
  });

  test('failed stop cancels a custom host-path change', () async {
    final workspace = await provider.createWorkspace(displayName: 'Second');
    final destination = await Directory(
      '${temporaryDirectory.path}/external',
    ).create();
    terminal.failStops = true;

    expect(
      await provider.setCustomHostPath(
        workspace.id,
        destination.path,
        moveFiles: false,
      ),
      WorkspaceProvider.errorTerminalStopFailed,
    );

    expect(provider.getById(workspace.id)!.customHostPath, isNull);
  });
}
