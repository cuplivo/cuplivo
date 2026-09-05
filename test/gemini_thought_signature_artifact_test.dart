import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';
import 'package:Cuplivo/core/services/api/providers/gemini_thought_signature.dart';
import 'package:Cuplivo/core/utils/multimodal_input_utils.dart';

ProviderConfig _geminiConfig(String baseUrl) {
  return ProviderConfig(
    id: 'GeminiTest',
    enabled: true,
    name: 'GeminiTest',
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.google,
  );
}

String _streamChunk(List<Map<String, dynamic>> parts, {String? finishReason}) {
  return 'data: ${jsonEncode({
    'candidates': [
      {
        'content': {'parts': parts},
        if (finishReason != null) 'finishReason': finishReason,
      },
    ],
    'usageMetadata': {'promptTokenCount': 1, 'candidatesTokenCount': 1, 'totalTokenCount': 2},
  })}\n\n';
}

const _legacyComment =
    '\n<!-- gemini_thought_signatures:{"text":{"k":"thoughtSignature","v":"sig-legacy"}} -->';

void main() {
  group('Gemini thought signature payload', () {
    test('encodes as bare JSON', () {
      final payload = encodeGeminiThoughtSignature(
        textKey: 'thoughtSignature',
        textValue: 'sig-text',
        imageSigs: const [
          {'k': 'thoughtSignature', 'v': 'sig-img'},
        ],
      );
      expect(jsonDecode(payload), {
        'text': {'k': 'thoughtSignature', 'v': 'sig-text'},
        'images': [
          {'k': 'thoughtSignature', 'v': 'sig-img'},
        ],
      });
      expect(encodeGeminiThoughtSignature(), '');
    });

    test('a legacy comment re-encodes as bare JSON', () {
      final legacy = extractGeminiThoughtMeta('Answer.$_legacyComment');
      final migrated = encodeGeminiThoughtSignature(
        textKey: legacy.textKey,
        textValue: legacy.textValue,
        imageSigs: legacy.images,
      );
      expect(legacy.cleanedText, 'Answer.');
      expect(migrated, startsWith('{'));
      expect(decodeGeminiThoughtSignature(migrated)?.textValue, 'sig-legacy');
    });

    test('collects the signature from a trailing empty part', () {
      final payload = collectGeminiThoughtSignatureFromParts([
        {
          'text': 'Thinking',
          'thought': true,
          'thoughtSignature': 'sig-thought',
        },
        {'text': 'Answer.'},
        {'text': '', 'thoughtSignature': 'sig-trailing'},
      ]);
      expect(jsonDecode(payload), {
        'text': {'k': 'thoughtSignature', 'v': 'sig-trailing'},
      });
    });

    test('decodes bare JSON and the legacy comment alike', () {
      final fresh = decodeGeminiThoughtSignature(
        '{"text":{"k":"thoughtSignature","v":"sig-new"}}',
      );
      expect(fresh?.textValue, 'sig-new');

      final legacy = decodeGeminiThoughtSignature(_legacyComment);
      expect(legacy?.textKey, 'thoughtSignature');
      expect(legacy?.textValue, 'sig-legacy');

      expect(decodeGeminiThoughtSignature(''), isNull);
      expect(decodeGeminiThoughtSignature('not a signature'), isNull);
      expect(decodeGeminiThoughtSignature('{}'), isNull);
    });
  });

  group('Gemini thought signature request transport', () {
    late HttpServer server;
    late List<Map<String, dynamic>> requestBodies;
    late List<Map<String, dynamic>> responseParts;
    late String? responseFinishReason;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      requestBodies = [];
      responseParts = [
        {'text': 'Answer.', 'thoughtSignature': 'sig-answer'},
      ];
      responseFinishReason = 'STOP';
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        requestBodies.add(jsonDecode(body) as Map<String, dynamic>);
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.write(
          _streamChunk(responseParts, finishReason: responseFinishReason),
        );
        request.response.write('data: [DONE]');
        await request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    Future<List<ChatStreamChunk>> send(List<Map<String, dynamic>> messages) {
      return ChatApiService.sendMessageStream(
        config: _geminiConfig(
          'http://${server.address.address}:${server.port}/v1beta',
        ),
        modelId: 'gemini-3.1-pro-preview',
        messages: messages,
      ).toList();
    }

    List<Map> modelParts(Map<String, dynamic> body) {
      final contents = (body['contents'] as List).cast<Map>();
      return (contents[1]['parts'] as List).cast<Map>();
    }

    test(
      'keeps the signature Gemini 3 hangs on a trailing empty part',
      () async {
        responseParts = [
          {
            'text': 'Thinking',
            'thought': true,
            'thoughtSignature': 'sig-thought',
          },
          {'text': 'Answer.'},
          {'text': '', 'thoughtSignature': 'sig-trailing'},
        ];

        final chunks = await send(const [
          {'role': 'user', 'content': 'Hello'},
        ]);

        final comment = chunks
            .map((c) => c.content)
            .firstWhere(
              (c) => c.contains('gemini_thought_signatures:'),
              orElse: () => '',
            );
        expect(comment, isNotEmpty);
        final meta = extractGeminiThoughtMeta(comment);
        expect(meta.textValue, 'sig-trailing');
      },
    );

    test('replays a stored signature from the internal key', () async {
      await send([
        {'role': 'user', 'content': 'Hello'},
        {
          'role': 'assistant',
          'content': 'Earlier answer.',
          multimodalInternalGeminiThoughtSignatureKey:
              encodeGeminiThoughtSignature(
                textKey: 'thoughtSignature',
                textValue: 'sig-stored',
              ),
        },
        {'role': 'user', 'content': 'Go on'},
      ]);

      final body = requestBodies.single;
      final model = modelParts(body).single;
      expect(model['text'], 'Earlier answer.');
      expect(model['thoughtSignature'], 'sig-stored');
      expect(
        jsonEncode(body),
        isNot(contains(multimodalInternalGeminiThoughtSignatureKey)),
      );
      expect(jsonEncode(body), isNot(contains('<!--')));
      expect(jsonEncode(body), isNot(contains('gemini_thought_signatures:')));
    });

    test('still reads a legacy comment left in the message text', () async {
      await send(const [
        {'role': 'user', 'content': 'Hello'},
        {'role': 'assistant', 'content': 'Earlier answer.$_legacyComment'},
        {'role': 'user', 'content': 'Go on'},
      ]);

      final model = modelParts(requestBodies.single).single;
      expect(model['text'], 'Earlier answer.');
      expect(model['thoughtSignature'], 'sig-legacy');
    });

    test('preserves signed parts order across a tool-call round', () async {
      await server.close(force: true);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        requestBodies.add(jsonDecode(body) as Map<String, dynamic>);
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        if (requestBodies.length == 1) {
          request.response.write(
            _streamChunk([
              {'text': '', 'thoughtSignature': 'sig-text'},
              {
                'functionCall': {
                  'name': 'fetch_markdown',
                  'args': {'url': 'https://example.com'},
                },
                'thoughtSignature': 'sig-fetch',
              },
            ]),
          );
        } else {
          request.response.write(
            _streamChunk([
              {'text': 'ok'},
            ], finishReason: 'STOP'),
          );
        }
        request.response.write('data: [DONE]');
        await request.response.close();
      });

      await send(const [
        {'role': 'user', 'content': 'Fetch it and summarize.'},
      ]);

      expect(requestBodies.length, 2);
      final parts = modelParts(requestBodies[1]);
      expect(parts.length, 2);
      expect(parts[0]['text'], '');
      expect(parts[0]['thoughtSignature'], 'sig-text');
      expect(parts[1]['functionCall']['name'], 'fetch_markdown');
      expect(parts[1]['thoughtSignature'], 'sig-fetch');
      final body = jsonEncode(requestBodies[1]);
      expect(body, isNot(contains('<!--')));
      expect(body, isNot(contains('gemini_thought_signatures:')));
      expect(
        body,
        isNot(contains(multimodalInternalGeminiThoughtSignatureKey)),
      );
    });
  });
}
