import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:Cuplivo/core/services/browser/browser_windows_environment.dart';
import 'package:Cuplivo/features/harness/models/dsh_remote.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';
import 'package:Cuplivo/shared/widgets/section_card.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

/// The stored DSH v1 browser cookie, split into the `name=value` pair the
/// WebView cookie jar needs.
///
/// The credential store keeps the cookie string from the login response; the
/// bound `authority`/`secure` live on [DshRemote], so attributes are taken from
/// the record rather than re-parsed from the (possibly truncated) string.
@immutable
class DshWebViewCookie {
  const DshWebViewCookie({required this.name, required this.value});

  final String name;
  final String value;

  /// Parses `dsh-auth-…=v1.…` (attributes after `;` are ignored).
  static DshWebViewCookie? parse(String? raw) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty) return null;
    final pair = text.split(';').first.trim();
    final separator = pair.indexOf('=');
    if (separator <= 0 || separator == pair.length - 1) return null;
    final name = pair.substring(0, separator).trim();
    final value = pair.substring(separator + 1).trim();
    if (name.isEmpty || value.isEmpty) return null;
    return DshWebViewCookie(name: name, value: value);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshWebViewCookie && other.name == name && other.value == value;

  @override
  int get hashCode => Object.hash(name, value);

  /// The name is not a secret; the value never appears in `toString`.
  @override
  String toString() => 'DshWebViewCookie($name)';
}

enum DshPluginWebFailure { unsupported, unauthorized, network }

/// The plugin/web panel host: a Cuplivo page that shows the Host's *own* Web UI.
///
/// DSH plugins contribute React slots inside the server's single-page app; the
/// protocol has **no per-plugin URL** (verified against 0.2.2-rc.1, see
/// `docs/cuplivo-dsh/client-reference.md` §3.10). This page therefore says so
/// honestly in its header and loads `http(s)://<authority>/` — the whole WebUI —
/// authenticated by the stored v1 browser cookie injected into the WebView jar.
///
/// The remote API cookie (`v2`) must never be injected here: browser pages only
/// accept v1. A 401/403 from the Host means the launch token/cookie rotated
/// (`dsh web` restart) and the assistant has to be reconnected.
class DshPluginWebPage extends StatefulWidget {
  const DshPluginWebPage({
    super.key,
    required this.remote,
    this.title,
    this.cookie,
    this.initialScript,
    this.onRequestReconnect,
  });

  final DshRemote remote;

  /// Plugin/panel display name; the header says "插件面板 · <title>".
  final String? title;

  /// Stored v1 cookie (`name=value`). Null when the remote was never logged in
  /// through the WebUI; the page then loads unauthenticated and the Host's own
  /// login page (or its 401) is shown instead of a silent blank.
  final String? cookie;

  /// Optional JS executed once after the first successful load.
  ///
  /// A hidden extension point for a future "deep landing" into one plugin
  /// panel. Deliberately not used by the shipped surface: DSH has no stable DOM
  /// contract for panels, so guessing selectors here would be brittle. Omitted
  /// (null) is the normal state.
  final String? initialScript;

  /// Opens the assistant's connect settings so the user can paste a fresh
  /// WebUI link (401 recovery). Null hides the action; retry stays available.
  final VoidCallback? onRequestReconnect;

  @override
  State<DshPluginWebPage> createState() => _DshPluginWebPageState();
}

class _DshPluginWebPageState extends State<DshPluginWebPage> {
  InAppWebViewController? _controller;
  WebViewEnvironment? _environment;
  bool _preparing = true;
  bool _loading = true;
  DshPluginWebFailure? _failure;
  int _generation = 0;
  bool _initialScriptRun = false;

  bool get _platformSupported =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isMacOS ||
          Platform.isWindows);

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    if (!_platformSupported) {
      setState(() {
        _preparing = false;
        _failure = DshPluginWebFailure.unsupported;
      });
      return;
    }
    if (Platform.isWindows) {
      try {
        _environment = await BrowserWindowsEnvironment.instance.get();
      } catch (_) {
        // A failed WebView2 environment falls back to the plugin default; the
        // page load then reports its own network error instead of blocking the
        // page behind a profile failure.
        _environment = null;
      }
    }
    await _injectCookie();
    if (!mounted) return;
    setState(() => _preparing = false);
  }

  /// Injects the stored cookie before the first navigation.
  ///
  /// Domain is left host-only for IP literals: `Domain=127.0.0.1` is rejected
  /// by WebKit/WebView2, while a host-only cookie set for the URL is exactly
  /// what DSH's own login would have produced for an IP authority.
  Future<void> _injectCookie() async {
    final cookie = DshWebViewCookie.parse(widget.cookie);
    if (cookie == null) return;
    final base = widget.remote.uri;
    final host = base.host;
    try {
      await CookieManager.instance(webViewEnvironment: _environment).setCookie(
        url: WebUri('${base.scheme}://${base.authority}/'),
        name: cookie.name,
        value: cookie.value,
        domain: _isIpLiteral(host) ? null : host,
        path: '/',
        isSecure: widget.remote.secure,
        isHttpOnly: true,
        sameSite: HTTPCookieSameSitePolicy.STRICT,
      );
    } catch (_) {
      // Injection is best-effort: a jar that refuses the write still gets the
      // Host's login page, which is an honest state, not a crash.
    }
  }

  static bool _isIpLiteral(String host) =>
      host.contains(':') || RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host);

  Future<void> _retry() async {
    setState(() {
      _failure = null;
      _loading = true;
      _initialScriptRun = false;
      // A fresh key rebuilds the native view; retry never reuses a document that
      // already answered 401/403 from the WebView's own cache.
      _generation += 1;
    });
    await _injectCookie();
  }

  void _onLoadStart(InAppWebViewController controller, WebUri? url) {
    if (!mounted) return;
    setState(() => _loading = true);
  }

  void _onLoadStop(InAppWebViewController controller, WebUri? url) {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _failure = null;
    });
    final script = widget.initialScript?.trim() ?? '';
    if (!_initialScriptRun && script.isNotEmpty) {
      _initialScriptRun = true;
      unawaited(
        controller.evaluateJavascript(source: script).catchError((Object _) {}),
      );
    }
  }

  void _onReceivedError(
    InAppWebViewController controller,
    WebResourceRequest request,
    WebResourceError error,
  ) {
    if (!mounted || request.isForMainFrame != true) return;
    if (error.type == WebResourceErrorType.CANCELLED) return;
    setState(() {
      _loading = false;
      _failure = DshPluginWebFailure.network;
    });
  }

  void _onReceivedHttpError(
    InAppWebViewController controller,
    WebResourceRequest request,
    WebResourceResponse response,
  ) {
    if (!mounted || request.isForMainFrame != true) return;
    final status = response.statusCode ?? 0;
    if (status == 401 || status == 403) {
      setState(() {
        _loading = false;
        _failure = DshPluginWebFailure.unauthorized;
      });
    } else if (status >= 500) {
      setState(() {
        _loading = false;
        _failure = DshPluginWebFailure.network;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final title = (widget.title ?? '').trim();
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
          if (_platformSupported && _failure == null)
            IosIconButton(
              icon: Lucide.RefreshCw,
              tooltip: l10n.retry,
              semanticLabel: l10n.retry,
              minSize: 44,
              onTap: () => unawaited(_reload()),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            const _DshWebHonestyNote(),
            Expanded(child: _buildBody(context)),
          ],
        ),
      ),
    );
  }

  Future<void> _reload() async {
    final controller = _controller;
    if (controller == null) {
      await _retry();
      return;
    }
    setState(() => _loading = true);
    await _injectCookie();
    await controller.reload();
  }

  Widget _buildBody(BuildContext context) {
    if (_preparing) {
      return _DshWebCenteredState(
        icon: Lucide.Globe,
        title: AppLocalizations.of(context)!.dshWebPanelLoading,
      );
    }
    final failure = _failure;
    if (failure != null) {
      return _buildFailure(context, failure);
    }
    return Stack(
      children: [
        InAppWebView(
          key: ValueKey<int>(_generation),
          webViewEnvironment: _environment,
          initialUrlRequest: URLRequest(url: WebUri(widget.remote.baseUrl)),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            thirdPartyCookiesEnabled: true,
            transparentBackground: false,
            supportZoom: false,
            isInspectable: kDebugMode,
          ),
          onWebViewCreated: (controller) => _controller = controller,
          onLoadStart: _onLoadStart,
          onLoadStop: _onLoadStop,
          onReceivedError: _onReceivedError,
          onReceivedHttpError: _onReceivedHttpError,
        ),
        if (_loading)
          Positioned.fill(
            child: ColoredBox(
              color: Theme.of(
                context,
              ).colorScheme.surface.withValues(alpha: 0.55),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    AppLocalizations.of(context)!.dshWebPanelLoading,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.65),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildFailure(BuildContext context, DshPluginWebFailure failure) {
    final l10n = AppLocalizations.of(context)!;
    final (icon, title, body) = switch (failure) {
      DshPluginWebFailure.unsupported => (
        Lucide.Globe,
        l10n.dshWebPanelUnsupportedTitle,
        l10n.dshWebPanelUnsupportedBody,
      ),
      DshPluginWebFailure.unauthorized => (
        Lucide.Lock,
        l10n.dshWebPanelUnauthorizedTitle,
        l10n.dshWebPanelUnauthorizedBody,
      ),
      DshPluginWebFailure.network => (
        Lucide.TriangleAlert,
        l10n.dshWebPanelNetworkTitle,
        l10n.dshWebPanelNetworkBody,
      ),
    };
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SectionCard(
            radius: 16,
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 34,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.4),
                ),
                const SizedBox(height: 12),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: AppFontWeights.semibold,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.65),
                  ),
                ),
                if (failure != DshPluginWebFailure.unsupported) ...[
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton(
                        onPressed: () => unawaited(_retry()),
                        child: Text(l10n.retry),
                      ),
                      if (failure == DshPluginWebFailure.unauthorized &&
                          widget.onRequestReconnect != null) ...[
                        const SizedBox(width: 10),
                        FilledButton(
                          onPressed: widget.onRequestReconnect,
                          child: Text(l10n.dshWebPanelReconnect),
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One-line, always-visible explanation of what this page actually is.
class _DshWebHonestyNote extends StatelessWidget {
  const _DshWebHonestyNote();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: context.appColors.surfaceFill,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Lucide.BadgeInfo,
            size: 14,
            color: cs.onSurface.withValues(alpha: 0.5),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              AppLocalizations.of(context)!.dshWebPanelNoPluginUrl,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.35,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DshWebCenteredState extends StatelessWidget {
  const _DshWebCenteredState({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 30, color: cs.onSurface.withValues(alpha: 0.35)),
          const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}
