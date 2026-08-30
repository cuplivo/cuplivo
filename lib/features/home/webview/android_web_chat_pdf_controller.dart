import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const String androidWebChatPdfChannelName = 'cuplivo/web_chat_pdf';

typedef AndroidWebChatPdfMessageHandler = Future<void> Function(String message);
typedef AndroidWebChatPdfResourceErrorHandler = void Function(int errorCode);
typedef AndroidWebChatPdfDiagnosticHandler = void Function(String code);

enum AndroidPdfPrintStatus {
  completed,
  cancelled,
  finished;

  static AndroidPdfPrintStatus parse(String? value) => switch (value) {
    'completed' => completed,
    'cancelled' => cancelled,
    'finished' => finished,
    _ => throw PlatformException(
      code: 'invalid_print_status',
      message: 'Android returned an unknown print status.',
      details: value,
    ),
  };
}

/// Owns the app-wide Android PDF channel for one system print task.
///
/// Android exposes only one native handler for this channel, so the Dart side
/// also rejects overlapping tasks before a second controller can replace the
/// active callback handler.
class AndroidWebChatPdfController {
  AndroidWebChatPdfController({
    required this.onMessage,
    required this.onResourceError,
    required this.onDiagnostic,
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel(androidWebChatPdfChannelName);

  static AndroidWebChatPdfController? _active;

  final AndroidWebChatPdfMessageHandler onMessage;
  final AndroidWebChatPdfResourceErrorHandler onResourceError;
  final AndroidWebChatPdfDiagnosticHandler onDiagnostic;
  final MethodChannel _channel;

  bool _started = false;
  bool _disposed = false;

  Future<void> start() async {
    if (_disposed) {
      throw StateError('Android Web chat PDF controller is disposed.');
    }
    if (_started) return;
    if (_active != null) {
      throw PlatformException(
        code: 'busy',
        message: 'Another Android PDF print task is already active.',
      );
    }

    _active = this;
    _channel.setMethodCallHandler(_handleMethodCall);
    _started = true;
    try {
      await _channel.invokeMethod<void>('start');
    } catch (_) {
      _releaseHandler();
      rethrow;
    }
  }

  Future<void> postEnvelope(Map<String, dynamic> envelope) =>
      _invoke<void>('postEnvelope', jsonEncode(envelope));

  Future<AndroidPdfPrintStatus> print({required String documentName}) async {
    final status = await _invoke<String>('print', <String, Object?>{
      'documentName': documentName,
    });
    return AndroidPdfPrintStatus.parse(status);
  }

  Future<T?> _invoke<T>(String method, [Object? arguments]) {
    if (_disposed) {
      throw StateError('Android Web chat PDF controller is disposed.');
    }
    if (!_started) {
      throw StateError('Android Web chat PDF controller has not started.');
    }
    return _channel.invokeMethod<T>(method, arguments);
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (_disposed) return null;
    switch (call.method) {
      case 'bridgeMessage':
        final message = call.arguments;
        if (message is String) await onMessage(message);
        return null;
      case 'resourceError':
        final errorCode = call.arguments;
        if (errorCode is int) onResourceError(errorCode);
        return null;
      case 'diagnostic':
        final code = call.arguments;
        if (code is String) onDiagnostic(code);
        return null;
      default:
        debugPrint(
          'AndroidWebChatPdfController: ignored native method ${call.method}',
        );
        return null;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      if (_started) await _channel.invokeMethod<void>('dispose');
    } catch (error) {
      debugPrint(
        'AndroidWebChatPdfController: native dispose failed '
        '(${error.runtimeType})',
      );
    } finally {
      _releaseHandler();
    }
  }

  void _releaseHandler() {
    _channel.setMethodCallHandler(null);
    if (identical(_active, this)) _active = null;
    _started = false;
  }
}
