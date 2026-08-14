import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/streaming_content_notifier.dart';
import '../../home/controllers/chat_transcript_viewport.dart';
import 'web_transcript_models.dart';
import 'web_transcript_resource_proxy.dart';
import 'web_transcript_session.dart';

typedef WebTranscriptSnapshotBuilder =
    WebTranscriptSnapshot Function(Map<String, ChatMessage> overrides);

class WebTranscriptView extends StatefulWidget {
  const WebTranscriptView({
    super.key,
    required this.snapshotBuilder,
    required this.streamingContentNotifier,
    required this.topContentPadding,
    required this.bottomContentPadding,
    required this.loadingLabel,
    required this.backgroundSource,
    required this.onFatal,
    required this.onAction,
    required this.onOpenPreparedImages,
    required this.onViewportChanged,
    required this.onLoadMoreBefore,
    required this.onLoadMoreAfter,
  });

  final WebTranscriptSnapshotBuilder snapshotBuilder;
  final StreamingContentNotifier streamingContentNotifier;
  final double topContentPadding;
  final double bottomContentPadding;
  final String loadingLabel;
  final String? backgroundSource;
  final void Function(Object error) onFatal;
  final void Function(
    String action,
    String? messageId,
    String? href,
    String? resourceId,
    String? value,
  )
  onAction;
  final void Function(
    String resourceId,
    Map<String, WebTranscriptResourceData> resources,
  )
  onOpenPreparedImages;
  final void Function(ChatTranscriptViewport viewport, bool attached)
  onViewportChanged;
  final bool Function() onLoadMoreBefore;
  final bool Function() onLoadMoreAfter;

  @override
  State<WebTranscriptView> createState() => WebTranscriptViewState();
}

class WebTranscriptViewState extends State<WebTranscriptView>
    with WidgetsBindingObserver
    implements ChatTranscriptViewport {
  static const int _resourceChunkBytes = 48 * 1024;
  static const int _maxResourceRequestsPerEpoch = 32;
  static const int _maxResourceBytesPerEpoch = 32 * 1024 * 1024;

  WebViewController? _controller;
  WebTranscriptSession? _session;
  late WebTranscriptResourceProxy _resourceProxy;
  late WebTranscriptSnapshot _snapshot;
  final Map<String, VoidCallback> _streamListeners = <String, VoidCallback>{};
  final Set<String> _patchInFlight = <String>{};
  final Map<String, WebTranscriptMessage> _queuedPatches =
      <String, WebTranscriptMessage>{};
  final Set<String> _resourceLoads = <String>{};
  final Map<String, WebTranscriptResourceData> _loadedResources =
      <String, WebTranscriptResourceData>{};
  Timer? _readyTimer;
  bool _ready = false;
  bool _failed = false;
  bool _nearBottom = true;
  bool _userScrolling = false;
  String? _firstVisibleMessageId;
  bool _loadingBefore = false;
  bool _loadingAfter = false;
  bool _disposed = false;
  int _initializeGeneration = 0;
  int _resourceRequestCount = 0;
  int _resourceBytes = 0;
  String? _lastSentSnapshot;
  String? _lastThemeAndSettings;

  @override
  bool get isReady => _ready && !_failed;

  @override
  bool get isNearBottom => _nearBottom;

  @override
  bool get isUserScrolling => _userScrolling;

  @override
  String? get firstVisibleMessageId => _firstVisibleMessageId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resourceProxy = WebTranscriptResourceProxy();
    _snapshot = _buildSnapshot();
    _syncStreamListeners();
    unawaited(_initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !isReady) return;
    _snapshot = _buildSnapshot();
    _runInBackground(
      _sendTranscriptIfChanged(fatalOnFailure: true, force: true),
    );
    _runInBackground(_sendThemeAndSettings(fatalOnFailure: true));
  }

  @override
  void didUpdateWidget(covariant WebTranscriptView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previousConversation = _snapshot.conversationId;
    _snapshot = _buildSnapshot();
    _syncStreamListeners();
    if (!isReady) return;
    if (_snapshot.conversationId != previousConversation) {
      _ready = false;
      _session!.startNewEpoch();
      _resetEpochResources();
      _lastSentSnapshot = null;
      _lastThemeAndSettings = null;
      _runInBackground(_replaceChangedConversation());
      return;
    }
    _runInBackground(_replaceTranscript(fatalOnFailure: true));
    _runInBackground(_sendThemeAndSettings());
  }

  WebTranscriptSnapshot _buildSnapshot([
    Map<String, ChatMessage> overrides = const <String, ChatMessage>{},
  ]) {
    final snapshot = widget.snapshotBuilder(overrides);
    final background = widget.backgroundSource?.trim();
    if (background == null || background.isEmpty) return snapshot;
    final backgroundId =
        'chat-background-${sha256.convert(utf8.encode(background)).toString().substring(0, 12)}';
    return WebTranscriptSnapshot(
      conversationId: snapshot.conversationId,
      messages: snapshot.messages,
      resources: <String, WebTranscriptResource>{
        ...snapshot.resources,
        backgroundId: WebTranscriptResource(
          id: backgroundId,
          source: background,
          kind: WebTranscriptResourceKind.background,
        ),
      },
      hasMoreBefore: snapshot.hasMoreBefore,
      hasMoreAfter: snapshot.hasMoreAfter,
    );
  }

  Future<void> _initialize() async {
    final generation = ++_initializeGeneration;
    try {
      final controller = WebViewController();
      if (_isInitializationStale(generation)) return;
      _controller = controller;
      _session = WebTranscriptSession(
        sendEncoded: (encoded) => controller.runJavaScript(
          "window.CuplivoTranscript.postCommand('$encoded')",
        ),
        onEvent: _handleEvent,
        onFatal: _fail,
      );
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (_isInitializationStale(generation)) return;
      await controller.addJavaScriptChannel(
        'CuplivoBridge',
        onMessageReceived: (message) => _session?.receive(message.message),
      );
      if (_isInitializationStale(generation)) return;
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            final isAsset =
                uri != null &&
                (uri.scheme == 'file' ||
                    uri.scheme == 'flutter-asset' ||
                    request.url.contains('assets/web_transcript/'));
            return isAsset
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true) {
              _fail(StateError('Web transcript asset load failed'));
            }
          },
        ),
      );
      if (_isInitializationStale(generation)) return;
      _readyTimer = Timer(
        const Duration(seconds: 10),
        () => _fail(TimeoutException('Web transcript did not become ready')),
      );
      await controller.loadFlutterAsset('assets/web_transcript/index.html');
      if (_isInitializationStale(generation)) return;
      setState(() {});
    } catch (error) {
      _fail(error);
    }
  }

  bool _isInitializationStale(int generation) {
    return _disposed || !mounted || generation != _initializeGeneration;
  }

  void _handleEvent(WebTranscriptBridgeEvent event) {
    switch (event.type) {
      case 'ready':
        unawaited(_startSession());
      case 'viewport':
        _handleViewport(event.payload);
      case 'resourceRequest':
        final id = event.payload['resourceId'];
        if (id is String) unawaited(_sendResource(id, event.epoch));
      case 'action':
        final action = event.payload['action'] as String? ?? '';
        final resourceId = event.payload['resourceId'] as String?;
        if (action == 'openResource' &&
            resourceId != null &&
            _loadedResources.containsKey(resourceId)) {
          widget.onOpenPreparedImages(
            resourceId,
            Map<String, WebTranscriptResourceData>.unmodifiable(
              _loadedResources,
            ),
          );
          return;
        }
        widget.onAction(
          action,
          event.payload['messageId'] as String?,
          event.payload['href'] as String?,
          event.payload['resourceId'] as String?,
          event.payload['value'] as String?,
        );
      case 'error':
        debugPrint('[WebTranscript] JS error code=${event.payload['code']}');
    }
  }

  Future<void> _startSession() async {
    if (_disposed || _failed || _ready) return;
    try {
      _session!.startNewEpoch();
      final epoch = _session!.epoch;
      _resetEpochResources();
      await _session!.send(
        'hello',
        const <String, Object?>{},
        fatalOnFailure: true,
      );
      await _replaceTranscript(fatalOnFailure: true);
      await _sendThemeAndSettings(fatalOnFailure: true);
      await _replaceTranscript(fatalOnFailure: true);
      if (_disposed || !mounted || _session!.epoch != epoch) return;
      _readyTimer?.cancel();
      _ready = true;
      widget.onViewportChanged(this, true);
      if (mounted) setState(() {});
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> _replaceTranscript({bool fatalOnFailure = false}) {
    return _sendTranscriptIfChanged(fatalOnFailure: fatalOnFailure);
  }

  Future<void> _sendTranscriptIfChanged({
    required bool fatalOnFailure,
    bool force = false,
  }) async {
    final serialized = jsonEncode(_snapshot.toJson());
    if (!force && serialized == _lastSentSnapshot) return;
    await _session!.send(
      'replaceTranscript',
      _snapshot.toJson(),
      fatalOnFailure: fatalOnFailure,
    );
    _lastSentSnapshot = serialized;
  }

  Future<void> _replaceChangedConversation() async {
    final epoch = _session!.epoch;
    try {
      await _sendTranscriptIfChanged(fatalOnFailure: true, force: true);
      await _sendThemeAndSettings(fatalOnFailure: true);
      await _sendTranscriptIfChanged(fatalOnFailure: true);
      if (_disposed || _failed || _session!.epoch != epoch) return;
      _ready = true;
      if (mounted) setState(() {});
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> _sendThemeAndSettings({bool fatalOnFailure = false}) async {
    if (_session == null || !mounted) return;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final settings = context.read<SettingsProvider>();
    final backgroundResourceId = _snapshot.resources.values
        .where(
          (resource) => resource.kind == WebTranscriptResourceKind.background,
        )
        .firstOrNull
        ?.id;
    final themePayload = <String, Object?>{
      'scheme': theme.brightness == Brightness.dark ? 'dark' : 'light',
      'fontScale': settings.chatFontScale.clamp(0.75, 2.0),
      'topPadding': widget.topContentPadding,
      'bottomPadding': widget.bottomContentPadding,
      'backgroundMask': settings.chatBackgroundMaskStrength,
      'languageCode': Localizations.localeOf(context).toLanguageTag(),
      'fontFamily': settings.appFontFamily,
      'codeFontFamily': settings.codeFontFamily,
      'backgroundResourceId': backgroundResourceId,
      'colors': <String, String>{
        'background': _hex(colors.surface),
        'foreground': _hex(colors.onSurface),
        'muted': _hex(colors.onSurfaceVariant),
        'accent': _hex(colors.primary),
        'codeBackground': _hex(colors.surfaceContainerHighest),
        'border': _hex(colors.outlineVariant),
      },
    };
    final settingsPayload = <String, Object?>{
      'mathEnabled': settings.enableMathRendering,
      'dollarMathEnabled': settings.enableDollarLatex,
      'autoScrollEnabled': settings.autoScrollEnabled,
    };
    final signature = jsonEncode(<String, Object?>{
      'epoch': _session!.epoch,
      'settings': settingsPayload,
      'theme': themePayload,
    });
    if (signature == _lastThemeAndSettings) return;
    await _session!.send('theme', themePayload, fatalOnFailure: fatalOnFailure);
    await _session!.send(
      'renderSettings',
      settingsPayload,
      fatalOnFailure: fatalOnFailure,
    );
    _lastThemeAndSettings = signature;
  }

  String _hex(Color color) {
    final value = color.toARGB32();
    return '#${(value & 0x00ffffff).toRadixString(16).padLeft(6, '0')}';
  }

  void _syncStreamListeners() {
    final active = _snapshot.messages
        .where((message) => message.source.isStreaming)
        .map((message) => message.source.id)
        .toSet();
    for (final entry in _streamListeners.entries.toList()) {
      if (active.contains(entry.key)) continue;
      if (widget.streamingContentNotifier.hasNotifier(entry.key)) {
        widget.streamingContentNotifier
            .getNotifier(entry.key)
            .removeListener(entry.value);
      }
      _streamListeners.remove(entry.key);
    }
    for (final id in active) {
      if (_streamListeners.containsKey(id)) continue;
      final notifier = widget.streamingContentNotifier.getNotifier(id);
      void listener() => _onStreamingUpdate(id, notifier.value);
      notifier.addListener(listener);
      _streamListeners[id] = listener;
    }
  }

  void _onStreamingUpdate(String id, StreamingContentData data) {
    if (!isReady) return;
    final existing = _snapshot.messages
        .where((message) => message.source.id == id)
        .firstOrNull;
    if (existing == null) return;
    var updated = existing.source.copyWith(
      content: data.content.isNotEmpty ? data.content : existing.source.content,
      totalTokens: data.totalTokens > 0
          ? data.totalTokens
          : existing.source.totalTokens,
    );
    if (data.reasoningText != null) {
      updated = updated.copyWith(reasoningText: data.reasoningText);
    }
    if (data.reasoningStartAt != null) {
      updated = updated.copyWith(reasoningStartAt: data.reasoningStartAt);
    }
    if (data.reasoningFinishedAt != null) {
      updated = updated.copyWith(reasoningFinishedAt: data.reasoningFinishedAt);
    }
    _snapshot = _buildSnapshot(<String, ChatMessage>{id: updated});
    final projected = _snapshot.messages
        .where((message) => message.source.id == id)
        .firstOrNull;
    if (projected != null) _queuePatch(projected);
  }

  void _queuePatch(WebTranscriptMessage message) {
    final id = message.source.id;
    if (_patchInFlight.contains(id)) {
      _queuedPatches[id] = message;
      return;
    }
    _patchInFlight.add(id);
    final epoch = _session!.epoch;
    unawaited(
      _session!
          .send('patchMessage', <String, Object?>{'message': message.toJson()})
          .catchError((Object error) {
            debugPrint('[WebTranscript] patch failed: $error');
          })
          .whenComplete(() {
            _patchInFlight.remove(id);
            if (!isReady || _session!.epoch != epoch) return;
            final queued = _queuedPatches.remove(id);
            if (queued != null) _queuePatch(queued);
          }),
    );
  }

  void _handleViewport(Map<String, dynamic> payload) {
    final scrollTop = (payload['scrollTop'] as num?)?.toDouble() ?? 0;
    final viewportHeight = (payload['viewportHeight'] as num?)?.toDouble() ?? 0;
    final contentHeight = (payload['contentHeight'] as num?)?.toDouble() ?? 0;
    _nearBottom = contentHeight - scrollTop - viewportHeight <= 48;
    _userScrolling = payload['isScrolling'] == true;
    _firstVisibleMessageId = payload['firstVisibleMessageId'] as String?;
    if (scrollTop <= 96 && _snapshot.hasMoreBefore && !_loadingBefore) {
      final epoch = _session?.epoch;
      _loadingBefore = true;
      if (widget.onLoadMoreBefore()) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _disposed || epoch != _session?.epoch) {
            _loadingBefore = false;
            return;
          }
          _snapshot = _buildSnapshot();
          if (isReady) {
            _runInBackground(_replaceTranscript(fatalOnFailure: true));
          }
          _loadingBefore = false;
        });
      } else {
        _loadingBefore = false;
      }
    }
    if (contentHeight - scrollTop - viewportHeight <= 96 &&
        _snapshot.hasMoreAfter &&
        !_loadingAfter) {
      final epoch = _session?.epoch;
      _loadingAfter = true;
      if (widget.onLoadMoreAfter()) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _disposed || epoch != _session?.epoch) {
            _loadingAfter = false;
            return;
          }
          _snapshot = _buildSnapshot();
          if (isReady) {
            _runInBackground(_replaceTranscript(fatalOnFailure: true));
          }
          _loadingAfter = false;
        });
      } else {
        _loadingAfter = false;
      }
    }
  }

  Future<void> _sendResource(String id, int epoch) async {
    if (_resourceLoads.contains(id) || epoch != _session?.epoch) return;
    if (_resourceRequestCount >= _maxResourceRequestsPerEpoch) {
      debugPrint('[WebTranscript] resource request limit reached');
      return;
    }
    final resource = _snapshot.resources[id];
    if (resource == null ||
        resource.kind == WebTranscriptResourceKind.attachment) {
      return;
    }
    _resourceLoads.add(id);
    _resourceRequestCount++;
    try {
      final data = await _resourceProxy.load(resource);
      if (_failed || epoch != _session!.epoch) return;
      if (_resourceBytes + data.bytes.length > _maxResourceBytesPerEpoch) {
        throw const WebTranscriptResourceException('epoch_resource_limit');
      }
      _resourceBytes += data.bytes.length;
      _loadedResources[id] = data;
      final chunks = _chunks(data.bytes, _resourceChunkBytes);
      final transferId = '$epoch:$id';
      for (var index = 0; index < chunks.length; index++) {
        if (_failed || epoch != _session!.epoch) return;
        await _session!.send('resourceChunk', <String, Object?>{
          'resourceId': id,
          'transferId': transferId,
          'index': index,
          'totalChunks': chunks.length,
          'mimeType': data.mimeType,
          'data': base64Encode(chunks[index]),
        });
      }
    } catch (error) {
      debugPrint('[WebTranscript] resource unavailable id=$id error=$error');
      if (resource.kind == WebTranscriptResourceKind.background) {
        _fail(error);
      }
    } finally {
      _resourceLoads.remove(id);
    }
  }

  List<Uint8List> _chunks(Uint8List bytes, int size) {
    final result = <Uint8List>[];
    for (var offset = 0; offset < bytes.length; offset += size) {
      result.add(
        Uint8List.sublistView(
          bytes,
          offset,
          (offset + size).clamp(0, bytes.length).toInt(),
        ),
      );
    }
    return result;
  }

  void _resetEpochResources() {
    _resourceLoads.clear();
    _loadedResources.clear();
    _resourceRequestCount = 0;
    _resourceBytes = 0;
    _patchInFlight.clear();
    _queuedPatches.clear();
  }

  void _runInBackground(Future<void> future) {
    unawaited(
      future.catchError((Object error) {
        debugPrint('[WebTranscript] background command failed: $error');
      }),
    );
  }

  void _fail(Object error) {
    if (_disposed || _failed) return;
    _failed = true;
    _ready = false;
    _readyTimer?.cancel();
    widget.onViewportChanged(this, false);
    debugPrint('[WebTranscript] fatal error: $error');
    widget.onFatal(error);
  }

  @override
  Future<void> scrollToMessage(String messageId, {String block = 'nearest'}) {
    if (!isReady) return Future<void>.value();
    return _session!.send('scrollToMessage', <String, Object?>{
      'messageId': messageId,
      'block': block,
    });
  }

  @override
  Future<void> scrollToTop() {
    if (!isReady) return Future<void>.value();
    return _session!.send('scrollToTop', const <String, Object?>{});
  }

  @override
  Future<void> scrollToBottom() {
    if (!isReady) return Future<void>.value();
    return _session!.send('scrollToBottom', const <String, Object?>{});
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return Center(child: Text(widget.loadingLabel));
    }
    return Stack(
      children: [
        Positioned.fill(child: WebViewWidget(controller: controller)),
        if (!_ready)
          Positioned.fill(
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: Center(child: Text(widget.loadingLabel)),
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _ready = false;
    _initializeGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    _readyTimer?.cancel();
    widget.onViewportChanged(this, false);
    for (final entry in _streamListeners.entries) {
      if (widget.streamingContentNotifier.hasNotifier(entry.key)) {
        widget.streamingContentNotifier
            .getNotifier(entry.key)
            .removeListener(entry.value);
      }
    }
    _streamListeners.clear();
    _session?.dispose();
    _resourceProxy.dispose();
    super.dispose();
  }
}
