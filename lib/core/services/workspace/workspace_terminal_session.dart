import 'package:flutter/foundation.dart';

import 'linux_sandbox_service.dart';

abstract class WorkspaceTerminalSessionPort {
  Future<void> start(
    SandboxPtyLaunchSpec spec, {
    required int rows,
    required int columns,
  });

  void write(List<int> data);

  void resize({required int rows, required int columns});

  Stream<List<int>> get output;

  Future<int> get exitCode;

  Future<void> close();
}

class WorkspaceTerminalController {
  WorkspaceTerminalController({required this.session});

  final WorkspaceTerminalSessionPort session;
  bool closed = false;
  Future<void>? _sessionClose;

  Future<void> start(
    SandboxPtyLaunchSpec spec, {
    required int rows,
    required int columns,
  }) async {
    if (closed) {
      throw StateError('WorkspaceTerminalController is closed');
    }
    await session.start(spec, rows: rows, columns: columns);
    if (closed) {
      await _closeSession();
      throw StateError('WorkspaceTerminalController closed during start');
    }
  }

  void write(List<int> data) {
    if (closed) return;
    session.write(data);
  }

  void resize({required int rows, required int columns}) {
    if (closed) return;
    session.resize(rows: rows, columns: columns);
  }

  Stream<List<int>> get output => session.output;

  Future<int> get exitCode => session.exitCode;

  Future<void> stop() async {
    if (closed) return;
    await _closeSession();
  }

  Future<void> dispose() async {
    if (closed) return;
    closed = true;
    await _closeSession();
  }

  Future<void> _closeSession() {
    return _sessionClose ??= () async {
      try {
        await session.close();
      } catch (e) {
        debugPrint('WorkspaceTerminalController.close: $e');
      } finally {
        _sessionClose = null;
      }
    }();
  }
}
