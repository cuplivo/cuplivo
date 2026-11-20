import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/services/workspace/workspace_runtime.dart';
import 'package:Cuplivo/features/harness/state/dsh_connections_provider.dart';
import 'package:Cuplivo/features/harness/widgets/terminal/dsh_terminal_launcher.dart';
import 'package:Cuplivo/features/workspace/terminal/terminal_page.dart';
import 'package:Cuplivo/features/workspace/terminal/terminal_session_manager.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

/// Full-screen terminal for one DSH session.
///
/// Mounts the shared [TerminalPage] with the remote [DshWorkspaceRuntime]
/// registered in a page-local [WorkspaceRuntimeProvider], so the local terminal
/// page (tabs, key bar, overflow menu) works unchanged against the Host. The
/// terminal is created here rather than by the page because the page only
/// auto-opens sessions added after mount; opening before mount keeps the first
/// frame from flashing the system-terminal fallback.
class DshTerminalPage extends StatefulWidget {
  const DshTerminalPage({
    super.key,
    required this.remoteId,
    required this.sessionId,
    this.title,
  });

  static const Key pageKey = ValueKey<String>('dsh-terminal-page');

  final String remoteId;
  final String sessionId;
  final String? title;

  @override
  State<DshTerminalPage> createState() => _DshTerminalPageState();
}

class _DshTerminalPageState extends State<DshTerminalPage> {
  DshTerminalLaunch? _launch;
  WorkspaceRuntimeProvider? _runtimeProvider;
  bool _starting = true;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    final launch = _launch;
    _launch = null;
    if (launch != null) unawaited(launch.dispose());
    _runtimeProvider?.dispose();
    _runtimeProvider = null;
    super.dispose();
  }

  Future<void> _start() async {
    final connections = context.read<DshConnectionsProvider?>();
    final gateway = connections?.gatewayFor(widget.remoteId);
    try {
      final launch = await launchDshTerminal(
        gateway: gateway,
        sessionId: widget.sessionId,
        title: widget.title,
      );
      if (!mounted) {
        await launch.dispose();
        return;
      }
      final runtimeProvider = WorkspaceRuntimeProvider()
        ..register(launch.runtime);
      setState(() {
        _launch = launch;
        _runtimeProvider = runtimeProvider;
        _starting = false;
      });
    } on Object catch (_) {
      if (!mounted) return;
      setState(() {
        _starting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final launch = _launch;
    final runtimeProvider = _runtimeProvider;
    final l10n = AppLocalizations.of(context)!;
    if (launch == null || runtimeProvider == null) {
      final cs = Theme.of(context).colorScheme;
      return Scaffold(
        key: DshTerminalPage.pageKey,
        backgroundColor: cs.surface,
        appBar: AppBar(title: Text(widget.title ?? l10n.terminalTitle)),
        body: Center(
          child: _starting
              ? const CircularProgressIndicator()
              : Text(
                  l10n.dshTerminalUnavailable,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
        ),
      );
    }
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<TerminalSessionManager>.value(
          value: launch.manager,
        ),
        ChangeNotifierProvider<WorkspaceRuntimeProvider>.value(
          value: runtimeProvider,
        ),
      ],
      child: KeyedSubtree(
        key: DshTerminalPage.pageKey,
        child: TerminalPage(
          cwd: launch.environment.cwd ?? launch.session.cwd,
          hostDir: launch.environment.cwd ?? launch.session.cwd,
          title: widget.title,
          initialSessionId: launch.session.id,
        ),
      ),
    );
  }
}
