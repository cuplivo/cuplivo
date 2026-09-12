import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';

ProviderConfig _config(String baseUrl) {
  return ProviderConfig(
    id: 'GeminiImageParityTest',
    enabled: true,
    name: 'GeminiImageParityTest',
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.google,
  );
}

/// Sends one user message through the Gemini path and returns the captured
/// request body.
Future<Map<String, dynamic>> _captureRequestBody(
  String content, {
  required bool stream,
}) async {
  Map<String, dynamic>? body;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));

  server.listen((request) async {
    body = (jsonDecode(await utf8.decoder.bind(request).join()) as Map)
        .cast<String, dynamic>();
    request.response.statusCode = HttpStatus.ok;
    const responseChunk = {
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': 'ok'},
            ],
          },
        },
      ],
    };
    if (stream) {
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.write('data: ${jsonEncode(responseChunk)}\n\n');
      request.response.write('data: [DONE]');
    } else {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(responseChunk));
    }
    await request.response.close();
  });

  await ChatApiService.sendMessageStream(
    config: _config('http://${server.address.address}:${server.port}/v1beta'),
    modelId: 'gemini-2.5-pro',
    messages: [
      {'role': 'user', 'content': content},
    ],
    stream: stream,
  ).toList();

  expect(body, isNotNull);
  return body!;
}

List<Map<String, dynamic>> _firstMessageParts(Map<String, dynamic> body) {
  final contents = (body['contents'] as List).cast<Map>();
  return (contents.first['parts'] as List)
      .cast<Map>()
      .map((part) => part.cast<String, dynamic>())
      .toList(growable: false);
}

void main() {
  test(
    'Gemini non-stream and stream encode a local image identically',
    () async {
      final dir = await Directory.systemTemp.createTemp('gemini_img_parity_');
      addTearDown(() async {
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      });
      final file = File('${dir.path}/sample.png');
      await file.writeAsBytes(const [1, 2, 3, 4]);
      final content = 'look [image:${file.path}]';

      final nonStream = await _captureRequestBody(content, stream: false);
      final streamed = await _captureRequestBody(content, stream: true);

      final nonStreamParts = _firstMessageParts(nonStream);
      final streamedParts = _firstMessageParts(streamed);

      expect(nonStreamParts, streamedParts);
      expect(nonStreamParts.first['text'], 'look');
      final imagePart = nonStreamParts.firstWhere(
        (part) => part['inline_data'] is Map,
      );
      expect(imagePart['inline_data']['mime_type'], 'image/png');
      expect(imagePart['inline_data']['data'], 'AQIDBA==');
    },
  );

  test(
    'Gemini non-stream and stream encode a data URL marker identically',
    () async {
      const content = 'look [image:data:image/png;base64,AQIDBA==]';

      final nonStream = await _captureRequestBody(content, stream: false);
      final streamed = await _captureRequestBody(content, stream: true);

      final nonStreamParts = _firstMessageParts(nonStream);
      final streamedParts = _firstMessageParts(streamed);

      expect(nonStreamParts, streamedParts);
      expect(nonStreamParts.first['text'], 'look');
      final imagePart = nonStreamParts.firstWhere(
        (part) => part['inline_data'] is Map,
      );
      expect(imagePart['inline_data']['mime_type'], 'image/png');
      expect(imagePart['inline_data']['data'], 'AQIDBA==');
    },
  );

  test(
    'Gemini non-stream and stream degrade a malformed data URL to text',
    () async {
      const content = 'look [image:data:image/png;notbase64]';

      final nonStream = await _captureRequestBody(content, stream: false);
      final streamed = await _captureRequestBody(content, stream: true);

      final nonStreamParts = _firstMessageParts(nonStream);
      final streamedParts = _firstMessageParts(streamed);

      expect(nonStreamParts, streamedParts);
      expect(nonStreamParts.any((part) => part['inline_data'] is Map), isFalse);
      expect(nonStreamParts.first['text'], 'look');
      expect(nonStreamParts.last['text'], 'data:image/png;notbase64');
    },
  );
}
