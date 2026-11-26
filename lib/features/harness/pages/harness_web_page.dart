import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/services/harness/harness_tailcat_dialer.dart';
import '../../../core/services/harness/harness_tailcat_tunnels.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/ios_text_button.dart';
import '../../../theme/app_font_weights.dart';
import '../widgets/harness_status.dart';
import '../widgets/harness_web_view.dart';

/// The remote DeepSeek Harness, embedded.
///
/// The page is deliberately thin: the instance runs its own WebUI, which owns
/// everything below the bar. Cuplivo adds only the return bar and the platform
/// fallbacks inside [HarnessWebView], so the remote product and this app cannot
/// drift into two half-copies of one screen.
///
/// A public-link harness loads its launch link directly. A tailcat harness
/// cannot: the WebView speaks HTTP, not tailnet, so that mode first has to open
/// the tunnel ([_TailcatHarnessView]) and loads its loopback origin instead.
class HarnessWebPage extends StatelessWidget {
  const HarnessWebPage({super.key, required this.assistantId});

  final String assistantId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final assistant = context.watch<AssistantProvider>().getById(assistantId);
    if (assistant == null || !assistant.hasHarnessConnection) {
      // Deleted underneath the page (or opened with no credential): there is
      // nothing to show. Leave on the next frame rather than keep a dead page.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.of(context).maybePop();
      });
      return const Scaffold(body: SizedBox.shrink());
    }

    return Scaffold(
      key: const Key('harness-web-page'),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: false,
        leading: IosIconButton(
          key: const Key('harness-return-button'),
          icon: Lucide.ArrowLeft,
          size: 22,
          minSize: 44,
          tooltip: l10n.settingsPageBackButton,
          semanticLabel: l10n.settingsPageBackButton,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        titleSpacing: 2,
        title: Text(
          assistant.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 16, fontWeight: AppFontWeights.medium),
        ),
      ),
      body: switch (assistant.harnessConnectionMode) {
        HarnessConnectionMode.publicLink => HarnessWebView(
          url: assistant.harnessUrl!.trim(),
        ),
        HarnessConnectionMode.tailcat => _TailcatHarnessView(
          assistant: assistant,
        ),
      },
    );
  }
}

/// The WebUI of a tailcat-connected harness: open the tunnel, then embed the
/// loopback origin it serves.
///
/// The tunnel is owned by [HarnessTailcatTunnels], not by this widget: the
/// settings page already proved the connection through the same tunnel, so
/// normally this is instant and the page never shows the progress state. The
/// states below exist for the open-from-list path and for a tunnel that broke
/// while the app was in the background.
class _TailcatHarnessView extends StatefulWidget {
  const _TailcatHarnessView({required this.assistant});

  final Assistant assistant;

  @override
  State<_TailcatHarnessView> createState() => _TailcatHarnessViewState();
}

class _TailcatHarnessViewState extends State<_TailcatHarnessView> {
  Uri? _origin;
  Object? _error;
  String? _openedFor;

  /// Bumped on every attempt so a late answer from an abandoned tunnel (the
  /// credential changed, or the user retried) cannot repaint the page.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _openTunnel();
  }

  @override
  void didUpdateWidget(covariant _TailcatHarnessView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The assistant's credential changed underneath the page (the settings page
    // can only be reached by leaving this one, but a sync restore may replace
    // the row): follow it instead of keeping a tunnel to the old peer.
    if (_keyOf(oldWidget.assistant) != _keyOf(widget.assistant)) {
      _openTunnel(force: true);
    }
  }

  String _keyOf(Assistant assistant) =>
      '${assistant.harnessTailcatAddress}|${assistant.harnessTailcatPort}';

  void _openTunnel({bool force = false}) {
    final address = widget.assistant.harnessTailcatAddress?.trim() ?? '';
    if (address.isEmpty) return;
    final key = _keyOf(widget.assistant);
    if (!force && _openedFor == key) return;
    _openedFor = key;
    _origin = null;
    _error = null;
    final generation = ++_generation;
    unawaited(
      _runTunnel(generation, address, widget.assistant.harnessTailcatPort),
    );
  }

  /// Owns the tunnel future's answer from the moment it exists.
  ///
  /// A `FutureBuilder` only subscribes on the next build, so an error that
  /// arrives first is an unhandled async error; a retry starts its future from
  /// a tap handler, which is exactly that window. This keeps the answer in
  /// state instead, where a stale generation is simply dropped.
  Future<void> _runTunnel(int generation, String address, int port) async {
    try {
      final origin = await context.read<HarnessTailcatTunnels>().ensureOpen(
        address,
        remotePort: port,
      );
      if (!mounted || generation != _generation) return;
      setState(() => _origin = origin);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = error);
    }
  }

  void _retry() => setState(() => _openTunnel(force: true));

  @override
  Widget build(BuildContext context) {
    if (_openedFor == null) {
      // Only reachable while the assistant's address is being removed; the page
      // above pops on the same notification.
      return const SizedBox.shrink();
    }
    final error = _error;
    if (error != null) {
      return _TunnelFailureView(error: error, onRetry: _retry);
    }
    final origin = _origin;
    if (origin == null) return const _TunnelOpeningView();
    return HarnessWebView(url: origin.toString());
  }
}

/// The tunnel handshake is a DERP round trip and possibly NAT traversal; on a
/// cold start that is long enough to need a sentence, not only a spinner.
class _TunnelOpeningView extends StatelessWidget {
  const _TunnelOpeningView();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      key: const Key('harness-tailcat-opening'),
      children: [
        const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: HarnessStatus(
            icon: Lucide.Loader,
            title: l10n.assistantHarnessTailcatOpening,
            actions: const <Widget>[],
          ),
        ),
      ],
    );
  }
}

class _TunnelFailureView extends StatelessWidget {
  const _TunnelFailureView({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return HarnessStatus(
      key: const Key('harness-tailcat-error'),
      icon: Lucide.CloudOff,
      title: _message(l10n),
      actions: [
        IosTextButton(
          key: const Key('harness-tailcat-retry'),
          label: l10n.assistantHarnessRetry,
          icon: Lucide.RotateCw,
          onPressed: onRetry,
        ),
      ],
    );
  }

  String _message(AppLocalizations l10n) {
    if (error is HarnessTailcatTunnelException) {
      return switch ((error as HarnessTailcatTunnelException).failure) {
        HarnessTailcatTunnelFailure.invalidAddress =>
          l10n.assistantHarnessTailcatInvalidAddress,
        HarnessTailcatTunnelFailure.unsupportedPlatform =>
          l10n.assistantHarnessTailcatUnsupported,
        HarnessTailcatTunnelFailure.tunnelUnavailable =>
          l10n.assistantHarnessTailcatUnavailable,
      };
    }
    return l10n.assistantHarnessTailcatUnavailable;
  }
}
