import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';
import 'package:Cuplivo/core/services/api/providers/zhipu_layout_parsing.dart';
import 'package:Cuplivo/core/services/api/stream/stream_chunk.dart';

ProviderConfig _config(
  String baseUrl, {
  String id = 'Zhipu AI',
  Map<String, dynamic> modelOverrides = const <String, dynamic>{},
  List<Map<String, String>> customBody = const <Map<String, String>>[],
}) {
  return ProviderConfig(
    id: id,
    enabled: true,
    name: id,
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.openai,
    modelOverrides: modelOverrides,
    customBody: customBody,
  );
}

ProviderConfig _officialConfig({
  Map<String, dynamic> modelOverrides = const <String, dynamic>{},
  List<Map<String, String>> customBody = const <Map<String, String>>[],
}) {
  return _config(
    'https://open.bigmodel.cn/api/paas/v4',
    modelOverrides: modelOverrides,
    customBody: customBody,
  );
}

String _localBaseUrl(HttpServer server) {
  return 'http://${server.address.address}:${server.port}/api/paas/v4';
}

Future<({Uri uri, Map<String, dynamic> body, List<StreamChunk> chunks})>
_captureLayoutParsing({
  required ProviderConfig config,
  required String modelId,
  required List<Map<String, dynamic>> messages,
  List<String>? userImagePaths,
  Map<String, dynamic> responseBody = const {
    'id': 'task_1',
    'created': 1727156815,
    'model': 'GLM-OCR',
    'md_results': '# Title\nExtracted text',
    'usage': {'prompt_tokens': 3, 'completion_tokens': 5, 'total_tokens': 8},
  },
}) async {
  late Uri requestUri;
  late Map<String, dynamic> requestBody;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() async {
    await server.close(force: true);
  });

  server.listen((request) async {
    requestUri = request.uri;
    requestBody = (jsonDecode(await utf8.decoder.bind(request).join()) as Map)
        .cast<String, dynamic>();
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(responseBody));
    await request.response.close();
  });

  final client = http.Client();
  addTearDown(client.close);
  final chunks = await sendZhipuLayoutParsingStream(
    client,
    config.copyWith(baseUrl: _localBaseUrl(server)),
    modelId,
    messages,
    userImagePaths: userImagePaths,
  ).toList();

  return (uri: requestUri, body: requestBody, chunks: chunks);
}

void main() {
  group('GLM-OCR layout parsing', () {
    test('only routes official Zhipu host + glm-ocr', () {
      expect(shouldUseZhipuLayoutParsing(_officialConfig(), 'glm-ocr'), isTrue);
      expect(shouldUseZhipuLayoutParsing(_officialConfig(), 'GLM-OCR'), isTrue);
      expect(
        shouldUseZhipuLayoutParsing(
          _officialConfig(
            modelOverrides: const {
              'My OCR': {'apiModelId': 'glm-ocr'},
            },
          ),
          'My OCR',
        ),
        isTrue,
      );
      expect(
        shouldUseZhipuLayoutParsing(_officialConfig(), 'zhipu/glm-ocr'),
        isFalse,
      );
      expect(
        shouldUseZhipuLayoutParsing(_officialConfig(), 'glm-ocr-v1'),
        isFalse,
      );
      expect(
        shouldUseZhipuLayoutParsing(
          _config('https://openrouter.ai/api/v1', id: 'OpenRouter'),
          'glm-ocr',
        ),
        isFalse,
      );
      expect(
        shouldUseZhipuLayoutParsing(
          _config('http://127.0.0.1:8000/v1', id: 'vLLM'),
          'glm-ocr',
        ),
        isFalse,
      );
    });

    test('posts only {model: glm-ocr, file} and reads md_results', () async {
      final captured = await _captureLayoutParsing(
        config: _officialConfig(
          customBody: const [
            {'key': 'stream_options', 'value': '{"include_usage":true}'},
            {'key': 'thinking', 'value': '{"type":"enabled"}'},
          ],
        ),
        modelId: 'glm-ocr',
        messages: const [
          {'role': 'system', 'content': 'should not be sent'},
          {'role': 'user', 'content': 'Please perform OCR'},
        ],
        userImagePaths: const [
          'https://cdn.bigmodel.cn/static/logo/introduction.png',
        ],
      );

      expect(captured.uri.path, '/api/paas/v4/layout_parsing');
      expect(captured.body, {
        'model': officialGlmOcrModelId,
        'file': 'https://cdn.bigmodel.cn/static/logo/introduction.png',
      });
      expect(captured.body.containsKey('messages'), isFalse);
      expect(captured.body.containsKey('stream_options'), isFalse);
      expect(captured.body.containsKey('thinking'), isFalse);
      expect(
        captured.chunks.whereType<TextDelta>().map((c) => c.text).join(),
        '# Title\nExtracted text',
      );
    });

    test('always sends official model id glm-ocr', () async {
      final captured = await _captureLayoutParsing(
        config: _officialConfig(
          modelOverrides: const {
            'zhipu/glm-ocr': {'apiModelId': 'zhipu/glm-ocr'},
          },
        ),
        modelId: 'zhipu/glm-ocr',
        messages: const [
          {'role': 'user', 'content': ''},
        ],
        userImagePaths: const [
          'https://cdn.bigmodel.cn/static/logo/introduction.png',
        ],
      );

      expect(captured.body['model'], officialGlmOcrModelId);
    });

    test('encodes local files as data URIs', () async {
      final dir = await Directory.systemTemp.createTemp('kelivo_glm_ocr_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/sample.png');
      await file.writeAsBytes(const [1, 2, 3, 4]);

      final captured = await _captureLayoutParsing(
        config: _officialConfig(),
        modelId: 'glm-ocr',
        messages: const [
          {'role': 'user', 'content': ''},
        ],
        userImagePaths: [file.path],
      );

      expect(captured.body['model'], officialGlmOcrModelId);
      expect(
        captured.body['file'],
        'data:image/png;base64,${base64Encode(const [1, 2, 3, 4])}',
      );
    });

    test('does not reroute non-official hosts to layout_parsing', () async {
      late Uri requestUri;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requestUri = request.uri;
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'ok'},
              },
            ],
          }),
        );
        await request.response.close();
      });

      await ChatApiService.generateMessage(
        config: _config(_localBaseUrl(server), id: 'OpenRouter'),
        modelId: 'glm-ocr',
        messages: const [
          {'role': 'user', 'content': 'ocr'},
        ],
        userImagePaths: const [
          'https://cdn.bigmodel.cn/static/logo/introduction.png',
        ],
        ocrActive: true,
      );

      expect(requestUri.path, isNot(contains('layout_parsing')));
      expect(requestUri.path, contains('chat/completions'));
    });
  });
}
