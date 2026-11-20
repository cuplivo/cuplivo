import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:Cuplivo/features/harness/pages/terminal/dsh_terminal_page.dart';
import 'package:Cuplivo/features/harness/state/dsh_connections_provider.dart';
import 'package:Cuplivo/features/harness/widgets/terminal/dsh_terminal_launcher.dart';
import 'package:Cuplivo/features/workspace/terminal/widgets/terminal_surface.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';
import 'package:Cuplivo/shared/widgets/ios_tile_button.dart';
import 'package:Cuplivo/shared/widgets/section_card.dart';
import 'package:Cuplivo/shared/widgets/snackbar.dart';

/// The session's remote terminal, rendered inline in the right rail.
///
/// A thin host over [TerminalSurface]: it resolves the DSH gateway from the
/// connections provider, opens one terminal on the session's workspace (an
/// interactive PTY when the Host reports `writable:true`, a visible read-only
/// surface otherwise), and offers a full-screen route. The full-screen route
/// mounts the shared [TerminalPage] with the same runtime, so local and remote
/// terminals share the emulator, key bar and overflow menu.
class DshTerminalPanel extends StatefulWidget {
  const DshTerminalPanel({
    super.key,
    required this.remoteId,
    required this.sessionId,
    this.title,
  });

  static const Key panelKey = ValueKey<String>('dsh-terminal-panel');
  static const Key viewKey = ValueKey<String>('dsh-terminal-view');
  static const Key expandKey = ValueKey<String>('dsh-terminal-expand');
  static const Key unavailableKey = ValueKey<String>(
    'dsh-terminal-unavailable',
  );
  static const Key headerKey = ValueKey<String>('dsh-terminal-header');

  /// The DSH remote (assistant) whose link serves the terminal.
  final String remoteId;

  /// The Host session whose workspace anchors the terminal.
  final String sessionId;

  /// Optional display title; defaults to the Host-reported shell title.
  final String? title;

  @override
  State<DshTerminalPanel> createState() => _DshTerminalPanelState();
}

class _DshTerminalPanelState extends State<DshTerminalPanel> {
  DshTerminalLaunch? _launch;
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
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _starting = true;
    });
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
      setState(() {
        _launch = launch;
        _starting = false;
      });
    } on Object catch (_) {
      if (!mounted) return;
      setState(() {
        _starting = false;
      });
    }
  }

  Future<void> _openFullScreen() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => DshTerminalPage(
          remoteId: widget.remoteId,
          sessionId: widget.sessionId,
          title: widget.title,
        ),
      ),
    );
  }

  Future<void> _openUrl(Uri uri) async {
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        if (!mounted) return;
        showAppSnackBar(context, message: uri.toString());
        return;
      }
      return;
    }
    if (!mounted) return;
    showAppSnackBar(
      context,
      message: AppLocalizations.of(context)!.terminalNotAvailable,
    );
  }

  @override
  Widget build(BuildContext context) {
    final launch = _launch;
    if (launch == null) {
      return KeyedSubtree(
        key: DshTerminalPanel.panelKey,
        child: _starting
            ? const Center(child: CircularProgressIndicator())
            : _UnavailableTerminal(onRetry: _start),
      );
    }
    return KeyedSubtree(
      key: DshTerminalPanel.panelKey,
      child: AnimatedBuilder(
        animation: Listenable.merge(<Listenable>[
          launch.manager,
          if (launch.pty != null) launch.pty!.info,
        ]),
        builder: (context, _) {
          final l10n = AppLocalizations.of(context)!;
          final cs = Theme.of(context).colorScheme;
          final info = launch.pty?.info.value;
          final shellTitle = widget.title?.trim();
          final title = (shellTitle != null && shellTitle.isNotEmpty)
              ? shellTitle
              : (info?.title.trim().isNotEmpty ?? false)
              ? info!.title
              : l10n.terminalTitle;
          final cwd = launch.environment.cwd ?? launch.session.cwd;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                key: DshTerminalPanel.headerKey,
                padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
                child: Row(
                  children: [
                    Icon(
                      Lucide.SquareTerminal,
                      size: 16,
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface,
                            ),
                          ),
                          Text(
                            cwd,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurface.withValues(alpha: 0.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Tooltip(
                      message: l10n.dshRailExpand,
                      child: IosIconButton(
                        key: DshTerminalPanel.expandKey,
                        icon: Lucide.Maximize2,
                        size: 17,
                        minSize: 34,
                        semanticLabel: l10n.dshRailExpand,
                        onTap: () => unawaited(_openFullScreen()),
                      ),
                    ),
                  ],
                ),
              ),
              Divider(
                height: 0.6,
                thickness: 0.6,
                color: cs.outlineVariant.withValues(alpha: 0.18),
              ),
              Expanded(
                child: TerminalSurface(
                  manager: launch.manager,
                  session: launch.session,
                  supportsPty: true,
                  hostDir: cwd,
                  showTabStrip: false,
                  viewKey: DshTerminalPanel.viewKey,
                  onOpenUrl: (_, uri) => _openUrl(uri),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _UnavailableTerminal extends StatelessWidget {
  const _UnavailableTerminal({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return KeyedSubtree(
      key: DshTerminalPanel.unavailableKey,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: SectionCard(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Lucide.SquareTerminal,
                  size: 28,
                  color: cs.onSurface.withValues(alpha: 0.3),
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.dshTerminalUnavailable,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.dshTerminalUnavailableHint,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 14),
                IosTileButton(
                  icon: Lucide.RotateCw,
                  label: l10n.workspacePreviewRetry,
                  onTap: onRetry,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
