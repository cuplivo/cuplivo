import 'dart:async';

import 'package:Cuplivo/core/dsh/dsh_terminal.dart';
import 'package:Cuplivo/features/harness/services/dsh_terminal_runtime.dart';
import 'package:Cuplivo/features/harness/state/dsh_gateway.dart';
import 'package:Cuplivo/features/workspace/terminal/terminal_session_manager.dart';

/// Why a DSH terminal surface could not start.
enum DshTerminalLaunchFailure { noGateway, noRuntime, failed }

/// Thrown by [launchDshTerminal]; the panel maps it to its honest state.
class DshTerminalLaunchException implements Exception {
  const DshTerminalLaunchException(this.failure, {this.cause});

  final DshTerminalLaunchFailure failure;
  final Object? cause;
}

/// One opened remote terminal plus the manager that owns it.
///
/// Shared by the rail panel and the full-screen harness terminal so both start
/// a terminal the same way: a [DshWorkspaceRuntime] over the session's
/// `terminal/*` endpoints, an environment read for the cwd, then one
/// [TerminalSessionManager.open] (which attaches and wires OSC 1337, key input
/// and wakelock exactly like the local terminal).
class DshTerminalLaunch {
  DshTerminalLaunch._({
    required this.runtime,
    required this.environment,
    required this.manager,
    required this.session,
    required this.pty,
  });

  final DshWorkspaceRuntime runtime;
  final DshTerminalEnvironment environment;
  final TerminalSessionManager manager;
  final TerminalSession session;

  /// The typed PTY when the gateway returned the expected implementation.
  final DshPtySession? pty;

  bool _listening = false;

  /// Mirrors the Host's `writable` flag onto [TerminalSession.readOnly] so the
  /// surface hides the key bar for a read-only attachment.
  void bindReadOnly() {
    if (_listening) return;
    _listening = true;
    final value = pty;
    if (value == null) return;
    value.writable.addListener(_applyReadOnly);
    _applyReadOnly();
  }

  void _applyReadOnly() {
    final value = pty;
    if (value == null) return;
    final next = !value.writable.value;
    if (session.readOnly == next) return;
    session.readOnly = next;
    session.notify();
  }

  Future<void> dispose() async {
    if (_listening) {
      pty?.writable.removeListener(_applyReadOnly);
      _listening = false;
    }
    await manager.closeAll();
    await runtime.closeCreatedTerminals();
    manager.dispose();
  }
}

/// Opens one terminal on [sessionId] through [gateway].
///
/// Throws [DshTerminalLaunchException] when the link has no terminal adapter or
/// the Host refuses the create/attach; callers render the unavailable state.
Future<DshTerminalLaunch> launchDshTerminal({
  required DshGateway? gateway,
  required String sessionId,
  String? title,
}) async {
  if (gateway == null) {
    throw const DshTerminalLaunchException(
      DshTerminalLaunchFailure.noGateway,
      cause: 'the remote is not connected',
    );
  }
  if (gateway is! DshTerminalRuntimeHost) {
    throw const DshTerminalLaunchException(
      DshTerminalLaunchFailure.noGateway,
      cause: 'this gateway has no terminal adapter',
    );
  }
  final runtime = gateway.terminalRuntimeFor(sessionId);
  if (runtime == null) {
    throw const DshTerminalLaunchException(
      DshTerminalLaunchFailure.noRuntime,
      cause: 'no live session handle',
    );
  }
  TerminalSessionManager? manager;
  try {
    final environment = await runtime.environment();
    final created = TerminalSessionManager();
    manager = created;
    final cwd = environment.cwd ?? '/';
    final session = await created.open(
      runtime: runtime,
      mounts: const [],
      cwd: cwd,
      title: title,
      hostDir: cwd,
    );
    final pty = session.pty is DshPtySession
        ? session.pty as DshPtySession
        : null;
    final launch = DshTerminalLaunch._(
      runtime: runtime,
      environment: environment,
      manager: created,
      session: session,
      pty: pty,
    );
    launch.bindReadOnly();
    return launch;
  } catch (error) {
    // A failed attach must not leave a Host-side terminal or a local manager
    // behind: `closeCreatedTerminals` reaps anything already created.
    await manager?.closeAll();
    manager?.dispose();
    await runtime.closeCreatedTerminals();
    throw DshTerminalLaunchException(
      DshTerminalLaunchFailure.failed,
      cause: error,
    );
  }
}
