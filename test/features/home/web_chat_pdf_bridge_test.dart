import 'dart:convert';

import 'package:Cuplivo/features/home/webview/web_chat_pdf_bridge.dart';
import 'package:Cuplivo/features/home/webview/web_chat_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  const sessionId = 'pdf-session';
  const conversationId = 'conversation';
  const token = 'capability';

  Map<String, dynamic> envelope(
    String type, {
    String capabilityToken = token,
    String renderSessionId = sessionId,
    String targetConversationId = conversationId,
    bool timedOut = false,
  }) => <String, dynamic>{
    'type': type,
    'protocolVersion': webChatProtocolVersion,
    'assetVersion': webChatAssetVersion,
    'capabilityToken': capabilityToken,
    'renderSessionId': renderSessionId,
    'conversationId': targetConversationId,
    if (timedOut) 'timedOut': true,
  };

  test(
    'ready sends one chunked snapshot containing the capability token',
    () async {
      final sent = <Map<String, dynamic>>[];
      final failures = <Object>[];
      final coordinator = WebChatPdfBridgeCoordinator(
        renderSessionId: sessionId,
        conversationId: conversationId,
        capabilityToken: token,
        snapshot: <String, dynamic>{
          'type': 'snapshot',
          'payload': List<String>.filled(120000, 'x').join(),
        },
        mediaRegistry: const {},
        clientFactory: http.Client.new,
        sendEnvelope: (message) async => sent.add(message),
        onRenderComplete: (_) async {},
        onFailure: failures.add,
      );

      final ready = envelope('ready');
      await coordinator.handleMessage(jsonEncode(ready));
      await coordinator.handleMessage(jsonEncode(ready));

      expect(sent.length, greaterThan(1));
      expect(sent.every((item) => item['type'] == 'transferChunk'), isTrue);
      final encoded = sent
          .map((item) => base64Decode(item['data']! as String))
          .expand((bytes) => bytes)
          .toList();
      final snapshot = jsonDecode(utf8.decode(encoded)) as Map<String, dynamic>;
      expect(snapshot['capabilityToken'], token);
      expect(failures, isEmpty);
    },
  );

  test(
    'forged token and stale session cannot complete the print render',
    () async {
      final completed = <bool>[];
      final coordinator = WebChatPdfBridgeCoordinator(
        renderSessionId: sessionId,
        conversationId: conversationId,
        capabilityToken: token,
        snapshot: const <String, dynamic>{'type': 'snapshot'},
        mediaRegistry: const {},
        clientFactory: http.Client.new,
        sendEnvelope: (_) async {},
        onRenderComplete: (timedOut) async => completed.add(timedOut),
        onFailure: (_) {},
      );

      await coordinator.handleMessage(
        jsonEncode(envelope('printRenderComplete', capabilityToken: 'forged')),
      );
      await coordinator.handleMessage(
        jsonEncode(envelope('printRenderComplete', renderSessionId: 'stale')),
      );
      await coordinator.handleMessage(
        jsonEncode(
          envelope('printRenderComplete', targetConversationId: 'different'),
        ),
      );
      expect(completed, isEmpty);

      final valid = envelope('printRenderComplete', timedOut: true);
      await coordinator.handleMessage(jsonEncode(valid));
      await coordinator.handleMessage(jsonEncode(valid));
      expect(completed, <bool>[true]);
    },
  );

  test(
    'unknown media is answered explicitly and dispose is idempotent',
    () async {
      final sent = <Map<String, dynamic>>[];
      final coordinator = WebChatPdfBridgeCoordinator(
        renderSessionId: sessionId,
        conversationId: conversationId,
        capabilityToken: token,
        snapshot: const <String, dynamic>{'type': 'snapshot'},
        mediaRegistry: const {},
        clientFactory: http.Client.new,
        sendEnvelope: (message) async => sent.add(message),
        onRenderComplete: (_) async {},
        onFailure: (_) {},
      );
      final request = envelope('mediaRequest')..['handle'] = 'missing';

      await coordinator.handleMessage(jsonEncode(request));
      expect(sent.single, <String, dynamic>{
        'type': 'mediaError',
        'renderSessionId': sessionId,
        'conversationId': conversationId,
        'handle': 'missing',
      });

      coordinator.dispose();
      coordinator.dispose();
      await coordinator.handleMessage(jsonEncode(envelope('ready')));
      expect(sent, hasLength(1));
    },
  );

  test('protocol mismatch and envelope write failure are reported', () async {
    final failures = <Object>[];
    final coordinator = WebChatPdfBridgeCoordinator(
      renderSessionId: sessionId,
      conversationId: conversationId,
      capabilityToken: token,
      snapshot: const <String, dynamic>{'type': 'snapshot'},
      mediaRegistry: const {},
      clientFactory: http.Client.new,
      sendEnvelope: (_) async => throw StateError('write failed'),
      onRenderComplete: (_) async {},
      onFailure: failures.add,
    );

    final mismatch = envelope('ready')..['assetVersion'] = 'stale';
    await coordinator.handleMessage(jsonEncode(mismatch));
    await coordinator.handleMessage(jsonEncode(envelope('ready')));

    expect(failures, hasLength(2));
    expect(failures.first, isA<WebChatProtocolException>());
    expect(failures.last, isA<StateError>());
  });
}
