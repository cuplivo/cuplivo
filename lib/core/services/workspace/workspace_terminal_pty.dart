import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';

import 'linux_sandbox_service.dart';
import 'workspace_terminal_session.dart';

class WorkspaceTerminalSession implements WorkspaceTerminalSessionPort {
  Pty? _pty;
  StreamController<List<int>>? _output;
  StreamSubscription<Uint8List>? _outSub;
  Future<void> _inflight = Future<void>.value();

  Future<void> _enqueue(Future<void> Function() op) {
    final previous = _inflight;
    final gate = Completer<void>();
    _inflight = gate.future;
    return () async {
      try {
        await previous;
        await op();
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    }();
  }

  @override
  Future<void> start(
    SandboxPtyLaunchSpec spec, {
    required int rows,
    required int columns,
  }) {
    return _enqueue(() async {
      await _closeUnlocked();
      final output = StreamController<List<int>>();
      final env = <String, String>{
        ...Platform.environment,
        ...spec.environment,
      };
      debugPrint(
        'WorkspaceTerminalSession.start exe=${spec.executable} '
        'cwd=${spec.workingDirectory} rows=$rows cols=$columns',
      );
      try {
        final pty = Pty.start(
          spec.executable,
          arguments: spec.arguments,
          environment: env,
          workingDirectory: spec.workingDirectory,
          rows: rows,
          columns: columns,
        );
        _output = output;
        _pty = pty;
        _outSub = pty.output.listen(
          output.add,
          onError: (Object e, StackTrace st) {
            debugPrint('WorkspaceTerminalSession.output: $e');
            if (!output.isClosed) output.addError(e, st);
          },
          onDone: () {
            if (!output.isClosed) unawaited(output.close());
          },
        );
      } catch (e) {
        debugPrint('WorkspaceTerminalSession.start failed: $e');
        if (!output.isClosed) await output.close();
        _output = null;
        _pty = null;
        _outSub = null;
        rethrow;
      }
    });
  }

  @override
  void write(List<int> data) {
    final pty = _pty;
    if (pty == null) return;
    pty.write(Uint8List.fromList(data));
  }

  @override
  void resize({required int rows, required int columns}) {
    _pty?.resize(rows, columns);
  }

  @override
  Stream<List<int>> get output =>
      _output?.stream ?? const Stream<List<int>>.empty();

  @override
  Future<int> get exitCode {
    final pty = _pty;
    if (pty == null) return Future<int>.value(-1);
    return pty.exitCode;
  }

  @override
  Future<void> close() => _enqueue(_closeUnlocked);

  Future<void> _closeUnlocked() async {
    final pty = _pty;
    _pty = null;
    await _outSub?.cancel();
    _outSub = null;
    final output = _output;
    _output = null;
    if (pty != null) {
      try {
        pty.kill();
      } catch (e) {
        debugPrint('WorkspaceTerminalSession.kill: $e');
      }
    }
    if (output != null && !output.isClosed) {
      await output.close();
    }
  }
}
