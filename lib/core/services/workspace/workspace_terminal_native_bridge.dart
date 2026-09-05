import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'linux_sandbox_service.dart';

enum WorkspaceTerminalProcessState { absent, running, exited }

class WorkspaceTerminalStopException implements Exception {
  const WorkspaceTerminalStopException(this.cause);

  final Object cause;

  @override
  String toString() => 'Workspace terminal stop failed: $cause';
}

@immutable
class WorkspaceTerminalSessionState {
  const WorkspaceTerminalSessionState({
    required this.workspaceId,
    required this.state,
    required this.durable,
    required this.autoStarted,
    required this.attachedViews,
    this.sessionId,
    this.processId,
    this.exitCode,
  });

  const WorkspaceTerminalSessionState.absent(String workspaceId)
    : this(
        workspaceId: workspaceId,
        state: WorkspaceTerminalProcessState.absent,
        durable: false,
        autoStarted: false,
        attachedViews: 0,
      );

  final String workspaceId;
  final WorkspaceTerminalProcessState state;
  final bool durable;
  final bool autoStarted;
  final int attachedViews;
  final String? sessionId;
  final int? processId;
  final int? exitCode;

  bool get exists => state != WorkspaceTerminalProcessState.absent;
  bool get running => state == WorkspaceTerminalProcessState.running;

  factory WorkspaceTerminalSessionState.fromMap(
    String workspaceId,
    Map<Object?, Object?>? map,
  ) {
    if (map == null || map['state'] == 'absent') {
      return WorkspaceTerminalSessionState.absent(workspaceId);
    }
    final state = switch (map['state']) {
      'running' => WorkspaceTerminalProcessState.running,
      'exited' => WorkspaceTerminalProcessState.exited,
      final value => throw StateError('Unknown terminal state: $value'),
    };
    final attachedViews = map['attachedViews'];
    if (attachedViews is! int || attachedViews < 0) {
      throw StateError('Invalid terminal attachedViews: $attachedViews');
    }
    return WorkspaceTerminalSessionState(
      workspaceId: workspaceId,
      state: state,
      durable: map['durable'] == true,
      autoStarted: map['autoStarted'] == true,
      attachedViews: attachedViews,
      sessionId: map['sessionId'] as String?,
      processId: map['processId'] as int?,
      exitCode: map['exitCode'] as int?,
    );
  }
}

@immutable
class WorkspaceTerminalNotificationStrings {
  const WorkspaceTerminalNotificationStrings({
    required this.channelName,
    required this.title,
    required this.text,
  });

  final String channelName;
  final String title;
  final String text;

  Map<String, String> toMap() => <String, String>{
    'channelName': channelName,
    'title': title,
    'text': text,
  };
}

abstract interface class WorkspaceTerminalPort {
  Future<WorkspaceTerminalSessionState> startSession({
    required String workspaceId,
    required String workspaceHostPath,
    required SandboxPtyLaunchSpec launchSpec,
    required bool durable,
    required bool autoStarted,
    required WorkspaceTerminalNotificationStrings notificationStrings,
  });

  Future<WorkspaceTerminalSessionState> getSessionState(String workspaceId);

  Future<WorkspaceTerminalSessionState> setDurable(
    String workspaceId,
    bool durable, {
    required WorkspaceTerminalNotificationStrings notificationStrings,
  });

  Future<void> stopSession(String workspaceId);

  Future<void> stopSessionForWorkspacePath(String workspaceHostPath);

  Future<void> stopAutoSessionIfDetached(String workspaceId);

  Future<void> stopAllSessions();
}

/// Android bridge for the process-owned terminal service.
///
/// The channel remains deliberately thin: session policy lives in
/// [WorkspaceTerminalCoordinator], while Android owns the PTY and emulator.
class WorkspaceTerminalNativeBridge implements WorkspaceTerminalPort {
  WorkspaceTerminalNativeBridge({
    this._channel = const MethodChannel('cuplivo/workspace_terminal'),
    bool Function()? androidProbe,
  }) : _androidProbe = androidProbe ?? (() => Platform.isAndroid);

  static final WorkspaceTerminalNativeBridge instance =
      WorkspaceTerminalNativeBridge();

  static const Duration stopTimeout = Duration(seconds: 8);

  final MethodChannel _channel;
  final bool Function() _androidProbe;

  void _requireAndroid() {
    if (!_androidProbe()) {
      throw UnsupportedError('Workspace terminal is Android-only');
    }
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
    _requireAndroid();
    final raw = await _channel
        .invokeMethod<Map<Object?, Object?>>('startSession', <String, Object?>{
          'workspaceId': workspaceId,
          'workspaceHostPath': workspaceHostPath,
          'executable': launchSpec.executable,
          'arguments': launchSpec.arguments,
          'environment': launchSpec.environment,
          'workingDirectory': launchSpec.workingDirectory,
          'durable': durable,
          'autoStarted': autoStarted,
          'notification': notificationStrings.toMap(),
        });
    return WorkspaceTerminalSessionState.fromMap(workspaceId, raw);
  }

  @override
  Future<WorkspaceTerminalSessionState> getSessionState(
    String workspaceId,
  ) async {
    if (!_androidProbe()) {
      return WorkspaceTerminalSessionState.absent(workspaceId);
    }
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
      'getSessionState',
      <String, Object?>{'workspaceId': workspaceId},
    );
    return WorkspaceTerminalSessionState.fromMap(workspaceId, raw);
  }

  @override
  Future<WorkspaceTerminalSessionState> setDurable(
    String workspaceId,
    bool durable, {
    required WorkspaceTerminalNotificationStrings notificationStrings,
  }) async {
    _requireAndroid();
    final raw = await _channel
        .invokeMethod<Map<Object?, Object?>>('setDurable', <String, Object?>{
          'workspaceId': workspaceId,
          'durable': durable,
          'notification': notificationStrings.toMap(),
        });
    return WorkspaceTerminalSessionState.fromMap(workspaceId, raw);
  }

  @override
  Future<void> stopSession(String workspaceId) async {
    if (!_androidProbe()) return;
    await _channel
        .invokeMethod<void>('stopSession', <String, Object?>{
          'workspaceId': workspaceId,
        })
        .timeout(stopTimeout);
  }

  @override
  Future<void> stopSessionForWorkspacePath(String workspaceHostPath) async {
    if (!_androidProbe()) return;
    await _channel
        .invokeMethod<void>('stopSessionForWorkspacePath', <String, Object?>{
          'workspaceHostPath': workspaceHostPath,
        })
        .timeout(stopTimeout);
  }

  @override
  Future<void> stopAutoSessionIfDetached(String workspaceId) async {
    if (!_androidProbe()) return;
    await _channel
        .invokeMethod<void>('stopAutoSessionIfDetached', <String, Object?>{
          'workspaceId': workspaceId,
        })
        .timeout(stopTimeout);
  }

  @override
  Future<void> stopAllSessions() async {
    if (!_androidProbe()) return;
    await _channel.invokeMethod<void>('stopAllSessions').timeout(stopTimeout);
  }
}
