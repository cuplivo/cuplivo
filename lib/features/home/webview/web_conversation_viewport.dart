import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as winweb;

import '../../../core/services/streaming_content_notifier.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_semantic_colors.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../controllers/conversation_viewport_port.dart';
import 'android_web_chat_view.dart';
import 'web_chat_protocol.dart';
import 'web_chat_remote_media.dart';
import 'web_chat_snapshot.dart';

typedef WebChatActionHandler =
    Future<void> Function(WebChatActionRequest request);
typedef WebChatStreamingPatchBuilder =
    Map<String, dynamic>? Function(String messageId, StreamingContentData data);

class WebConversationViewport extends StatefulWidget {
  const WebConversationViewport({
    super.key,
    required this.snapshot,
    required this.mediaRegistry,
    required this.viewportPort,
    required this.streamingContentNotifier,
    required this.buildStreamingPatch,
    required this.onAction,
    required this.onUseFlutter,
    required this.onUserScrollIntent,
    required this.remoteMediaClientFactory,
  });

  final Map<String, dynamic> snapshot;
  final Map<String, WebChatMediaSource> mediaRegistry;
  final WebConversationViewportPort viewportPort;
  final StreamingContentNotifier streamingContentNotifier;
  final WebChatStreamingPatchBuilder buildStreamingPatch;
  final WebChatActionHandler onAction;
  final VoidCallback onUseFlutter;
  final VoidCallback onUserScrollIntent;
  final WebChatHttpClientFactory remoteMediaClientFactory;

  @override
  State<WebConversationViewport> createState() =>
      _WebConversationViewportState();
}

class _WebConversationViewportState extends State<WebConversationViewport> {
  static const Duration _initializationTimeout = Duration(seconds: 10);
  static const String _windowsVirtualHost = 'cuplivo-web-chat.invalid';
  static const String _webView2Url =
      'https://developer.microsoft.com/microsoft-edge/webview2/';
  static const List<String> _windowsAssets = <String>[
    'index.html',
    'styles.css',
    'app.bundle.js',
    'vendor/marked.min.js',
    'vendor/purify.min.js',
    'vendor/highlight.min.js',
    'vendor/github.min.css',
    'vendor/katex.min.js',
    'vendor/katex.min.css',
    'vendor/auto-render.min.js',
  ];

  WebViewController? _flutterController;
  /// Resolves once the iOS/macOS shell page navigation completes. WKWebView
  /// fails evaluateJavaScript while a navigation is in flight, and the page
  /// posts `ready` before that, so bridge sends wait on this first.
  Future<void>? _flutterShellLoadFuture;
  AndroidWebChatController? _androidController;
  winweb.WebviewController? _windowsController;
  StreamSubscription<dynamic>? _windowsMessageSubscription;
  final Map<String, _StreamingListenerBinding> _streamListeners =
      <String, _StreamingListenerBinding>{};
  final WebChatStreamingPatchBuffer _streamPatchBuffer =
      WebChatStreamingPatchBuffer();
  final WebChatSnapshotSendQueue _snapshotQueue = WebChatSnapshotSendQueue();
  Timer? _streamFlushTimer;
  Timer? _initializationTimer;
  Timer? _renderCommitTimer;
  _RenderCommitIdentity? _renderCommitIdentity;
  bool _ready = false;
  bool _firstRenderCommitted = false;
  bool _initializing = false;
  bool _webView2Missing = false;
  int _generation = 0;
  int _transportGeneration = 0;
  int _nextRenderRevision = 0;
  bool _snapshotTransferActive = false;
  String? _lastSnapshotSignature;
  String? _errorCode;
  String? _lastWebDiagnosticCode;
  int? _failedRenderRevision;
  int? _failedMessageCount;
  late final String _capabilityToken = _randomCapabilityToken();
  late WebChatActionGate _actionGate = _newActionGate();
  late final WebViewportCommandSender _viewportCommandSender =
      _sendViewportCommand;

  String get _renderSessionId =>
      widget.snapshot['renderSessionId']?.toString() ?? '';
  String get _conversationId =>
      widget.snapshot['conversationId']?.toString() ?? '';
  int get _actionEpoch =>
      (widget.snapshot['actionEpoch'] as num?)?.toInt() ?? 0;

  @override
  void initState() {
    super.initState();
    widget.viewportPort.attach(_viewportCommandSender);
    _syncStreamingListeners();
    _initialize();
  }

  @override
  void didUpdateWidget(covariant WebConversationViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sessionChanged =
        oldWidget.snapshot['renderSessionId'] !=
            widget.snapshot['renderSessionId'] ||
        oldWidget.snapshot['conversationId'] !=
            widget.snapshot['conversationId'];
    if (sessionChanged ||
        oldWidget.snapshot['actionEpoch'] != widget.snapshot['actionEpoch']) {
      _actionGate = _newActionGate();
    }
    if (sessionChanged) {
      _transportGeneration++;
      _streamFlushTimer?.cancel();
      _streamFlushTimer = null;
      _streamPatchBuffer.clear();
      _snapshotQueue.clear();
      _clearRenderCommitWatchdog();
      _firstRenderCommitted = false;
      _nextRenderRevision = 0;
      _lastSnapshotSignature = null;
      _lastWebDiagnosticCode = null;
      _failedRenderRevision = null;
      _failedMessageCount = null;
    }
    if (!identical(oldWidget.viewportPort, widget.viewportPort)) {
      oldWidget.viewportPort.detach(_viewportCommandSender);
      widget.viewportPort.attach(_viewportCommandSender);
    }
    _syncStreamingListeners();
    if (_ready) _enqueueLatestSnapshot();
  }

  @override
  void dispose() {
    _generation++;
    _transportGeneration++;
    _initializationTimer?.cancel();
    _streamFlushTimer?.cancel();
    _clearRenderCommitWatchdog();
    _streamPatchBuffer.clear();
    _snapshotQueue.clear();
    _detachStreamingListeners();
    widget.viewportPort.detach(_viewportCommandSender);
    unawaited(_windowsMessageSubscription?.cancel());
    final controller = _windowsController;
    _windowsController = null;
    if (controller != null) {
      unawaited(
        controller.dispose().catchError((Object error) {
          debugPrint(
            'WebConversationViewport: Windows dispose failed '
            '(${error.runtimeType})',
          );
        }),
      );
    }
    _androidController?.dispose();
    _androidController = null;
    _flutterController = null;
    super.dispose();
  }

  WebChatActionGate _newActionGate() => WebChatActionGate(
    renderSessionId: _renderSessionId,
    conversationId: _conversationId,
    actionEpoch: _actionEpoch,
  );

  Future<void> _initialize() async {
    if (_initializing || _ready) return;
    _initializing = true;
    _errorCode = null;
    _failedRenderRevision = null;
    _failedMessageCount = null;
    _webView2Missing = false;
    if (mounted) setState(() {});
    final generation = ++_generation;
    _initializationTimer?.cancel();
    _initializationTimer = Timer(_initializationTimeout, () {
      debugPrint('WebConversationViewport: shell ready timed out');
      _fail(generation, 'shell_ready_timeout');
    });
    try {
      if (Platform.isWindows) {
        await _initializeWindows(generation);
      } else if (Platform.isAndroid) {
        // The Android platform view loads the shell once it is attached.
      } else {
        await _initializeFlutterWebView(generation);
      }
    } on TimeoutException {
      debugPrint('WebConversationViewport: initialization timed out');
      _fail(generation, 'initialization_timeout');
    } on PlatformException catch (error) {
      debugPrint(
        'WebConversationViewport: platform initialization failed: '
        '${error.code}',
      );
      _fail(generation, 'platform_${error.code}');
    } catch (error) {
      debugPrint(
        'WebConversationViewport: initialization failed '
        '(${error.runtimeType})',
      );
      _fail(generation, 'initialization_failed');
    }
  }

  Future<void> _initializeWindows(int generation) async {
    final version = await winweb.WebviewController.getWebViewVersion().timeout(
      _initializationTimeout,
    );
    if (version == null || version.isEmpty) {
      _webView2Missing = true;
      throw const WebChatProtocolException('webview2_runtime_missing');
    }
    final controller = winweb.WebviewController();
    await controller.initialize().timeout(_initializationTimeout);
    if (_isStale(generation)) {
      await controller.dispose();
      return;
    }
    await controller.setBackgroundColor(const Color(0x00000000));
    await controller.setPopupWindowPolicy(winweb.WebviewPopupWindowPolicy.deny);
    _windowsMessageSubscription = controller.webMessage.listen(
      (dynamic event) => _handleBridgeMessage(_windowsMessageText(event)),
      onError: (Object error) {
        debugPrint(
          'WebConversationViewport: Windows bridge failed '
          '(${error.runtimeType})',
        );
      },
    );
    final shell = await _prepareWindowsShell();
    await controller.addVirtualHostNameMapping(
      _windowsVirtualHost,
      shell.parent.path,
      winweb.WebviewHostResourceAccessKind.deny,
    );
    _windowsController = controller;
    final shellUri = Uri(
      scheme: 'https',
      host: _windowsVirtualHost,
      path: '/index.html',
      queryParameters: <String, String>{'platform': 'windows'},
    );
    await controller.loadUrl(shellUri.toString());
  }

  Future<void> _initializeFlutterWebView(int generation) async {
    final controller =
        WebViewController(
            onPermissionRequest: (request) => unawaited(request.deny()),
          )
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setBackgroundColor(const Color(0x00000000))
          ..setNavigationDelegate(
            NavigationDelegate(
              onNavigationRequest: (request) {
                if (!request.isMainFrame || _isLocalShellUrl(request.url)) {
                  return NavigationDecision.navigate;
                }
                unawaited(_openExternalUrl(request.url));
                return NavigationDecision.prevent;
              },
              onWebResourceError: (error) {
                if (error.isForMainFrame != true) return;
                debugPrint(
                  'WebConversationViewport: shell resource failed: '
                  '${error.errorCode}',
                );
                _fail(generation, 'resource_${error.errorCode}');
              },
            ),
          )
          ..addJavaScriptChannel(
            'CuplivoChat',
            onMessageReceived: (message) =>
                _handleBridgeMessage(message.message),
          );
    if (_isStale(generation)) return;
    _flutterController = controller;
    final shellLoadFuture =
        controller.loadFlutterAsset('assets/web_chat/index.html');
    _flutterShellLoadFuture = shellLoadFuture;
    await shellLoadFuture;
  }

  Future<void> _handleAndroidViewCreated(int viewId, int generation) async {
    if (_isStale(generation)) return;
    final oldController = _androidController;
    final controller = AndroidWebChatController.attach(
      viewId: viewId,
      onMessage: _handleBridgeMessage,
      onResourceError: (errorCode) {
        debugPrint(
          'WebConversationViewport: Android shell resource failed: '
          '$errorCode',
        );
        _fail(generation, 'resource_$errorCode');
      },
      onNavigationRequest: (url) => unawaited(_openExternalUrl(url)),
      onDiagnostic: (code) {
        debugPrint('WebConversationViewport: Android diagnostic $code');
        if (code == 'render_process_gone') {
          _fail(generation, code);
        }
      },
    );
    _androidController = controller;
    oldController?.dispose();
    try {
      await controller.loadShell();
    } on PlatformException catch (error) {
      debugPrint(
        'WebConversationViewport: Android shell initialization failed: '
        '${error.code}',
      );
      _fail(generation, 'platform_${error.code}');
    } catch (error) {
      debugPrint(
        'WebConversationViewport: Android shell initialization failed '
        '(${error.runtimeType})',
      );
      _fail(generation, 'initialization_failed');
    }
  }

  bool _isLocalShellUrl(String url) =>
      url.startsWith('file:') ||
      url.startsWith('data:') ||
      url.startsWith('about:') ||
      url.startsWith('https://$_windowsVirtualHost/') ||
      url.startsWith('https://appassets.androidplatform.net/');

  Future<File> _prepareWindowsShell() async {
    final temp = await getTemporaryDirectory();
    final directory = Directory(
      '${temp.path}${Platform.pathSeparator}cuplivo_web_chat_$webChatAssetVersion',
    );
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final relativeAssets = <String>{
      ..._windowsAssets,
      for (final asset in manifest.listAssets())
        if (asset.startsWith('assets/web_chat/vendor/fonts/'))
          asset.substring('assets/web_chat/'.length),
    };
    final index = File('${directory.path}${Platform.pathSeparator}index.html');
    if (await _windowsCacheIsComplete(directory, relativeAssets)) {
      await _cleanupOldWindowsCaches(directory);
      return index;
    }
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
    await directory.create(recursive: true);
    for (final relative in relativeAssets) {
      final data = await rootBundle.load('assets/web_chat/$relative');
      final output = File(
        '${directory.path}${Platform.pathSeparator}'
        '${relative.replaceAll('/', Platform.pathSeparator)}',
      );
      await output.parent.create(recursive: true);
      await output.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    }
    final mermaid = await rootBundle.load('assets/mermaid.min.js');
    await File(
      '${directory.path}${Platform.pathSeparator}mermaid.min.js',
    ).writeAsBytes(
      mermaid.buffer.asUint8List(mermaid.offsetInBytes, mermaid.lengthInBytes),
    );
    final marker = File('${directory.path}${Platform.pathSeparator}.complete');
    final temporaryMarker = File(
      '${directory.path}${Platform.pathSeparator}.complete.tmp',
    );
    await temporaryMarker.writeAsString(webChatAssetVersion, flush: true);
    await temporaryMarker.rename(marker.path);
    await _cleanupOldWindowsCaches(directory);
    return index;
  }

  Future<bool> _windowsCacheIsComplete(
    Directory directory,
    Set<String> relativeAssets,
  ) async {
    if (!await directory.exists()) return false;
    final marker = File('${directory.path}${Platform.pathSeparator}.complete');
    try {
      if (!await marker.exists() ||
          await marker.readAsString() != webChatAssetVersion) {
        return false;
      }
      for (final relative in <String>{...relativeAssets, 'mermaid.min.js'}) {
        final file = File(
          '${directory.path}${Platform.pathSeparator}'
          '${relative.replaceAll('/', Platform.pathSeparator)}',
        );
        if (!await file.exists() || await file.length() == 0) return false;
      }
      return true;
    } catch (error) {
      debugPrint(
        'WebConversationViewport: Windows cache validation failed '
        '(${error.runtimeType})',
      );
      return false;
    }
  }

  Future<void> _cleanupOldWindowsCaches(Directory activeDirectory) async {
    final parent = activeDirectory.parent;
    try {
      await for (final entity in parent.list(followLinks: false)) {
        if (entity is! Directory || entity.path == activeDirectory.path) {
          continue;
        }
        final name = entity.path.split(Platform.pathSeparator).last;
        if (!name.startsWith('cuplivo_web_chat_')) continue;
        try {
          await entity.delete(recursive: true);
        } catch (error) {
          debugPrint(
            'WebConversationViewport: old Windows cache cleanup failed '
            '(${error.runtimeType})',
          );
        }
      }
    } catch (error) {
      debugPrint(
        'WebConversationViewport: Windows cache scan failed '
        '(${error.runtimeType})',
      );
    }
  }

  void _handleBridgeMessage(String raw) {
    Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('bridge payload is not an object');
      }
      message = decoded.map((key, value) => MapEntry(key.toString(), value));
    } catch (error) {
      debugPrint(
        'WebConversationViewport: malformed bridge message '
        '(${error.runtimeType})',
      );
      return;
    }
    switch (message['type']) {
      case 'ready':
        if (message['protocolVersion'] != webChatProtocolVersion ||
            message['assetVersion'] != webChatAssetVersion) {
          _fail(_generation, 'protocol_mismatch');
          return;
        }
        // `ready` always belongs to a fresh JavaScript document. Re-send even
        // when Flutter's semantic snapshot has not changed since a reload.
        _transportGeneration++;
        _snapshotQueue.clear();
        _clearRenderCommitWatchdog();
        _lastSnapshotSignature = null;
        _lastWebDiagnosticCode = null;
        _failedRenderRevision = null;
        _failedMessageCount = null;
        _ready = true;
        _firstRenderCommitted = false;
        _initializing = false;
        _initializationTimer?.cancel();
        if (mounted) setState(() {});
        _enqueueLatestSnapshot();
        return;
      case 'renderCommitted':
        if (!_isAuthorizedBridgeRequest(message)) {
          debugPrint('WebConversationViewport: rejected render ACK');
          return;
        }
        final revision = (message['renderRevision'] as num?)?.toInt();
        if (revision == null ||
            !_snapshotQueue.acknowledge(
              renderSessionId: _renderSessionId,
              conversationId: _conversationId,
              renderRevision: revision,
            )) {
          debugPrint('WebConversationViewport: ignored stale render ACK');
          return;
        }
        _clearRenderCommitWatchdog();
        if (!_firstRenderCommitted) {
          _firstRenderCommitted = true;
          if (mounted) setState(() {});
        }
        unawaited(_drainSnapshotQueue());
        scheduleMicrotask(() {
          if (!_snapshotQueue.hasInFlight && _streamPatchBuffer.hasPending) {
            _scheduleStreamingPatchFlush();
          }
        });
        return;
      case 'viewportInteraction':
        if (!_isAuthorizedBridgeRequest(message)) {
          debugPrint('WebConversationViewport: rejected viewport interaction');
          return;
        }
        widget.viewportPort.cancelAutoFollow();
        widget.onUserScrollIntent();
        return;
      case 'action':
        unawaited(_handleAction(message));
        return;
      case 'externalLink':
        if (!_isAuthorizedBridgeRequest(message)) {
          debugPrint('WebConversationViewport: rejected external link');
          return;
        }
        final url = message['url']?.toString();
        if (url != null) unawaited(_openExternalUrl(url));
        return;
      case 'mediaRequest':
        unawaited(_handleMediaRequest(message));
        return;
      case 'viewportMetrics':
        final wasUserScrolling = widget.viewportPort.isUserScrolling;
        widget.viewportPort.updateMetrics(message);
        final isUserScrolling = widget.viewportPort.isUserScrolling;
        if (!wasUserScrolling && isUserScrolling) {
          widget.onUserScrollIntent();
          _pauseRenderCommitWatchdog();
        } else if (wasUserScrolling && !isUserScrolling) {
          _resumeRenderCommitWatchdog();
          unawaited(_drainSnapshotQueue());
        }
        return;
      case 'diagnostic':
        final code = message['code']?.toString() ?? 'unknown';
        if (code == 'render_failed' && !_isAuthorizedBridgeRequest(message)) {
          debugPrint(
            'WebConversationViewport: rejected render failure diagnostic',
          );
          return;
        }
        _lastWebDiagnosticCode = code;
        debugPrint('WebConversationViewport: web diagnostic $code');
        if (code == 'render_failed') {
          final revision = (message['renderRevision'] as num?)?.toInt();
          final inFlight = _snapshotQueue.inFlight;
          final identity =
              _renderCommitIdentity ??
              (inFlight == null
                  ? null
                  : _RenderCommitIdentity.fromSnapshot(inFlight));
          if (revision == null ||
              identity == null ||
              revision != identity.renderRevision ||
              !identity.matches(inFlight)) {
            debugPrint('WebConversationViewport: ignored stale render failure');
            return;
          }
          _fail(_generation, 'render_failed', renderRevision: revision);
        }
        return;
    }
  }

  Future<void> _handleAction(Map<String, dynamic> message) async {
    final requestId = message['requestId']?.toString() ?? '';
    if (message['capabilityToken'] != _capabilityToken) {
      debugPrint('WebConversationViewport: rejected action capability');
      await _sendActionResult(requestId, ok: false, code: 'capability');
      return;
    }
    try {
      final request = WebChatActionRequest.fromJson(message);
      if (!_actionGate.accept(request)) {
        await _sendActionResult(requestId, ok: false, code: 'stale');
        return;
      }
      await widget.onAction(request);
      await _sendActionResult(requestId, ok: true);
    } catch (error) {
      debugPrint(
        'WebConversationViewport: action failed (${error.runtimeType})',
      );
      await _sendActionResult(requestId, ok: false, code: 'action_failed');
    }
  }

  Future<void> _handleMediaRequest(Map<String, dynamic> message) async {
    if (!_isAuthorizedBridgeRequest(message)) {
      debugPrint('WebConversationViewport: rejected media capability');
      return;
    }
    final handle = message['handle']?.toString() ?? '';
    if (!handle.startsWith('local:') &&
        !handle.startsWith('asset:') &&
        !handle.startsWith('remote:')) {
      return;
    }
    final requestSessionId = _renderSessionId;
    final requestConversationId = _conversationId;
    try {
      final source = widget.mediaRegistry[handle];
      if (source == null) {
        throw const WebChatProtocolException('unknown media handle');
      }
      final _WebChatMediaPayload media;
      if (source.kind == WebChatMediaSourceKind.remoteImage) {
        final remote = await WebChatRemoteImageLoader(
          clientFactory: widget.remoteMediaClientFactory,
        ).load(source.value);
        media = _WebChatMediaPayload(mime: remote.mime, bytes: remote.bytes);
      } else {
        final extension = source.value.toLowerCase().split('.').last;
        final mime = switch (extension) {
          'png' => 'image/png',
          'jpg' || 'jpeg' => 'image/jpeg',
          'gif' => 'image/gif',
          'webp' => 'image/webp',
          'svg' when source.kind == WebChatMediaSourceKind.bundledAsset =>
            'image/svg+xml',
          _ => null,
        };
        if (mime == null) {
          throw const WebChatProtocolException('unsupported media type');
        }
        final bytes = switch (source.kind) {
          WebChatMediaSourceKind.localFile => await _readLocalMedia(
            source.value,
          ),
          WebChatMediaSourceKind.bundledAsset => await _readBundledMedia(
            source.value,
          ),
          WebChatMediaSourceKind.remoteImage => throw StateError(
            'remote media handled above',
          ),
        };
        media = _WebChatMediaPayload(mime: mime, bytes: bytes);
      }
      if (requestSessionId != _renderSessionId ||
          requestConversationId != _conversationId) {
        debugPrint('WebConversationViewport: discarded stale media response');
        return;
      }
      final activeSource = widget.mediaRegistry[handle];
      if (activeSource == null ||
          activeSource.kind != source.kind ||
          activeSource.value != source.value) {
        debugPrint(
          'WebConversationViewport: discarded inactive media response',
        );
        return;
      }
      final payload = <String, dynamic>{
        'type': 'mediaResult',
        'renderSessionId': requestSessionId,
        'conversationId': requestConversationId,
        'handle': handle,
        'dataUrl': 'data:${media.mime};base64,${base64Encode(media.bytes)}',
      };
      for (final chunk in chunkWebChatEnvelope(
        payload: payload,
        transferId: 'media:$requestSessionId:${handle.hashCode}',
      )) {
        if (requestSessionId != _renderSessionId ||
            requestConversationId != _conversationId) {
          debugPrint('WebConversationViewport: stopped stale media transfer');
          return;
        }
        await _sendEnvelope(chunk);
      }
    } catch (error) {
      final detail = switch (error) {
        WebChatProtocolException(:final message) => message,
        FileSystemException(:final message) => message,
        _ => error.runtimeType.toString(),
      };
      debugPrint('WebConversationViewport: media request failed ($detail)');
      if (requestSessionId != _renderSessionId ||
          requestConversationId != _conversationId) {
        return;
      }
      await _sendEnvelope(<String, dynamic>{
        'type': 'mediaError',
        'renderSessionId': requestSessionId,
        'conversationId': requestConversationId,
        'handle': handle,
        'code': detail,
      });
    }
  }

  Future<Uint8List> _readLocalMedia(String path) async {
    final resolvedPath = SandboxPathResolver.fix(path);
    final file = File(resolvedPath);
    if (!await file.exists()) {
      throw const FileSystemException('media file does not exist');
    }
    final length = await file.length();
    if (length > 16 * 1024 * 1024) {
      throw const WebChatProtocolException('local media exceeds size limit');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > 16 * 1024 * 1024) {
      throw const WebChatProtocolException('local media exceeds size limit');
    }
    return bytes;
  }

  Future<Uint8List> _readBundledMedia(String path) async {
    if (!path.startsWith('assets/icons/') ||
        path.contains('..') ||
        path.contains(r'\')) {
      throw const WebChatProtocolException('bundled media is not allowed');
    }
    final data = await rootBundle.load(path);
    if (data.lengthInBytes > 2 * 1024 * 1024) {
      throw const WebChatProtocolException('bundled media exceeds size limit');
    }
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  bool _isAuthorizedBridgeRequest(Map<String, dynamic> message) =>
      message['capabilityToken'] == _capabilityToken &&
      message['renderSessionId'] == _renderSessionId &&
      message['conversationId'] == _conversationId;

  void _enqueueLatestSnapshot() {
    if (!_ready) return;
    final semantic = Map<String, dynamic>.of(widget.snapshot)
      ..remove('renderRevision');
    final signature = jsonEncode(semantic);
    if (signature == _lastSnapshotSignature) return;
    _lastSnapshotSignature = signature;
    final payload = Map<String, dynamic>.of(semantic)
      ..['renderRevision'] = ++_nextRenderRevision
      ..['capabilityToken'] = _capabilityToken;
    _snapshotQueue.enqueue(payload);
    unawaited(_drainSnapshotQueue());
  }

  Future<void> _drainSnapshotQueue() async {
    if (!_ready ||
        widget.viewportPort.isUserScrolling ||
        _streamPatchBuffer.inFlight ||
        _snapshotTransferActive) {
      return;
    }
    final payload = _snapshotQueue.takeNext();
    if (payload == null) return;
    _snapshotTransferActive = true;
    final transportGeneration = _transportGeneration;
    final transferId =
        '${payload['renderSessionId']}:${payload['renderRevision']}';
    try {
      for (final chunk in chunkWebChatEnvelope(
        payload: payload,
        transferId: transferId,
      )) {
        if (!_ready || transportGeneration != _transportGeneration) return;
        await _sendEnvelope(chunk);
      }
    } finally {
      _snapshotTransferActive = false;
      if (_ready && transportGeneration != _transportGeneration) {
        unawaited(_drainSnapshotQueue());
      }
    }
    if (!_ready ||
        transportGeneration != _transportGeneration ||
        !_snapshotQueue.hasInFlight) {
      return;
    }
    final identity = _RenderCommitIdentity.fromSnapshot(payload);
    if (identity.matches(_snapshotQueue.inFlight)) {
      _beginRenderCommitWatchdog(identity);
    }
  }

  void _beginRenderCommitWatchdog(_RenderCommitIdentity identity) {
    _renderCommitTimer?.cancel();
    _renderCommitTimer = null;
    _renderCommitIdentity = identity;
    if (!widget.viewportPort.isUserScrolling) {
      _armRenderCommitWatchdog(identity);
    }
  }

  void _armRenderCommitWatchdog(_RenderCommitIdentity identity) {
    _renderCommitTimer?.cancel();
    final generation = _generation;
    _renderCommitTimer = Timer(_initializationTimeout, () {
      if (_isStale(generation)) return;
      if (widget.viewportPort.isUserScrolling) {
        _pauseRenderCommitWatchdog();
        return;
      }
      if (_renderCommitIdentity?.sameAs(identity) != true ||
          !identity.matches(_snapshotQueue.inFlight)) {
        return;
      }
      debugPrint('WebConversationViewport: render commit timed out');
      _fail(
        generation,
        'render_commit_timeout',
        renderRevision: identity.renderRevision,
      );
    });
  }

  void _pauseRenderCommitWatchdog() {
    // User-controlled scrolling is not part of the Web renderer's effective
    // commit deadline. The exact in-flight identity remains resumable.
    _renderCommitTimer?.cancel();
    _renderCommitTimer = null;
  }

  void _resumeRenderCommitWatchdog() {
    if (!_ready || widget.viewportPort.isUserScrolling) return;
    final identity = _renderCommitIdentity;
    if (identity == null) return;
    if (!identity.matches(_snapshotQueue.inFlight)) {
      _clearRenderCommitWatchdog();
      return;
    }
    _armRenderCommitWatchdog(identity);
  }

  void _clearRenderCommitWatchdog() {
    _renderCommitTimer?.cancel();
    _renderCommitTimer = null;
    _renderCommitIdentity = null;
  }

  Future<void> _sendActionResult(
    String requestId, {
    required bool ok,
    String? code,
  }) => _sendEnvelope(<String, dynamic>{
    'type': 'actionResult',
    'requestId': requestId,
    'ok': ok,
    if (code != null) 'code': code,
  });

  Future<void> _sendEnvelope(Map<String, dynamic> envelope) async {
    final encoded = jsonEncode(envelope);
    try {
      if (Platform.isWindows) {
        await _windowsController?.postWebMessage(encoded);
      } else {
        await _runWebJavaScriptWithRetry(
          'window.CuplivoWeb.receive(${jsonEncode(encoded)});',
        );
      }
    } catch (error) {
      debugPrint(
        'WebConversationViewport: bridge send failed '
        '(${error.runtimeType})',
      );
      _fail(_generation, 'bridge_send_failed');
    }
  }

  Future<void> _sendViewportCommand(Map<String, dynamic> command) async {
    await _stopWebScrolling();
    await _sendEnvelope(command);
  }

  Future<void> _runWebJavaScript(String source) async {
    if (Platform.isWindows) {
      await _windowsController?.executeScript(source);
    } else if (Platform.isAndroid) {
      await _androidController?.runJavaScript(source);
    } else {
      final shellLoad = _flutterShellLoadFuture;
      if (shellLoad != null) await shellLoad;
      await _flutterController?.runJavaScript(source);
    }
  }

  /// WKWebView occasionally fails evaluateJavaScript transiently right after
  /// the shell posts `ready` (navigation and subresources still settling).
  /// Retry a few times before tearing the whole viewport down.
  Future<void> _runWebJavaScriptWithRetry(String source) async {
    final generation = _generation;
    for (var attempt = 1;; attempt++) {
      try {
        await _runWebJavaScript(source);
        return;
      } catch (error) {
        if (attempt >= 3 || _isStale(generation) || !_ready) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 80 * attempt));
      }
    }
  }

  Future<void> _stopWebScrolling() async {
    if (!_ready) return;
    try {
      if (Platform.isAndroid) {
        await _androidController?.stopScrolling();
      } else {
        await _runWebJavaScript('window.CuplivoWeb?.stopScrolling?.();');
      }
    } catch (error) {
      debugPrint(
        'WebConversationViewport: stop scrolling failed '
        '(${error.runtimeType})',
      );
    }
  }

  void _syncStreamingListeners() {
    final ids = <String>{
      for (final message in (widget.snapshot['messages'] as List? ?? const []))
        if (message is Map &&
            widget.streamingContentNotifier.hasNotifier(
              message['id']?.toString() ?? '',
            ))
          message['id']?.toString() ?? '',
    }..remove('');
    for (final id in _streamListeners.keys.toList()) {
      if (ids.contains(id)) continue;
      final binding = _streamListeners.remove(id)!;
      binding.notifier.removeListener(binding.listener);
      _streamPatchBuffer.remove(id);
    }
    for (final id in ids) {
      if (!widget.streamingContentNotifier.hasNotifier(id)) continue;
      final notifier = widget.streamingContentNotifier.getNotifier(id);
      final existing = _streamListeners[id];
      if (existing != null) {
        if (identical(existing.notifier, notifier)) continue;
        existing.notifier.removeListener(existing.listener);
      }
      void listener() {
        final patch = widget.buildStreamingPatch(id, notifier.value);
        if (patch == null) return;
        _streamPatchBuffer.enqueue(id, patch);
        _scheduleStreamingPatchFlush();
      }

      _streamListeners[id] = _StreamingListenerBinding(
        notifier: notifier,
        listener: listener,
      );
      notifier.addListener(listener);
    }
  }

  void _detachStreamingListeners() {
    for (final binding in _streamListeners.values) {
      binding.notifier.removeListener(binding.listener);
    }
    _streamListeners.clear();
  }

  void _scheduleStreamingPatchFlush() {
    if (_streamFlushTimer != null ||
        _streamPatchBuffer.inFlight ||
        _snapshotQueue.hasInFlight) {
      return;
    }
    _streamFlushTimer = Timer(const Duration(milliseconds: 16), () {
      _streamFlushTimer = null;
      unawaited(_flushStreamingPatches());
    });
  }

  Future<void> _flushStreamingPatches() async {
    if (!_ready || !_firstRenderCommitted || _snapshotQueue.hasInFlight) {
      return;
    }
    final patches = _streamPatchBuffer.takeBatch();
    if (patches == null) return;
    try {
      await _sendEnvelope(<String, dynamic>{
        'type': 'messagePatches',
        'renderSessionId': _renderSessionId,
        'conversationId': _conversationId,
        'patches': patches,
      });
    } finally {
      _streamPatchBuffer.completeBatch();
      if (_snapshotQueue.hasPending) {
        unawaited(_drainSnapshotQueue());
      } else if (_streamPatchBuffer.hasPending) {
        _scheduleStreamingPatchFlush();
      }
    }
  }

  Future<void> _openExternalUrl(String raw) async {
    final uri = Uri.tryParse(raw);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      debugPrint('WebConversationViewport: rejected external URL');
      return;
    }
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      debugPrint('WebConversationViewport: could not open external URL');
    }
  }

  void _fail(int generation, String code, {int? renderRevision}) {
    if (_isStale(generation)) return;
    final inFlightMessages = _snapshotQueue.inFlight?['messages'];
    final messages = inFlightMessages is List
        ? inFlightMessages
        : widget.snapshot['messages'];
    _failedRenderRevision =
        renderRevision ?? _renderCommitIdentity?.renderRevision;
    _failedMessageCount = messages is List ? messages.length : 0;
    _transportGeneration++;
    _streamFlushTimer?.cancel();
    _streamFlushTimer = null;
    _streamPatchBuffer.clear();
    _ready = false;
    _firstRenderCommitted = false;
    _initializing = false;
    _errorCode = code;
    _initializationTimer?.cancel();
    _clearRenderCommitWatchdog();
    _snapshotQueue.clear();
    if (mounted) setState(() {});
  }

  bool _isStale(int generation) => !mounted || generation != _generation;

  void _retry() {
    _generation++;
    _transportGeneration++;
    _streamFlushTimer?.cancel();
    _streamFlushTimer = null;
    _streamPatchBuffer.clear();
    _ready = false;
    _firstRenderCommitted = false;
    _initializing = false;
    _errorCode = null;
    _clearRenderCommitWatchdog();
    _snapshotQueue.clear();
    _lastSnapshotSignature = null;
    _lastWebDiagnosticCode = null;
    _failedRenderRevision = null;
    _failedMessageCount = null;
    unawaited(_windowsMessageSubscription?.cancel());
    _windowsMessageSubscription = null;
    final windowsController = _windowsController;
    _windowsController = null;
    if (windowsController != null) unawaited(windowsController.dispose());
    _androidController?.dispose();
    _androidController = null;
    _flutterController = null;
    _flutterShellLoadFuture = null;
    unawaited(_initialize());
  }

  @override
  Widget build(BuildContext context) {
    if (_errorCode != null) return _buildError(context);
    final Widget child;
    if (Platform.isWindows) {
      child = _windowsController == null
          ? const SizedBox.shrink()
          : winweb.Webview(
              _windowsController!,
              permissionRequested: (_, _, _) =>
                  winweb.WebviewPermissionDecision.deny,
            );
    } else if (Platform.isAndroid) {
      final generation = _generation;
      child = AndroidWebChatView(
        key: ValueKey<int>(generation),
        onPlatformViewCreated: (viewId) =>
            unawaited(_handleAndroidViewCreated(viewId, generation)),
      );
    } else {
      child = _flutterController == null
          ? const SizedBox.shrink()
          : WebViewWidget(controller: _flutterController!);
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (PointerDownEvent _) => unawaited(_stopWebScrolling()),
      child: Stack(
        fit: StackFit.expand,
        children: [
          child,
          if (!_firstRenderCommitted)
            ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: Center(
                child: Semantics(
                  label: AppLocalizations.of(context)!.webChatLoading,
                  child: const CircularProgressIndicator.adaptive(),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final diagnostics = <String, dynamic>{
      'component': 'web_conversation_viewport',
      'code': _errorCode,
      'platform': Platform.operatingSystem,
      'protocolVersion': webChatProtocolVersion,
      'assetVersion': webChatAssetVersion,
      'renderRevision': _failedRenderRevision,
      'messageCount': _failedMessageCount,
      if (_lastWebDiagnosticCode != null)
        'lastWebDiagnosticCode': _lastWebDiagnosticCode,
    };
    return ColoredBox(
      color: colors.surface,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Lucide.Globe, size: 34, color: colors.error),
                const SizedBox(height: 12),
                Text(
                  _webView2Missing
                      ? l10n.webChatWebView2Missing
                      : l10n.webChatInitializationFailed,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _ErrorAction(label: l10n.webChatRetry, onTap: _retry),
                    _ErrorAction(
                      label: l10n.webChatCopyDiagnostics,
                      onTap: () async {
                        await Clipboard.setData(
                          ClipboardData(text: jsonEncode(diagnostics)),
                        );
                        if (context.mounted) {
                          showAppSnackBar(
                            context,
                            message: l10n.webChatDiagnosticsCopied,
                          );
                        }
                      },
                    ),
                    if (_webView2Missing)
                      _ErrorAction(
                        label: l10n.webChatInstallWebView2,
                        onTap: () => unawaited(_openExternalUrl(_webView2Url)),
                      ),
                    _ErrorAction(
                      label: l10n.webChatUseFlutterThisConversation,
                      onTap: widget.onUseFlutter,
                      primary: true,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RenderCommitIdentity {
  const _RenderCommitIdentity({
    required this.renderSessionId,
    required this.conversationId,
    required this.renderRevision,
  });

  factory _RenderCommitIdentity.fromSnapshot(Map<String, dynamic> snapshot) =>
      _RenderCommitIdentity(
        renderSessionId: snapshot['renderSessionId']?.toString() ?? '',
        conversationId: snapshot['conversationId']?.toString() ?? '',
        renderRevision: (snapshot['renderRevision'] as num?)?.toInt() ?? -1,
      );

  final String renderSessionId;
  final String conversationId;
  final int renderRevision;

  bool matches(Map<String, dynamic>? snapshot) =>
      snapshot != null &&
      snapshot['renderSessionId'] == renderSessionId &&
      snapshot['conversationId'] == conversationId &&
      snapshot['renderRevision'] == renderRevision;

  bool sameAs(_RenderCommitIdentity other) =>
      renderSessionId == other.renderSessionId &&
      conversationId == other.conversationId &&
      renderRevision == other.renderRevision;
}

class _ErrorAction extends StatelessWidget {
  const _ErrorAction({
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IosCardPress(
      baseColor: primary ? colors.primary : context.appColors.surfaceFill,
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Text(
        label,
        style: TextStyle(color: primary ? colors.onPrimary : colors.onSurface),
      ),
    );
  }
}

class _StreamingListenerBinding {
  const _StreamingListenerBinding({
    required this.notifier,
    required this.listener,
  });

  final ValueNotifier<StreamingContentData> notifier;
  final VoidCallback listener;
}

class _WebChatMediaPayload {
  const _WebChatMediaPayload({required this.mime, required this.bytes});

  final String mime;
  final Uint8List bytes;
}

String _windowsMessageText(dynamic event) {
  if (event is String) return event;
  try {
    return event.content?.toString() ?? event.toString();
  } catch (error) {
    debugPrint(
      'WebConversationViewport: bridge conversion failed '
      '(${error.runtimeType})',
    );
    return event.toString();
  }
}

String _randomCapabilityToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return base64UrlEncode(bytes);
}
