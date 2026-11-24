import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_text_button.dart';
import '../../../theme/app_font_weights.dart';
import '../../../utils/app_directories.dart';

/// Whether the DeepSeek Harness WebUI can be embedded on [platform].
///
/// Only platforms with a native WebView implementation can host it: the
/// plugin has none for Linux, and a web build cannot embed itself. This reads
/// [defaultTargetPlatform] / [kIsWeb] at the call site instead of dart:io so
/// widget tests can drive it through [debugDefaultTargetPlatformOverride].
@visibleForTesting
bool harnessWebViewSupported(TargetPlatform platform, {required bool isWeb}) {
  if (isWeb) return false;
  return switch (platform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
    TargetPlatform.linux || TargetPlatform.fuchsia => false,
  };
}

/// The WebView2 profile directory of the embedded DSH view on Windows.
///
/// Deliberately separate from the browser feature's `<appData>/browser/webview2`
/// profile: the DSH WebUI is a remote product's own surface, not a browser tab,
/// so its cookies, cache and history must not mix with the in-app browser's.
@visibleForTesting
String harnessWindowsProfilePath(String appDataDirectory) =>
    p.join(appDataDirectory, 'harness', 'webview2');

/// TEMPORARY E2E diagnostics: the launch link carries a live token, so the
/// query string is never printed.
String _loggedUrl(WebUri? uri) {
  if (uri == null) return 'null';
  final value = uri.toString();
  final cut = value.indexOf('?');
  return cut < 0 ? value : '${value.substring(0, cut)}?<redacted>';
}

/// The remote DeepSeek Harness WebUI, embedded in the app.
///
/// [url] is the tokenized launch link printed by `dsh web`. The native WebView
/// follows DSH's own 303/302 chain and keeps the cookies those responses set,
/// so the page authenticates itself; this widget only shows progress and load
/// failures, and lets the user retry or fall back to an external browser.
///
/// On Windows the view runs on its own WebView2 profile under the app data
/// directory instead of the default profile next to the executable, which an
/// installed app may not be allowed to create.
///
/// It fills the space its parent gives it; the parent owns any top bar.
class HarnessWebView extends StatefulWidget {
  const HarnessWebView({super.key, required this.url});

  /// The tokenized DSH WebUI launch link, including its `token` parameter.
  final String url;

  @override
  State<HarnessWebView> createState() => _HarnessWebViewState();
}

class _HarnessWebViewState extends State<HarnessWebView> {
  // Shared by every instance: the settings never depend on widget state, and
  // a new object on each build would ask the plugin to reappraise them.
  static final InAppWebViewSettings _settings = InAppWebViewSettings(
    javaScriptEnabled: true,
    // The WebUI keeps its operator session in browser storage/cookies.
    domStorageEnabled: true,
  );

  InAppWebViewController? _controller;
  bool _loading = true;
  bool _failed = false;
  int _progress = 0;

  /// Memoized one-time WebView2 environment of this view (Windows only).
  Future<WebViewEnvironment?>? _environment;
  WebViewEnvironment? _webViewEnvironment;
  bool _environmentReady = false;

  bool get _supported =>
      harnessWebViewSupported(defaultTargetPlatform, isWeb: kIsWeb);

  @override
  void initState() {
    super.initState();
    // The native view must be created with its environment already resolved,
    // so this runs before the first build that mounts it; elsewhere it is a
    // no-op that simply marks the view ready.
    unawaited(_initializeEnvironment());
  }

  Future<void> _initializeEnvironment() async {
    final environment = await _ensureEnvironment();
    if (!mounted) return;
    setState(() {
      _webViewEnvironment = environment;
      _environmentReady = true;
    });
  }

  Future<WebViewEnvironment?> _ensureEnvironment() =>
      _environment ??= _createEnvironment();

  Future<WebViewEnvironment?> _createEnvironment() async {
    // Only WebView2 has a user-selectable profile; the other platforms use
    // the plugin's default environment.
    if (defaultTargetPlatform != TargetPlatform.windows) return null;
    try {
      final dataDirectory = await AppDirectories.getAppDataDirectory();
      final profile = harnessWindowsProfilePath(dataDirectory.path);
      await Directory(profile).create(recursive: true);
      return await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(userDataFolder: profile),
      );
    } catch (_) {
      // A profile that cannot be created must not throw out of the widget
      // tree. Forget the memoized future so a later mount retries, and let the
      // view start on the plugin's default environment: its load then reports
      // the failure through the error state instead of a blank red screen.
      _environment = null;
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return KeyedSubtree(
      key: const Key('harness-web-view'),
      child: _supported
          ? _buildEmbedded(context, l10n)
          : _buildUnsupported(context, l10n),
    );
  }

  Widget _buildEmbedded(BuildContext context, AppLocalizations l10n) {
    if (!_environmentReady) {
      // Windows creates its WebView2 profile before the native view exists;
      // the same slim strip covers that one-time preparation.
      return const Column(
        children: [
          LinearProgressIndicator(minHeight: 2),
          Expanded(child: SizedBox.shrink()),
        ],
      );
    }
    return Column(
      children: [
        // Kept in layout rather than stacked over the native view: the Flutter
        // strip is guaranteed to paint on every platform, while an overlay
        // above a platform view depends on how the view is composited.
        if (_loading && !_failed)
          LinearProgressIndicator(minHeight: 2, value: _progress / 100),
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(widget.url)),
                initialSettings: _settings,
                webViewEnvironment: _webViewEnvironment,
                onWebViewCreated: (controller) => _controller = controller,
                onConsoleMessage: (controller, message) {
                  debugPrint(
                    '[harness-webview] console ${message.messageLevel} '
                    '${message.message}',
                  );
                },
                onReceivedServerTrustAuthRequest:
                    (controller, challenge) async {
                      debugPrint('[harness-webview] ssl challenge $challenge');
                      return ServerTrustAuthResponse(
                        action: ServerTrustAuthResponseAction.CANCEL,
                      );
                    },
                onLoadStart: _onLoadStart,
                onProgressChanged: _onProgressChanged,
                onLoadStop: _onLoadStop,
                onReceivedError: _onReceivedError,
                onReceivedHttpError: _onReceivedHttpError,
              ),
              if (_failed)
                Positioned.fill(
                  child: ColoredBox(
                    color: Theme.of(context).colorScheme.surface,
                    child: _HarnessStatus(
                      key: const Key('harness-web-view-error'),
                      icon: LucideIcons.cloudOff,
                      title: l10n.assistantHarnessLoadFailed,
                      actions: [
                        IosTextButton(
                          key: const Key('harness-web-view-retry'),
                          label: l10n.assistantHarnessRetry,
                          icon: LucideIcons.rotateCw,
                          onPressed: () => unawaited(_retry()),
                        ),
                        _openInBrowserButton(l10n),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildUnsupported(BuildContext context, AppLocalizations l10n) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: _HarnessStatus(
        key: const Key('harness-web-view-unsupported'),
        icon: LucideIcons.monitorOff,
        title: l10n.assistantHarnessUnsupportedPlatform,
        actions: [_openInBrowserButton(l10n)],
      ),
    );
  }

  Widget _openInBrowserButton(AppLocalizations l10n) {
    return IosTextButton(
      key: const Key('harness-web-view-open-browser'),
      label: l10n.assistantHarnessOpenInBrowser,
      icon: LucideIcons.externalLink,
      onPressed: () => unawaited(_openInBrowser()),
    );
  }

  Future<void> _retry() async {
    final controller = _controller;
    if (controller == null) return;
    setState(() {
      _failed = false;
      _loading = true;
      _progress = 0;
    });
    try {
      // Reload re-runs the launch link when the first exchange never finished,
      // and simply refetches the WebUI once DSH's cookies are in place.
      await controller.reload();
    } catch (_) {
      // A native view that is already gone cannot reload; keep offering the
      // error state instead of an empty frame that never resolves.
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  Future<void> _openInBrowser() async {
    final uri = Uri.tryParse(widget.url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // No external browser handler: the in-app retry stays the only action.
    }
  }

  void _onLoadStart(InAppWebViewController controller, WebUri? url) {
    debugPrint('[harness-webview] loadStart ${_loggedUrl(url)}');
    if (!mounted) return;
    setState(() {
      _failed = false;
      _loading = true;
      _progress = 0;
    });
  }

  void _onProgressChanged(InAppWebViewController controller, int progress) {
    if (!mounted || _failed) return;
    final next = progress.clamp(0, 100);
    if (next == _progress) return;
    setState(() {
      _progress = next;
      if (next >= 100) _loading = false;
    });
  }

  void _onLoadStop(InAppWebViewController controller, WebUri? url) {
    debugPrint('[harness-webview] loadStop ${_loggedUrl(url)}');
    if (!mounted || _failed) return;
    setState(() {
      _loading = false;
      _progress = 100;
    });
  }

  void _onReceivedError(
    InAppWebViewController controller,
    WebResourceRequest request,
    WebResourceError error,
  ) {
    debugPrint(
      '[harness-webview] error main=${request.isForMainFrame} '
      'type=${error.type} description=${error.description} '
      'url=${_loggedUrl(request.url)}',
    );
    // Only the main document failing is a load error; a missing image or an
    // unreachable subresource must not replace the page the user is reading.
    if (!mounted || request.isForMainFrame != true) return;
    // Superseded navigations (a reload or redirect that cancelled the previous
    // request) are reported here too, but they are not a page the user sees.
    if (error.type == WebResourceErrorType.CANCELLED) return;
    _failLoad();
  }

  void _onReceivedHttpError(
    InAppWebViewController controller,
    WebResourceRequest request,
    WebResourceResponse response,
  ) {
    debugPrint(
      '[harness-webview] httpError main=${request.isForMainFrame} '
      'status=${response.statusCode} url=${_loggedUrl(request.url)}',
    );
    if (!mounted || request.isForMainFrame != true) return;
    if ((response.statusCode ?? 0) < 400) return;
    _failLoad();
  }

  void _failLoad() {
    debugPrint('[harness-webview] showing the load-failure state');
    setState(() {
      _failed = true;
      _loading = false;
    });
  }
}

/// A centered icon, message and action row for the states that are not a
/// live WebUI (load failure, unsupported platform).
class _HarnessStatus extends StatelessWidget {
  const _HarnessStatus({
    super.key,
    required this.icon,
    required this.title,
    required this.actions,
  });

  final IconData icon;
  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 36, color: colorScheme.onSurfaceVariant),
              const SizedBox(height: 18),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: AppFontWeights.semibold,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: actions,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
