import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../utils/sandbox_path_resolver.dart';
import 'web_chat_protocol.dart';
import 'web_chat_remote_media.dart';
import 'web_chat_snapshot.dart';

typedef WebChatPdfEnvelopeSender =
    Future<void> Function(Map<String, dynamic> envelope);
typedef WebChatPdfRenderCompleteHandler = Future<void> Function(bool timedOut);
typedef WebChatPdfFailureHandler = void Function(Object error);

/// Shared snapshot/media bridge used by the Windows and Android PDF engines.
class WebChatPdfBridgeCoordinator {
  WebChatPdfBridgeCoordinator({
    required this.renderSessionId,
    required this.conversationId,
    required this.capabilityToken,
    required this.snapshot,
    required this.mediaRegistry,
    required this.clientFactory,
    required this.sendEnvelope,
    required this.onRenderComplete,
    required this.onFailure,
  });

  final String renderSessionId;
  final String conversationId;
  final String capabilityToken;
  final Map<String, dynamic> snapshot;
  final Map<String, WebChatMediaSource> mediaRegistry;
  final WebChatHttpClientFactory clientFactory;
  final WebChatPdfEnvelopeSender sendEnvelope;
  final WebChatPdfRenderCompleteHandler onRenderComplete;
  final WebChatPdfFailureHandler onFailure;

  bool _snapshotSent = false;
  bool _renderCompleted = false;
  bool _disposed = false;

  Future<void> handleMessage(String raw) async {
    if (_disposed) return;
    Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('bridge payload is not an object');
      }
      message = decoded.map((key, value) => MapEntry(key.toString(), value));
    } catch (error) {
      debugPrint(
        'WebChatPdfBridgeCoordinator: malformed bridge message '
        '(${error.runtimeType})',
      );
      return;
    }

    try {
      switch (message['type']) {
        case 'ready':
          if (message['protocolVersion'] != webChatProtocolVersion ||
              message['assetVersion'] != webChatAssetVersion) {
            _fail(
              const WebChatProtocolException('PDF shell protocol mismatch'),
            );
            return;
          }
          await _sendSnapshot();
          return;
        case 'mediaRequest':
          if (!_isAuthorized(message)) {
            debugPrint('WebChatPdfBridgeCoordinator: rejected media request');
            return;
          }
          await _answerMediaRequest(message);
          return;
        case 'printRenderComplete':
          if (!_isAuthorized(message) || _renderCompleted) {
            debugPrint(
              'WebChatPdfBridgeCoordinator: ignored stale print completion',
            );
            return;
          }
          _renderCompleted = true;
          final timedOut = message['timedOut'] == true;
          if (timedOut) {
            debugPrint(
              'WebChatPdfBridgeCoordinator: print render completed with '
              'incomplete media or renderers',
            );
          }
          await onRenderComplete(timedOut);
          return;
        case 'diagnostic':
          debugPrint(
            'WebChatPdfBridgeCoordinator: shell diagnostic '
            '${message['code'] ?? message}',
          );
          return;
      }
    } catch (error) {
      _fail(error);
    }
  }

  bool _isAuthorized(Map<String, dynamic> message) =>
      message['capabilityToken'] == capabilityToken &&
      message['renderSessionId'] == renderSessionId &&
      message['conversationId'] == conversationId;

  Future<void> _sendSnapshot() async {
    if (_snapshotSent || _disposed) return;
    _snapshotSent = true;
    final payload = Map<String, dynamic>.of(snapshot)
      ..['capabilityToken'] = capabilityToken;
    for (final chunk in chunkWebChatEnvelope(
      payload: payload,
      transferId: 'pdf-snapshot:$renderSessionId',
    )) {
      if (_disposed) return;
      await sendEnvelope(chunk);
    }
  }

  Future<void> _answerMediaRequest(Map<String, dynamic> message) async {
    final handle = message['handle']?.toString() ?? '';
    final source = mediaRegistry[handle];
    if (source == null) {
      await _sendMediaError(handle);
      return;
    }
    try {
      String mime;
      Uint8List bytes;
      if (source.kind == WebChatMediaSourceKind.remoteImage) {
        final remote = await WebChatRemoteImageLoader(
          clientFactory: clientFactory,
        ).load(source.value);
        mime = remote.mime;
        bytes = remote.bytes;
      } else {
        final extension = source.value.toLowerCase().split('.').last;
        mime = switch (extension) {
          'png' => 'image/png',
          'jpg' || 'jpeg' => 'image/jpeg',
          'gif' => 'image/gif',
          'webp' => 'image/webp',
          'svg' when source.kind == WebChatMediaSourceKind.bundledAsset =>
            'image/svg+xml',
          _ => '',
        };
        if (mime.isEmpty) {
          await _sendMediaError(handle);
          return;
        }
        bytes = switch (source.kind) {
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
      }
      final payload = <String, dynamic>{
        'type': 'mediaResult',
        'renderSessionId': renderSessionId,
        'conversationId': conversationId,
        'handle': handle,
        'dataUrl': 'data:$mime;base64,${base64Encode(bytes)}',
      };
      for (final chunk in chunkWebChatEnvelope(
        payload: payload,
        transferId: 'pdf-media:$renderSessionId:${handle.hashCode}',
      )) {
        if (_disposed) return;
        await sendEnvelope(chunk);
      }
    } catch (error) {
      debugPrint(
        'WebChatPdfBridgeCoordinator: media request failed for $handle '
        '(${error.runtimeType}: $error)',
      );
      await _sendMediaError(handle);
    }
  }

  Future<void> _sendMediaError(String handle) async {
    if (_disposed) return;
    await sendEnvelope(<String, dynamic>{
      'type': 'mediaError',
      'renderSessionId': renderSessionId,
      'conversationId': conversationId,
      'handle': handle,
    });
  }

  void _fail(Object error) {
    if (_disposed) return;
    onFailure(error);
  }

  void dispose() {
    _disposed = true;
  }
}

Future<Uint8List> _readLocalMedia(String path) async {
  final resolvedPath = SandboxPathResolver.fix(path);
  final file = File(resolvedPath);
  if (!await file.exists()) {
    throw const FileSystemException('media file does not exist');
  }
  final length = await file.length();
  if (length > webChatMediaMaxBytes) {
    throw const WebChatProtocolException('local media exceeds size limit');
  }
  final bytes = await file.readAsBytes();
  if (bytes.length > webChatMediaMaxBytes) {
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
