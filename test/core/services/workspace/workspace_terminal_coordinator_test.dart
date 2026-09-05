import 'dart:async';

import 'package:Cuplivo/core/models/workspace.dart';
import 'package:Cuplivo/core/services/workspace/linux_sandbox_service.dart';
import 'package:Cuplivo/core/services/workspace/workspace_terminal_coordinator.dart';
import 'package:Cuplivo/core/services/workspace/workspace_terminal_native_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

const _notification = WorkspaceTerminalNotificationStrings(
  channelName: 'channel',
  title: 'title',
  text: 'text',
);

Workspace _workspace(
  String id, {
  bool keep = true,
  bool durable = false,
  bool autoStart = false,
  bool readOnly = false,
}) => Workspace(
  id: id,
  displayName: id,
  alias: id,
  keepTerminalAfterExit: keep,
  terminalPersistentKeepAlive: durable,
  autoStartLinuxSandbox: autoStart,
  readOnly: readOnly,
);

class _FakeWorkspaceStore implements WorkspaceTerminalWorkspaceStore {
  _FakeWorkspaceStore(this.items, {Future<void> Function()? initialize})
    : _initialize = initialize ?? (() async {});

  List<Workspace> items;
  final Future<void> Function() _initialize;
  final List<String> calls = <String>[];

  @override
  Future<void> initialize() async {
    calls.add('workspace:init');
    await _initialize();
  }

  @override
  String? hostPathFor(Workspace workspace) => '/workspaces/${workspace.id}';

  @override
  List<Workspace> get orderedWorkspaces => List<Workspace>.of(items);

  @override
  Future<void> persistSettings(
    String workspaceId, {
    required bool keepTerminalAfterExit,
    required bool terminalPersistentKeepAlive,
    required bool autoStartLinuxSandbox,
  }) async {
    calls.add(
      'persist:$workspaceId:$keepTerminalAfterExit:'
      '$terminalPersistentKeepAlive:$autoStartLinuxSandbox',
    );
    final index = items.indexWhere((workspace) => workspace.id == workspaceId);
    if (index < 0) return;
    items[index] = items[index].copyWith(
      keepTerminalAfterExit: keepTerminalAfterExit,
      terminalPersistentKeepAlive: terminalPersistentKeepAlive,
      autoStartLinuxSandbox: autoStartLinuxSandbox,
    );
  }

  @override
  Workspace? workspaceById(String id) {
    for (final workspace in items) {
      if (workspace.id == id) return workspace;
    }
    return null;
  }
}

class _FakeSandbox implements WorkspaceTerminalSandboxPort {
  _FakeSandbox({Future<void> Function()? initialize})
    : _initialize = initialize ?? (() async {});

  final Future<void> Function() _initialize;
  final List<String> calls = <String>[];
  final Map<String, SandboxStatus> statuses = <String, SandboxStatus>{};

  @override
  Future<void> initialize() async {
    calls.add('sandbox:init');
    await _initialize();
  }

  @override
  Future<SandboxPtyLaunchSpec> launchSpec(
    String workspaceId,
    String workspaceHostPath,
  ) async {
    calls.add('spec:$workspaceId');
    return SandboxPtyLaunchSpec(
      executable: '/proot',
      arguments: <String>['/bin/bash', '-l'],
      environment: const <String, String>{'TERM': 'xterm-256color'},
      workingDirectory: workspaceHostPath,
    );
  }

  @override
  Future<SandboxStatus> statusFor(String workspaceHostPath) async {
    calls.add('status:$workspaceHostPath');
    return statuses[workspaceHostPath] ?? SandboxStatus.ready;
  }
}

class _FakeTerminal implements WorkspaceTerminalPort {
  final Map<String, WorkspaceTerminalSessionState> states =
      <String, WorkspaceTerminalSessionState>{};
  final Set<String> startFailures = <String>{};
  final Set<String> stopFailures = <String>{};
  final List<String> calls = <String>[];

  @override
  Future<WorkspaceTerminalSessionState> getSessionState(
    String workspaceId,
  ) async =>
      states[workspaceId] ?? WorkspaceTerminalSessionState.absent(workspaceId);

  @override
  Future<WorkspaceTerminalSessionState> setDurable(
    String workspaceId,
    bool durable, {
    required WorkspaceTerminalNotificationStrings notificationStrings,
  }) async {
    calls.add('durable:$workspaceId:$durable');
    final current = states[workspaceId]!;
    final next = WorkspaceTerminalSessionState(
      workspaceId: workspaceId,
      state: current.state,
      durable: durable,
      autoStarted: current.autoStarted,
      attachedViews: current.attachedViews,
      sessionId: current.sessionId,
      processId: current.processId,
      exitCode: current.exitCode,
    );
    states[workspaceId] = next;
    return next;
  }

  @override
  Future<WorkspaceTerminalSessionState> startSession({
    required String workspaceId,
    required String workspaceHostPath,
    required SandboxPtyLaunchSpec launchSpec,
    required bool durable,
    required bool autoStarted,
    required WorkspaceTerminalNotificationStrings notificationStrings,
  }) async {
    calls.add('start:$workspaceId:$durable:$autoStarted');
    if (startFailures.contains(workspaceId)) {
      throw StateError('start failed for $workspaceId');
    }
    final state = WorkspaceTerminalSessionState(
      workspaceId: workspaceId,
      state: WorkspaceTerminalProcessState.running,
      durable: durable,
      autoStarted: autoStarted,
      attachedViews: 0,
      sessionId: 'session-$workspaceId',
      processId: 42,
    );
    states[workspaceId] = state;
    return state;
  }

  @override
  Future<void> stopAllSessions() async {
    calls.add('stop-all');
    states.clear();
  }

  @override
  Future<void> stopAutoSessionIfDetached(String workspaceId) async {
    calls.add('stop-auto:$workspaceId');
    if (stopFailures.contains(workspaceId)) {
      throw StateError('stop failed for $workspaceId');
    }
    states.remove(workspaceId);
  }

  @override
  Future<void> stopSession(String workspaceId) async {
    calls.add('stop:$workspaceId');
    if (stopFailures.contains(workspaceId)) {
      throw StateError('stop failed for $workspaceId');
    }
    states.remove(workspaceId);
  }

  @override
  Future<void> stopSessionForWorkspacePath(String workspaceHostPath) async {
    calls.add('stop-path:$workspaceHostPath');
  }
}

void main() {
  test('session-state map validates native state and attached count', () {
    final running = WorkspaceTerminalSessionState.fromMap('workspace-a', {
      'state': 'running',
      'sessionId': 'session-a',
      'processId': 7,
      'durable': true,
      'autoStarted': false,
      'attachedViews': 1,
    });

    expect(running.running, isTrue);
    expect(running.durable, isTrue);
    expect(running.attachedViews, 1);
    expect(
      () => WorkspaceTerminalSessionState.fromMap('workspace-a', {
        'state': 'running',
        'attachedViews': -1,
      }),
      throwsStateError,
    );
    expect(
      () => WorkspaceTerminalSessionState.fromMap('workspace-a', {
        'state': 'mystery',
        'attachedViews': 0,
      }),
      throwsStateError,
    );
  });

  test(
    'startup waits for workspace and SAF initialization then uses order',
    () async {
      final workspaceReady = Completer<void>();
      final safReady = Completer<void>();
      final store = _FakeWorkspaceStore(<Workspace>[
        _workspace('workspace-b', autoStart: true),
        _workspace('workspace-skip'),
        _workspace('workspace-a', durable: true, autoStart: true),
        _workspace('workspace-readonly', autoStart: true, readOnly: true),
      ], initialize: () => workspaceReady.future);
      final sandbox = _FakeSandbox(initialize: () => safReady.future);
      final terminal = _FakeTerminal();
      final coordinator = WorkspaceTerminalCoordinator(
        workspaces: store,
        sandbox: sandbox,
        terminal: terminal,
        androidProbe: () => true,
      );

      final startup = coordinator.initialize(_notification);
      final duplicateStartup = coordinator.initialize(_notification);
      expect(identical(startup, duplicateStartup), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(sandbox.calls, isEmpty);
      expect(terminal.calls, isEmpty);

      workspaceReady.complete();
      await Future<void>.delayed(Duration.zero);
      expect(sandbox.calls, <String>['sandbox:init']);
      expect(terminal.calls, isEmpty);

      safReady.complete();
      await Future.wait(<Future<void>>[startup, duplicateStartup]);
      expect(terminal.calls, <String>[
        'start:workspace-b:false:true',
        'start:workspace-a:true:true',
      ]);
    },
  );

  test('failed automatic startup preserves the persisted opt-in', () async {
    final store = _FakeWorkspaceStore(<Workspace>[
      _workspace('workspace-a', autoStart: true),
    ]);
    final terminal = _FakeTerminal()..startFailures.add('workspace-a');
    final coordinator = WorkspaceTerminalCoordinator(
      workspaces: store,
      sandbox: _FakeSandbox(),
      terminal: terminal,
      androidProbe: () => true,
    );

    await coordinator.initialize(_notification);

    expect(store.workspaceById('workspace-a')!.autoStartLinuxSandbox, isTrue);
    expect(store.calls.where((call) => call.startsWith('persist:')), isEmpty);
  });

  test('disabling parent stops first and atomically clears children', () async {
    final store = _FakeWorkspaceStore(<Workspace>[
      _workspace('workspace-a', durable: true, autoStart: true),
    ]);
    final terminal = _FakeTerminal();
    final coordinator = WorkspaceTerminalCoordinator(
      workspaces: store,
      sandbox: _FakeSandbox(),
      terminal: terminal,
      androidProbe: () => true,
    )..updateNotificationStrings(_notification);

    await coordinator.setKeepTerminalAfterExit('workspace-a', false);

    expect(terminal.calls, <String>['stop:workspace-a']);
    expect(store.calls.last, 'persist:workspace-a:false:false:false');
    final workspace = store.workspaceById('workspace-a')!;
    expect(workspace.keepTerminalAfterExit, isFalse);
    expect(workspace.terminalPersistentKeepAlive, isFalse);
    expect(workspace.autoStartLinuxSandbox, isFalse);
  });

  test('failed parent stop preserves all three settings', () async {
    final store = _FakeWorkspaceStore(<Workspace>[
      _workspace('workspace-a', durable: true, autoStart: true),
    ]);
    final terminal = _FakeTerminal()..stopFailures.add('workspace-a');
    final coordinator = WorkspaceTerminalCoordinator(
      workspaces: store,
      sandbox: _FakeSandbox(),
      terminal: terminal,
      androidProbe: () => true,
    )..updateNotificationStrings(_notification);

    await expectLater(
      coordinator.setKeepTerminalAfterExit('workspace-a', false),
      throwsA(isA<WorkspaceTerminalStopException>()),
    );

    final workspace = store.workspaceById('workspace-a')!;
    expect(workspace.keepTerminalAfterExit, isTrue);
    expect(workspace.terminalPersistentKeepAlive, isTrue);
    expect(workspace.autoStartLinuxSandbox, isTrue);
    expect(store.calls.where((call) => call.startsWith('persist:')), isEmpty);
  });

  test(
    'durable setting upgrades and downgrades a running session before persistence',
    () async {
      final store = _FakeWorkspaceStore(<Workspace>[_workspace('workspace-a')]);
      final terminal = _FakeTerminal()
        ..states['workspace-a'] = const WorkspaceTerminalSessionState(
          workspaceId: 'workspace-a',
          state: WorkspaceTerminalProcessState.running,
          durable: false,
          autoStarted: false,
          attachedViews: 1,
        );
      var permissionRequests = 0;
      final coordinator = WorkspaceTerminalCoordinator(
        workspaces: store,
        sandbox: _FakeSandbox(),
        terminal: terminal,
        androidProbe: () => true,
        requestNotificationPermission: () async {
          permissionRequests++;
          return true;
        },
      )..updateNotificationStrings(_notification);

      await coordinator.setDurable('workspace-a', true);

      expect(permissionRequests, 1);
      expect(terminal.calls, <String>['durable:workspace-a:true']);
      expect(store.calls.last, 'persist:workspace-a:true:true:false');

      await coordinator.setDurable('workspace-a', false);

      expect(permissionRequests, 1);
      expect(terminal.calls, <String>[
        'durable:workspace-a:true',
        'durable:workspace-a:false',
      ]);
      expect(store.calls.last, 'persist:workspace-a:true:false:false');
    },
  );

  test('durable setting without a session only persists the opt-in', () async {
    final store = _FakeWorkspaceStore(<Workspace>[_workspace('workspace-a')]);
    final terminal = _FakeTerminal();
    final coordinator = WorkspaceTerminalCoordinator(
      workspaces: store,
      sandbox: _FakeSandbox(),
      terminal: terminal,
      androidProbe: () => true,
      requestNotificationPermission: () async => true,
    )..updateNotificationStrings(_notification);

    await coordinator.setDurable('workspace-a', true);

    expect(terminal.calls, isEmpty);
    expect(store.calls.last, 'persist:workspace-a:true:true:false');
  });

  test(
    'denied notification permission leaves durable setting disabled',
    () async {
      final store = _FakeWorkspaceStore(<Workspace>[_workspace('workspace-a')]);
      final terminal = _FakeTerminal();
      final coordinator = WorkspaceTerminalCoordinator(
        workspaces: store,
        sandbox: _FakeSandbox(),
        terminal: terminal,
        androidProbe: () => true,
        requestNotificationPermission: () async => false,
      )..updateNotificationStrings(_notification);

      await expectLater(
        coordinator.setDurable('workspace-a', true),
        throwsA(isA<WorkspaceTerminalNotificationPermissionException>()),
      );

      expect(
        store.workspaceById('workspace-a')!.terminalPersistentKeepAlive,
        isFalse,
      );
      expect(
        terminal.calls.where((call) => call.startsWith('durable:')),
        isEmpty,
      );
      expect(store.calls.where((call) => call.startsWith('persist:')), isEmpty);
    },
  );

  test(
    'auto-start failure does not persist and disabling stops hidden session',
    () async {
      final store = _FakeWorkspaceStore(<Workspace>[_workspace('workspace-a')]);
      final terminal = _FakeTerminal()..startFailures.add('workspace-a');
      final coordinator = WorkspaceTerminalCoordinator(
        workspaces: store,
        sandbox: _FakeSandbox(),
        terminal: terminal,
        androidProbe: () => true,
      )..updateNotificationStrings(_notification);

      await expectLater(
        coordinator.setAutoStart('workspace-a', true),
        throwsStateError,
      );
      expect(store.calls.where((call) => call.startsWith('persist:')), isEmpty);

      terminal.startFailures.clear();
      await coordinator.setAutoStart('workspace-a', true);
      await coordinator.setAutoStart('workspace-a', false);
      expect(terminal.calls.last, 'stop-auto:workspace-a');
      expect(store.calls.last, 'persist:workspace-a:true:false:false');
    },
  );
}
