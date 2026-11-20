import 'dart:async';

import 'package:flutter/material.dart';

import 'package:Cuplivo/features/harness/models/dsh_remote.dart';
import 'package:Cuplivo/features/harness/widgets/dsh_web_ui_view.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';

export 'package:Cuplivo/features/harness/widgets/dsh_web_ui_view.dart'
    show DshPluginWebFailure, DshWebUiScriptMessageCallback, DshWebViewCookie;

/// The plugin/web panel host: a Cuplivo page that shows the Host's *own* Web UI.
///
/// The page is deliberately thin: the embedded view ([DshWebUiView]) owns the
/// cookie injection, loading/failure states and the optional script result
/// channel, while this file only adds the app chrome (title, authority subtitle,
/// refresh action) and forwards the connection settings recovery callback. The
/// same view mounts inline in settings tabs and file previews, which is why the
/// extraction exists.
///
/// DSH plugins contribute React slots inside the server's single-page app; the
/// protocol has **no per-plugin URL** (verified against 0.2.2-rc.1, see
/// `docs/cuplivo-dsh/client-reference.md` §3.10). This page therefore says so
/// honestly in its header note and loads the Host origin.
///
/// The remote API cookie (`v2`) and the launch token must never be injected
/// here: browser pages only accept v1. A 401/403 from the Host means the launch
/// token/cookie rotated (`dsh web` restart) and the assistant has to be
/// reconnected.
class DshPluginWebPage extends StatefulWidget {
  const DshPluginWebPage({
    super.key,
    required this.remote,
    this.title,
    this.cookie,
    this.initialUrl,
    this.initialScript,
    this.onScriptMessage,
    this.onRequestReconnect,
  });

  final DshRemote remote;

  /// Plugin/panel display name; the header says "插件面板 · <title>".
  final String? title;

  /// Stored v1 cookie (`name=value`). Null when the remote was never logged in
  /// through the WebUI; the page then loads unauthenticated and the Host's own
  /// login page (or its 401) is shown instead of a silent blank.
  final String? cookie;

  /// Optional deep link into the Host's own UI. Defaults to [DshRemote.baseUrl].
  final Uri? initialUrl;

  /// Optional JS executed once after the first successful load.
  final String? initialScript;

  /// Receives the string payload of any `CuplivoHost` JS → Dart message the
  /// optional landing/harvest script posts (the generic surface-harvest bridge
  /// passes its result object here).
  final DshWebUiScriptMessageCallback? onScriptMessage;

  /// Opens the assistant's connect settings so the user can paste a fresh
  /// WebUI link (401 recovery). Null hides the action; retry stays available.
  final VoidCallback? onRequestReconnect;

  @override
  State<DshPluginWebPage> createState() => _DshPluginWebPageState();
}

class _DshPluginWebPageState extends State<DshPluginWebPage> {
  final GlobalKey<DshWebUiViewState> _webKey = GlobalKey<DshWebUiViewState>();
  DshPluginWebFailure? _failure;

  void _onFailureChanged(DshPluginWebFailure? failure) {
    if (!mounted || identical(_failure, failure)) return;
    setState(() => _failure = failure);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final title = (widget.title ?? '').trim();
    final showRefresh = DshWebUiView.isPlatformSupported && _failure == null;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title.isEmpty
                  ? l10n.dshPluginPanelTitle
                  : '${l10n.dshPluginPanelTitle} · $title',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16),
            ),
            Text(
              widget.remote.authority,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: AppFontWeights.regular,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
        actions: [
          if (showRefresh)
            IosIconButton(
              icon: Lucide.RefreshCw,
              tooltip: l10n.retry,
              semanticLabel: l10n.retry,
              minSize: 44,
              onTap: () => unawaited(_webKey.currentState?.reload()),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: DshWebUiView(
          key: _webKey,
          remote: widget.remote,
          cookie: widget.cookie,
          initialUrl: widget.initialUrl,
          initialScript: widget.initialScript,
          onScriptMessage: widget.onScriptMessage,
          onRequestReconnect: widget.onRequestReconnect,
          onFailureChanged: _onFailureChanged,
        ),
      ),
    );
  }
}
