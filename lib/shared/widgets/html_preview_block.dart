import 'dart:async';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as winweb;

import '../../desktop/html_preview_dialog.dart';
import '../../features/chat/pages/html_preview_page.dart';
import '../../icons/lucide_adapter.dart';
import 'export_capture_scope.dart';
import 'snackbar.dart';
import 'tabbed_preview_block.dart';

enum _HtmlTab { preview, code }

/// In-chat HTML code block renderer. Preview tab hosts an interactive WebView
/// (Windows: webview_windows, others: webview_flutter; Linux unsupported).
/// The WebView is created lazily — only when the Preview tab is active AND
/// streaming has ended — survives tab switches (only recreated when the code
/// changes or the block is disposed), and is disposed on block dispose. On
/// init failure the Preview tab shows the error view; re-entering the Preview
/// tab retries.
class HtmlPreviewBlock extends StatefulWidget {
  const HtmlPreviewBlock({
    super.key,
    required this.code,
    this.streaming = false,
  });

  final String code;
  final bool streaming;

  @override
  State<HtmlPreviewBlock> createState() => _HtmlPreviewBlockState();
}

class _HtmlPreviewBlockState extends State<HtmlPreviewBlock> {
  static const double _previewHeight = 406;
  static const int _maxHtmlCodeUnits = 1024 * 1024; // 1 MB equivalent
  static const Duration _webViewInitTimeoutDuration = Duration(seconds: 10);

  _HtmlTab _selectedTab = _HtmlTab.preview;
  late final ScrollController _codeScrollController;
  bool _webViewInitRequested = false;
  bool _webViewFailed = false;
  bool _ready = false;
  bool? _lastDark;
  int _webViewGeneration = 0;
  Timer? _webViewInitTimer;
  WebViewController? _flutterCtrl;
  winweb.WebviewController? _winCtrl;

  @override
  void initState() {
    super.initState();
    _codeScrollController = ScrollController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final firstRun = _lastDark == null;
    final themeChanged = !firstRun && _lastDark != dark;
    _lastDark = dark;
    if (firstRun) {
      // Deferred from initState: Theme.of is only legal here, and starting
      // the WebView after _lastDark is set guarantees the first load uses
      // the correct dark/light wrapper.
      if (!widget.streaming) _ensureWebView();
    } else if (themeChanged && _ready) {
      _reloadWebView();
    }
  }

  @override
  void didUpdateWidget(covariant HtmlPreviewBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    final streamingJustEnded = oldWidget.streaming && !widget.streaming;
    if (streamingJustEnded) {
      // Generation finished — unconditional switch to the Preview tab
      // (mirrors SvgPreviewBlock.streamingJustEnded).
      _selectedTab = _HtmlTab.preview;
      _ensureWebView();
      final sp = context.read<SettingsProvider>();
      if (sp.autoOpenHtmlPreviewOnComplete && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _openFullScreen(context);
        });
      }
    } else if (!widget.streaming && oldWidget.code != widget.code) {
      // Non-streaming code change (e.g. edited message) — re-render once
      _selectedTab = _HtmlTab.preview;
      _resetWebView();
      _ensureWebView();
    }
  }

  @override
  void dispose() {
    // Invalidate any in-flight init: its continuation must not commit a stale
    // controller nor touch state after disposal.
    _webViewGeneration++;
    _webViewInitTimer?.cancel();
    _webViewInitTimer = null;
    _codeScrollController.dispose();
    if (_winCtrl != null) {
      try {
        _winCtrl?.dispose();
      } catch (e) {
        debugPrint('HtmlPreviewBlock: dispose Windows controller failed: $e');
      }
    }
    super.dispose();
  }

  bool _isStale(int generation) => generation != _webViewGeneration;

  void _markWebViewFailed() {
    _webViewFailed = true;
    _webViewInitRequested = false;
    if (mounted) setState(() {});
  }

  Future<void> _disposeWindowsController(winweb.WebviewController c) async {
    try {
      await c.dispose();
    } catch (e) {
      debugPrint('HtmlPreviewBlock: dispose Windows controller failed: $e');
    }
  }

  /// Runs [winweb.WebviewController.initialize] with a timeout.
  ///
  /// webview_windows leaves its internal completer pending forever when the
  /// plugin channel never answers, so `initialize()` can hang without ever
  /// throwing — and a later `dispose()` would hang on that same completer.
  /// The timer is held in state so reset/dispose can cancel it: in tests the
  /// init hangs by design, and the widget teardown must not leave a pending
  /// timer behind.
  Future<void> _initializeWithTimeout(winweb.WebviewController c) {
    final completer = Completer<void>();
    _webViewInitTimer?.cancel();
    final timer = Timer(_webViewInitTimeoutDuration, () {
      _webViewInitTimer = null;
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException(
            'webview init timed out',
            _webViewInitTimeoutDuration,
          ),
        );
      }
    });
    _webViewInitTimer = timer;
    c.initialize().then(
      (value) {
        timer.cancel();
        _webViewInitTimer = null;
        if (!completer.isCompleted) completer.complete();
      },
      onError: (Object e) {
        timer.cancel();
        _webViewInitTimer = null;
        if (!completer.isCompleted) completer.completeError(e);
      },
    );
    return completer.future;
  }

  Future<void> _ensureWebView() async {
    if (_webViewInitRequested || Platform.isLinux) return;
    _webViewInitRequested = true;
    _webViewFailed = false;
    final gen = _webViewGeneration;
    final dark = _lastDark ?? false;
    if (Platform.isWindows) {
      final c = winweb.WebviewController();
      // webview_windows only resolves its internal completer when
      // initialize() succeeds or throws PlatformException. Any other failure
      // (e.g. MissingPluginException in tests) leaves dispose() awaiting that
      // completer forever — and nothing native exists to release. The flow
      // below only ever disposes after a successful initialize(), which is
      // exactly the safe window.
      try {
        await _initializeWithTimeout(c);
        if (_isStale(gen)) {
          await _disposeWindowsController(c);
          return;
        }
        try {
          await c.setBackgroundColor(const Color(0x00000000));
        } catch (e) {
          debugPrint('HtmlPreviewBlock: setBackgroundColor failed: $e');
        }
        if (_isStale(gen)) {
          await _disposeWindowsController(c);
          return;
        }
        _winCtrl = c;
        await _loadWindowsContent(c, dark);
      } catch (e) {
        debugPrint('HtmlPreviewBlock: webview init failed: $e');
        if (identical(_winCtrl, c)) {
          _winCtrl = null;
          await _disposeWindowsController(c);
        }
        if (!_isStale(gen)) _markWebViewFailed();
        return;
      }
    } else {
      final c = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted);
      try {
        if (_isStale(gen)) return;
        _flutterCtrl = c;
        await _loadFlutterContent(c, dark);
      } catch (e) {
        debugPrint('HtmlPreviewBlock: webview init failed: $e');
        if (identical(_flutterCtrl, c)) _flutterCtrl = null;
        if (!_isStale(gen)) _markWebViewFailed();
        return;
      }
    }
    if (_isStale(gen)) return;
    if (mounted) {
      setState(() => _ready = true);
    }
  }

  Future<void> _reloadWebView() async {
    if (!_webViewInitRequested || Platform.isLinux) return;
    final dark = _lastDark ?? false;
    try {
      if (Platform.isWindows) {
        final c = _winCtrl;
        if (c == null) return;
        await _loadWindowsContent(c, dark);
      } else {
        final c = _flutterCtrl;
        if (c == null) return;
        await _loadFlutterContent(c, dark);
      }
    } catch (e) {
      debugPrint('HtmlPreviewBlock: webview reload failed: $e');
    }
  }

  void _resetWebView() {
    // Bump the generation so any in-flight init continuation discards its
    // controller instead of committing it over the freshly created one.
    _webViewGeneration++;
    _webViewInitTimer?.cancel();
    _webViewInitTimer = null;
    _webViewInitRequested = false;
    _webViewFailed = false;
    _ready = false;
    if (_winCtrl != null) {
      try {
        _winCtrl?.dispose();
      } catch (e) {
        debugPrint('HtmlPreviewBlock: dispose Windows controller failed: $e');
      }
    }
    _winCtrl = null;
    _flutterCtrl = null;
  }

  Future<void> _loadWindowsContent(
    winweb.WebviewController c,
    bool dark,
  ) async {
    final html = _wrapIfNeeded(widget.code, isDark: dark);
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/html_block_${DateTime.now().microsecondsSinceEpoch}.html',
    );
    await file.writeAsString(html, flush: true);
    await c.loadUrl(Uri.file(file.path).toString());
  }

  Future<void> _loadFlutterContent(WebViewController c, bool dark) async {
    await c.loadHtmlString(_wrapIfNeeded(widget.code, isDark: dark));
  }

  String _wrapIfNeeded(String input, {required bool isDark}) {
    final hasHtmlTag = input.toLowerCase().contains('<html');
    final hasBodyTag = input.toLowerCase().contains('<body');
    if (hasHtmlTag && hasBodyTag) return input;
    final bg = isDark ? '#111111' : '#ffffff';
    final fg = isDark ? '#eaeaea' : '#222222';
    return '''<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <style>
      html, body { background: $bg; color: $fg; margin: 0; padding: 0; }
      .container { padding: 12px; }
      img, video, canvas, iframe { max-width: 100%; height: auto; }
      pre, code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace; }
    </style>
  </head>
  <body>
    <div class="container">
      $input
    </div>
  </body>
</html>''';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;
    final exporting = ExportCaptureScope.of(context);
    final settings = context.watch<SettingsProvider>();
    final colors = PreviewBlockColors.resolve(isDark);
    // While streaming, the show-code setting is authoritative for the tab;
    // otherwise the user-selected tab applies. Export always forces the Code
    // tab (platform WebViews cannot be captured offscreen).
    final showCodeWhileStreaming =
        widget.streaming && settings.htmlStreamingShowCodeInProgress;
    final tab = exporting || showCodeWhileStreaming
        ? _HtmlTab.code
        : _selectedTab;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: colors.body,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            decoration: BoxDecoration(
              color: colors.header,
              border: Border(
                bottom: BorderSide(color: colors.border, width: 1),
              ),
            ),
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(
                      start: 16,
                      end: 10,
                    ),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.tabTrack,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              PreviewTabButton(
                                label: l10n.htmlPreviewTab,
                                selected: tab == _HtmlTab.preview,
                                colors: colors,
                                onTap: () {
                                  setState(() {
                                    _selectedTab = _HtmlTab.preview;
                                  });
                                  if (!_webViewInitRequested &&
                                      !widget.streaming) {
                                    _ensureWebView();
                                  }
                                },
                              ),
                              PreviewTabButton(
                                label: l10n.mermaidCodeTab,
                                selected: tab == _HtmlTab.code,
                                colors: colors,
                                onTap: () {
                                  setState(() {
                                    _selectedTab = _HtmlTab.code;
                                  });
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (!exporting)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        PreviewTextAction(
                          icon: Lucide.Copy,
                          label: l10n.shareProviderSheetCopyButton,
                          colors: colors,
                          onTap: () => _copyHtmlCode(context),
                        ),
                        const SizedBox(width: 4),
                        PreviewTextAction(
                          icon: Lucide.Download,
                          label: l10n.htmlSaveFile,
                          colors: colors,
                          onTap: () => _saveHtmlFile(context),
                        ),
                        const SizedBox(width: 4),
                        PreviewTextAction(
                          icon: Lucide.Eye,
                          label: l10n.htmlOpenFullScreenPreview,
                          colors: colors,
                          onTap: () => _openFullScreen(context),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            key: const ValueKey('html-preview-body'),
            width: double.infinity,
            height: _previewHeight,
            child: ColoredBox(
              color: colors.body,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                layoutBuilder: (currentChild, previousChildren) {
                  return currentChild ?? const SizedBox.shrink();
                },
                child: tab == _HtmlTab.code
                    ? _buildCodeView(context, colors)
                    : _buildPreviewView(context, colors),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewView(BuildContext context, PreviewBlockColors colors) {
    if (widget.code.length > _maxHtmlCodeUnits) {
      return Padding(
        key: const ValueKey('html-preview-oversized'),
        padding: const EdgeInsets.all(8),
        child: PreviewErrorView(colors: colors),
      );
    }

    if (_webViewFailed) {
      // Init failed (e.g. missing WebView2 runtime) — show the error state
      // instead of an eternal spinner. Re-entering the Preview tab retries.
      return Padding(
        key: const ValueKey('html-preview-failed'),
        padding: const EdgeInsets.all(8),
        child: PreviewErrorView(colors: colors),
      );
    }

    if (Platform.isLinux) {
      final l10n = AppLocalizations.of(context)!;
      return Padding(
        key: const ValueKey('html-preview-linux-unsupported'),
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            l10n.htmlPreviewNotSupportedOnLinux,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              height: 1.4,
              color: colors.textTertiary,
            ),
          ),
        ),
      );
    }

    if (widget.streaming || !_ready) {
      return Padding(
        key: const ValueKey('html-preview-loading'),
        padding: const EdgeInsets.all(8),
        child: PreviewLoadingView(colors: colors),
      );
    }

    if (Platform.isWindows) {
      final c = _winCtrl;
      if (c == null) return const SizedBox.shrink();
      return winweb.Webview(c);
    }
    final c = _flutterCtrl;
    if (c == null) return const SizedBox.shrink();
    return WebViewWidget(controller: c);
  }

  Widget _buildCodeView(BuildContext context, PreviewBlockColors colors) {
    return Padding(
      key: const ValueKey('html-code-body'),
      padding: const EdgeInsets.all(12),
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: {
            PointerDeviceKind.touch,
            PointerDeviceKind.mouse,
            PointerDeviceKind.stylus,
            PointerDeviceKind.unknown,
          },
        ),
        child: Scrollbar(
          controller: _codeScrollController,
          thumbVisibility: true,
          interactive: true,
          notificationPredicate: (notif) => notif.metrics.axis == Axis.vertical,
          child: SingleChildScrollView(
            controller: _codeScrollController,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                widget.code,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _copyHtmlCode(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!context.mounted) return;
    showAppSnackBar(
      context,
      message: l10n.chatMessageWidgetCopiedToClipboard,
      type: NotificationType.success,
    );
  }

  Future<void> _saveHtmlFile(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final suggested = 'page_${DateTime.now().millisecondsSinceEpoch}.html';
    try {
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: l10n.htmlSaveDialogTitle,
        fileName: suggested,
        type: FileType.custom,
        allowedExtensions: const ['html'],
      );
      if (savePath == null || savePath.isEmpty) return;
      await File(savePath).parent.create(recursive: true);
      await File(savePath).writeAsString(widget.code);
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        message: l10n.htmlSaveSuccess,
        type: NotificationType.success,
      );
    } catch (e) {
      debugPrint('HtmlPreviewBlock: save file failed: $e');
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        message: l10n.htmlSaveFailed,
        type: NotificationType.error,
      );
    }
  }

  void _openFullScreen(BuildContext context) {
    if (Platform.isAndroid || Platform.isIOS) {
      Navigator.of(context).push(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => HtmlPreviewPage(html: widget.code),
          transitionDuration: const Duration(milliseconds: 300),
          reverseTransitionDuration: const Duration(milliseconds: 240),
          transitionsBuilder: (context, anim, sec, child) {
            final curved = CurvedAnimation(
              parent: anim,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return FadeTransition(opacity: curved, child: child);
          },
        ),
      );
    } else {
      showHtmlPreviewDesktopDialog(context, html: widget.code);
    }
  }
}
