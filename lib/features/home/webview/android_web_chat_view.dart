import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

typedef AndroidWebChatMessageHandler = void Function(String message);
typedef AndroidWebChatResourceErrorHandler = void Function(int errorCode);
typedef AndroidWebChatNavigationHandler = void Function(String url);
typedef AndroidWebChatDiagnosticHandler = void Function(String code);

class AndroidWebChatController {
  AndroidWebChatController._({
    required int viewId,
    required AndroidWebChatMessageHandler onMessage,
    required AndroidWebChatResourceErrorHandler onResourceError,
    required AndroidWebChatNavigationHandler onNavigationRequest,
    required AndroidWebChatDiagnosticHandler onDiagnostic,
  }) : _channel = MethodChannel('cuplivo/web_chat/$viewId') {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'bridgeMessage':
          final message = call.arguments;
          if (message is String) onMessage(message);
        case 'resourceError':
          final errorCode = call.arguments;
          if (errorCode is int) onResourceError(errorCode);
        case 'navigationRequest':
          final url = call.arguments;
          if (url is String) onNavigationRequest(url);
        case 'diagnostic':
          final code = call.arguments;
          if (code is String) onDiagnostic(code);
      }
    });
  }

  final MethodChannel _channel;
  bool _disposed = false;

  static AndroidWebChatController attach({
    required int viewId,
    required AndroidWebChatMessageHandler onMessage,
    required AndroidWebChatResourceErrorHandler onResourceError,
    required AndroidWebChatNavigationHandler onNavigationRequest,
    required AndroidWebChatDiagnosticHandler onDiagnostic,
  }) => AndroidWebChatController._(
    viewId: viewId,
    onMessage: onMessage,
    onResourceError: onResourceError,
    onNavigationRequest: onNavigationRequest,
    onDiagnostic: onDiagnostic,
  );

  Future<void> loadShell() => _invoke('loadShell');

  Future<void> runJavaScript(String source) => _invoke('runJavaScript', source);

  Future<void> stopScrolling([String origin = 'programmatic']) =>
      _invoke('stopScrolling', origin);

  Future<void> _invoke(String method, [Object? arguments]) async {
    if (_disposed) {
      throw StateError('Android Web chat controller is disposed.');
    }
    await _channel.invokeMethod<void>(method, arguments);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _channel.setMethodCallHandler(null);
  }
}

class AndroidWebChatView extends StatelessWidget {
  const AndroidWebChatView({super.key, required this.onPlatformViewCreated});

  static const String viewType = 'cuplivo/web_chat';

  final PlatformViewCreatedCallback onPlatformViewCreated;

  @override
  Widget build(BuildContext context) => AndroidView(
    viewType: viewType,
    layoutDirection: Directionality.of(context),
    onPlatformViewCreated: onPlatformViewCreated,
    gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
      Factory<OneSequenceGestureRecognizer>(VerticalDragGestureRecognizer.new),
    },
  );
}
