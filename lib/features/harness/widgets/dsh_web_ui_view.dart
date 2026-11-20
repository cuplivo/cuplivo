import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:Cuplivo/core/services/browser/browser_windows_environment.dart';
import 'package:Cuplivo/features/harness/models/dsh_remote.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
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

/// How the embedded Host Web UI failed, once it is past loading.
///
/// `unsupported` is the pre-flight answer (desktop Linux, web builds); the
/// other two come from the native view itself, so a caller can show the same
/// taxonomy wherever the view is mounted (full page, settings tab, preview).
enum DshPluginWebFailure { unsupported, unauthorized, network }

/// Callback for one JS → Flutter message from the embedded Host Web UI.
///
/// The page reports through the injected `flutter_inappwebview` bridge channel
/// named by [DshWebUiView.scriptMessageHandlerName]; the payload is the first
/// handler argument converted to a string. For a landing/harvest flow the
/// script decides what to send (e.g. a JSON object with the page it landed on).
typedef DshWebUiScriptMessageCallback = void Function(String message);

/// The embedded DeepSeek Harness Web UI.
///
/// DSH plugins contribute React slots inside the server's single-page app and
/// the protocol has **no per-plugin URL** (verified against 0.2.2-rc.1, see
/// `docs/cuplivo-dsh/client-reference.md` §3.10). The view therefore always
/// loads a Host origin — the whole WebUI, or a deep link the protocol exposes
/// (`initialUrl`) — authenticated by the stored v1 browser cookie injected into
/// the WebView jar.
///
/// Deliberately not a page: it renders no Scaffold and no AppBar, so a caller
/// can host it as a full page ([DshPluginWebPage]), an inline settings panel, or
/// a file-preview surface. [showHonestyNote] says whether the one-line "this is
/// the Host's own UI" note is part of that host.
///
/// Security: the remote **API** cookie (`v2`) and the launch token must never be
/// injected here — browser pages only accept `v1`. A 401/403 from the Host means
/// the launch token/cookie rotated (`dsh web` restart) and the assistant has to
/// be reconnected; [onRequestReconnect] is the honest recovery affordance.
class DshWebUiView extends StatefulWidget {
  const DshWebUiView({
    super.key,
    required this.remote,
    this.cookie,
    this.initialUrl,
    this.initialScript,
    this.scriptMessageHandlerName = 'CuplivoHost',
    this.onScriptMessage,
    this.onRequestReconnect,
    this.onFailureChanged,
    this.showHonestyNote = true,
  });

  /// The remote whose origin/authority/cookie attributes are used.
  final DshRemote remote;

  /// Stored v1 cookie (`name=value`). Null when the remote was never logged in
  /// through the WebUI; the view then loads unauthenticated and the Host's own
  /// login page (or its 401) is shown instead of a silent blank.
  final String? cookie;

  /// First URL to load. Defaults to [DshRemote.baseUrl].
  ///
  /// A caller that has a real deep link (the Host's own UI route) passes it
  /// here; a plugin panel has no per-plugin URL, so the default whole-WebUI
  /// origin is the honest target.
  final Uri? initialUrl;

  /// One-shot JavaScript executed after the first successful load.
  ///
  /// Extension point for a future "deep landing" into a Host surface. The
  /// landing contract is deliberately best-effort: the script targets the
  /// official UI by visible/accessible label (sidebar row, rail card, settings
  /// nav text), it runs at most once per view generation, and an evaluation
  /// failure is swallowed — a landing miss must never error the page. Omitted
  /// (null) is the normal state.
  final String? initialScript;

  /// Name of the `flutter_inappwebview` JS → Dart handler the view registers.
  ///
  /// A landing/harvest script reports back with
  /// `window.flutter_inappwebview.callHandler(<name>, payload)`. The handler is
  /// only registered when [onScriptMessage] is non-null, so a page that does
  /// not need a result channel has no extra surface.
  final String scriptMessageHandlerName;

  /// Receives the string payload of every [scriptMessageHandlerName] call.
  final DshWebUiScriptMessageCallback? onScriptMessage;

  /// Opens the assistant's connect settings so the user can paste a fresh
  /// WebUI link (401 recovery). Null hides the action; retry stays available.
  final VoidCallback? onRequestReconnect;

  /// Reports the current failure (null = healthy/preparing) to a host that
  /// needs it for outer chrome (e.g. hiding a refresh AppBar action).
  final ValueChanged<DshPluginWebFailure?>? onFailureChanged;

  /// Whether the one-line honesty note above the WebView is shown.
  final bool showHonestyNote;

  /// Whether this platform can host the native WebView at all.
  static bool get isPlatformSupported =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isMacOS ||
          Platform.isWindows);

  @override
  State<DshWebUiView> createState() => DshWebUiViewState();
}

class DshWebUiViewState extends State<DshWebUiView> {
  InAppWebViewController? _controller;
  WebViewEnvironment? _environment;
  bool _preparing = true;
  bool _loading = true;
  DshPluginWebFailure? _failure;
  int _generation = 0;
  bool _initialScriptRun = false;

  Uri get _targetUrl => widget.initialUrl ?? widget.remote.uri;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  @override
  void didUpdateWidget(DshWebUiView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.remote.id != widget.remote.id ||
        oldWidget.initialUrl != widget.initialUrl ||
        oldWidget.cookie != widget.cookie) {
      unawaited(_retry());
    }
  }

  Future<void> _prepare() async {
    if (!DshWebUiView.isPlatformSupported) {
      _setFailure(DshPluginWebFailure.unsupported);
      setState(() => _preparing = false);
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

  void _setFailure(DshPluginWebFailure? failure) {
    _failure = failure;
    final callback = widget.onFailureChanged;
    if (callback == null) return;
    // The view reports failures from load callbacks *and* from didUpdateWidget;
    // a host that mirrors it into its own app-bar state must not be asked to
    // setState during a build phase.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) callback(failure);
    });
  }

  /// Loads the target URL again in a fresh native document.
  ///
  /// A generation is a new webview, so a document that answered 401/403 from
  /// the WebView cache is never reused; the failure taxonomy is unchanged from
  /// the original plugin page.
  Future<void> reload() async {
    final controller = _controller;
    if (controller == null) {
      await _retry();
      return;
    }
    setState(() => _loading = true);
    await _injectCookie();
    await controller.reload();
  }

  Future<void> _retry() async {
    setState(() {
      _setFailure(null);
      _loading = true;
      _preparing = false;
      _initialScriptRun = false;
      _generation += 1;
    });
    await _injectCookie();
  }

  void _onWebViewCreated(InAppWebViewController controller) {
    _controller = controller;
    final callback = widget.onScriptMessage;
    if (callback == null) return;
    controller.addJavaScriptHandler(
      handlerName: widget.scriptMessageHandlerName,
      callback: (arguments) {
        final payload = arguments.isEmpty ? '' : '${arguments.first}';
        callback(payload);
        return null;
      },
    );
  }

  void _onLoadStart(InAppWebViewController controller, WebUri? url) {
    if (!mounted) return;
    setState(() => _loading = true);
  }

  void _onLoadStop(InAppWebViewController controller, WebUri? url) {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _setFailure(null);
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
      _setFailure(DshPluginWebFailure.network);
    });
  }

  void _onRenderProcessGone(
    InAppWebViewController controller,
    RenderProcessGoneDetail detail,
  ) {
    // The Android WebView renderer can exit (memory pressure, a Chromium
    // crash, a WebView update). Without a handler the platform kills the app;
    // with it the page degrades to the retry state, which recreates the view.
    debugPrint(
      '[dsh-webview] renderer gone: didCrash=${detail.didCrash} '
      'priority=${detail.rendererPriorityAtExit}',
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      _setFailure(DshPluginWebFailure.network);
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
        _setFailure(DshPluginWebFailure.unauthorized);
      });
    } else if (status >= 500) {
      setState(() {
        _loading = false;
        _setFailure(DshPluginWebFailure.network);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final note = widget.showHonestyNote;
    if (!note) return _buildBody(context);
    return Column(
      children: [
        const _DshWebHonestyNote(),
        Expanded(child: _buildBody(context)),
      ],
    );
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
          initialUrlRequest: URLRequest(url: WebUri(_targetUrl.toString())),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            thirdPartyCookiesEnabled: true,
            transparentBackground: false,
            supportZoom: false,
            isInspectable: kDebugMode,
            // Android reports a dead renderer so the panel can show its retry
            // state instead of a white, unresponsive page.
            useOnRenderProcessGone: true,
          ),
          onWebViewCreated: _onWebViewCreated,
          onLoadStart: _onLoadStart,
          onLoadStop: _onLoadStop,
          onReceivedError: _onReceivedError,
          onReceivedHttpError: _onReceivedHttpError,
          onRenderProcessGone: _onRenderProcessGone,
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

/// One-line, always-visible explanation of what the embedded UI actually is.
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
