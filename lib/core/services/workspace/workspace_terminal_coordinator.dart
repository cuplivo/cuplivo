import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/workspace.dart';
import '../../providers/workspace_provider.dart';
import '../notification_service.dart';
import '../saf/saf_mount_sync_service.dart';
import 'linux_sandbox_service.dart';
import 'workspace_terminal_native_bridge.dart';

abstract interface class WorkspaceTerminalWorkspaceStore {
  Future<void> initialize();

  List<Workspace> get orderedWorkspaces;

  Workspace? workspaceById(String id);

  String? hostPathFor(Workspace workspace);

  Future<void> persistSettings(
    String workspaceId, {
    required bool keepTerminalAfterExit,
    required bool terminalPersistentKeepAlive,
    required bool autoStartLinuxSandbox,
  });
}

class WorkspaceProviderTerminalStore
    implements WorkspaceTerminalWorkspaceStore {
  WorkspaceProviderTerminalStore(this.provider);

  final WorkspaceProvider provider;

  @override
  Future<void> initialize() => provider.init();

  @override
  List<Workspace> get orderedWorkspaces => provider.workspaces;

  @override
  Workspace? workspaceById(String id) => provider.getById(id);

  @override
  String? hostPathFor(Workspace workspace) => provider.hostPathFor(workspace);

  @override
  Future<void> persistSettings(
    String workspaceId, {
    required bool keepTerminalAfterExit,
    required bool terminalPersistentKeepAlive,
    required bool autoStartLinuxSandbox,
  }) => provider.setTerminalPersistenceSettings(
    workspaceId,
    keepTerminalAfterExit: keepTerminalAfterExit,
    terminalPersistentKeepAlive: terminalPersistentKeepAlive,
    autoStartLinuxSandbox: autoStartLinuxSandbox,
  );
}

abstract interface class WorkspaceTerminalSandboxPort {
  Future<void> initialize();

  Future<SandboxStatus> statusFor(String workspaceHostPath);

  Future<SandboxPtyLaunchSpec> launchSpec(
    String workspaceId,
    String workspaceHostPath,
  );
}

class WorkspaceTerminalSandboxGateway implements WorkspaceTerminalSandboxPort {
  WorkspaceTerminalSandboxGateway({
    required this.sandbox,
    required this.safMounts,
  });

  final LinuxSandboxService sandbox;
  final SafMountSyncService safMounts;

  @override
  Future<void> initialize() => safMounts.init();

  @override
  Future<SandboxStatus> statusFor(String workspaceHostPath) =>
      sandbox.statusFor(workspaceHostPath);

  @override
  Future<SandboxPtyLaunchSpec> launchSpec(
    String workspaceId,
    String workspaceHostPath,
  ) => sandbox.ptyLaunchSpec(
    workspaceHostPath,
    binds: safMounts.guestBindsFor(workspaceId),
  );
}

class WorkspaceTerminalStartException implements Exception {
  const WorkspaceTerminalStartException(this.status);

  final SandboxStatus status;

  @override
  String toString() => 'Workspace terminal cannot start: ${status.name}';
}

class WorkspaceTerminalNotificationPermissionException implements Exception {
  const WorkspaceTerminalNotificationPermissionException();

  @override
  String toString() => 'Terminal notification permission was denied';
}

/// Coordinates persisted workspace policy with the Android-owned terminal.
class WorkspaceTerminalCoordinator {
  WorkspaceTerminalCoordinator({
    required this.workspaces,
    required this.sandbox,
    required this.terminal,
    bool Function()? androidProbe,
    Future<bool> Function()? requestNotificationPermission,
  }) : _androidProbe = androidProbe ?? (() => Platform.isAndroid),
       _requestNotificationPermission =
           requestNotificationPermission ??
           (() async {
             await NotificationService.ensureInitialized();
             return NotificationService.ensureAndroidNotificationsPermission();
           });

  final WorkspaceTerminalWorkspaceStore workspaces;
  final WorkspaceTerminalSandboxPort sandbox;
  final WorkspaceTerminalPort terminal;
  final bool Function() _androidProbe;
  final Future<bool> Function() _requestNotificationPermission;

  WorkspaceTerminalNotificationStrings? _notificationStrings;
  Future<void>? _dependenciesReady;
  Future<void>? _startup;

  void updateNotificationStrings(
    WorkspaceTerminalNotificationStrings notificationStrings,
  ) {
    _notificationStrings = notificationStrings;
  }

  Future<void> initialize(
    WorkspaceTerminalNotificationStrings notificationStrings,
  ) {
    updateNotificationStrings(notificationStrings);
    if (!_androidProbe()) return Future<void>.value();
    final existing = _startup;
    if (existing != null) return existing;
    final next = _runStartup();
    _startup = next;
    return next;
  }

  Future<void> _runStartup() async {
    try {
      await _autoStartConfiguredWorkspaces();
    } catch (_) {
      _startup = null;
      rethrow;
    }
  }

  Future<void> _ensureDependenciesReady() {
    final existing = _dependenciesReady;
    if (existing != null) return existing;
    final next = _initializeDependencies();
    _dependenciesReady = next;
    return next;
  }

  Future<void> _initializeDependencies() async {
    try {
      await workspaces.initialize();
      await sandbox.initialize();
    } catch (_) {
      _dependenciesReady = null;
      rethrow;
    }
  }

  Future<void> _autoStartConfiguredWorkspaces() async {
    await _ensureDependenciesReady();
    for (final workspace in workspaces.orderedWorkspaces) {
      if (!workspace.keepTerminalAfterExit ||
          !workspace.autoStartLinuxSandbox) {
        continue;
      }
      if (workspace.readOnly) {
        debugPrint(
          'WorkspaceTerminalCoordinator: auto-start skipped for '
          '${workspace.id}: workspace is read-only',
        );
        continue;
      }
      try {
        await ensureSession(workspace.id, autoStarted: true);
      } catch (error, stackTrace) {
        debugPrint(
          'WorkspaceTerminalCoordinator: auto-start failed for '
          '${workspace.id}: $error\n$stackTrace',
        );
      }
    }
  }

  Future<WorkspaceTerminalSessionState> ensureSession(
    String workspaceId, {
    bool autoStarted = false,
  }) async {
    if (!_androidProbe()) {
      throw UnsupportedError('Workspace terminal is Android-only');
    }
    await _ensureDependenciesReady();
    final workspace = workspaces.workspaceById(workspaceId);
    if (workspace == null) {
      throw StateError('Workspace not found: $workspaceId');
    }
    if (workspace.readOnly) {
      throw const WorkspaceTerminalStartException(SandboxStatus.unsupported);
    }
    final hostPath = workspaces.hostPathFor(workspace);
    if (hostPath == null) {
      throw StateError('Workspace has no host path: $workspaceId');
    }
    final existing = await terminal.getSessionState(workspaceId);
    if (existing.running) return existing;
    final status = await sandbox.statusFor(hostPath);
    if (status != SandboxStatus.ready) {
      throw WorkspaceTerminalStartException(status);
    }
    final notificationStrings = _notificationStrings;
    if (notificationStrings == null) {
      throw StateError('Workspace terminal notification strings unavailable');
    }
    final spec = await sandbox.launchSpec(workspaceId, hostPath);
    return terminal.startSession(
      workspaceId: workspaceId,
      workspaceHostPath: hostPath,
      launchSpec: spec,
      durable: workspace.terminalPersistentKeepAlive,
      autoStarted: autoStarted,
      notificationStrings: notificationStrings,
    );
  }

  Future<WorkspaceTerminalSessionState> restartSession(
    String workspaceId,
  ) async {
    await terminal.stopSession(workspaceId);
    return ensureSession(workspaceId);
  }

  Future<void> leaveTerminalPage(String workspaceId) async {
    final workspace = workspaces.workspaceById(workspaceId);
    if (workspace?.keepTerminalAfterExit != true) {
      await terminal.stopSession(workspaceId);
    }
  }

  Future<void> setKeepTerminalAfterExit(
    String workspaceId,
    bool enabled,
  ) async {
    final workspace = workspaces.workspaceById(workspaceId);
    if (workspace == null) return;
    if (!enabled) {
      try {
        await terminal.stopSession(workspaceId);
      } catch (error) {
        throw WorkspaceTerminalStopException(error);
      }
    }
    await workspaces.persistSettings(
      workspaceId,
      keepTerminalAfterExit: enabled,
      terminalPersistentKeepAlive:
          enabled && workspace.terminalPersistentKeepAlive,
      autoStartLinuxSandbox: enabled && workspace.autoStartLinuxSandbox,
    );
  }

  Future<void> setDurable(String workspaceId, bool enabled) async {
    final workspace = workspaces.workspaceById(workspaceId);
    if (workspace == null || !workspace.keepTerminalAfterExit) return;
    final notificationStrings = _notificationStrings;
    if (notificationStrings == null) {
      throw StateError('Workspace terminal notification strings unavailable');
    }
    if (enabled && !await _requestNotificationPermission()) {
      throw const WorkspaceTerminalNotificationPermissionException();
    }
    final state = await terminal.getSessionState(workspaceId);
    if (state.running) {
      await terminal.setDurable(
        workspaceId,
        enabled,
        notificationStrings: notificationStrings,
      );
    }
    await workspaces.persistSettings(
      workspaceId,
      keepTerminalAfterExit: true,
      terminalPersistentKeepAlive: enabled,
      autoStartLinuxSandbox: workspace.autoStartLinuxSandbox,
    );
  }

  Future<void> setAutoStart(String workspaceId, bool enabled) async {
    final workspace = workspaces.workspaceById(workspaceId);
    if (workspace == null || !workspace.keepTerminalAfterExit) return;
    if (enabled) {
      await ensureSession(workspaceId, autoStarted: true);
    } else {
      try {
        await terminal.stopAutoSessionIfDetached(workspaceId);
      } catch (error) {
        throw WorkspaceTerminalStopException(error);
      }
    }
    await workspaces.persistSettings(
      workspaceId,
      keepTerminalAfterExit: true,
      terminalPersistentKeepAlive: workspace.terminalPersistentKeepAlive,
      autoStartLinuxSandbox: enabled,
    );
  }
}
