import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/api_keys.dart';
import 'package:Cuplivo/core/models/model_spec.dart';
import 'package:Cuplivo/core/models/reasoning_request.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_helpers.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';

void main() {
  test('explicit keys and multi-key selection take precedence', () {
    final config = ProviderConfig.defaultsFor(
      'TestProvider',
    ).copyWith(apiKey: 'user-key');
    expect(effectiveApiKey(config), 'user-key');
    final multiKey = config.copyWith(
      multiKeyEnabled: true,
      apiKeys: [
        ApiKeyConfig(id: 'first', key: 'first-key', createdAt: 1, updatedAt: 1),
        ApiKeyConfig(id: 'next', key: 'next-key', createdAt: 1, updatedAt: 1),
      ],
    );
    expect(effectiveApiKey(multiKey), 'first-key');
    expect(effectiveApiKey(multiKey), 'next-key');
  });

  test('SiliconFlow has no built-in models or fallback credentials', () {
    final config = ProviderConfig.defaultsFor('SiliconFlow');
    expect(config.baseUrl, 'https://api.siliconflow.cn/v1');
    expect(config.models, isEmpty);
    expect(config.modelOverrides, isEmpty);
    for (final id in ['THUDM/GLM-4-9B-0414', 'Qwen/Qwen3-8B']) {
      expect(apiKeyForRequest(config, id), isEmpty);
      expect(
        apiKeyForRequest(config.copyWith(apiKey: 'user-key'), id),
        'user-key',
      );
    }
  });

  test(
    'auto sends tools and OpenAI reasoning controls on chat requests',
    () async {
      final requests = <Map<String, dynamic>>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        expect(request.uri.path, '/v1/chat/completions');
        expect(request.headers.value('authorization'), 'Bearer user-key');
        requests.add(
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>,
        );
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {'content': 'OK'},
                'finish_reason': 'stop',
              },
            ],
          })}\n\ndata: [DONE]\n\n',
        );
        await request.response.close();
      });
      final config = ProviderConfig.defaultsFor('TestProvider').copyWith(
        apiKey: 'user-key',
        baseUrl: 'http://${server.address.address}:${server.port}/v1',
        models: const ['auto'],
        // The reasoning controls this test asserts come from the model's
        // declared spec, so it states that spec itself instead of relying on a
        // built-in provider's model prefill, which Cuplivo does not ship.
        modelOverrides: const {
          'auto': {
            'type': 'chat',
            'input': ['text'],
            'output': ['text'],
            'abilities': ['tool', 'reasoning'],
            'reasoning': {'dialect': 'openaiReasoningEffort'},
          },
        },
      );
      const tools = [
        {
          'type': 'function',
          'function': {
            'name': 'echo',
            'description': 'Echo the input',
            'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
          },
        },
      ];
      for (final level in [ReasoningLevel.high, ReasoningLevel.off]) {
        await ChatApiService.sendMessageStream(
          config: config,
          modelId: 'auto',
          messages: const [
            {'role': 'user', 'content': 'Hello'},
          ],
          tools: tools,
          reasoning: ReasoningRequest(level),
        ).toList();
      }
      expect(requests, hasLength(2));
      expect(requests[0]['reasoning_effort'], 'high');
      expect(requests[1]['reasoning_effort'], 'none');
      for (final request in requests) {
        expect(request['model'], 'auto');
        expect(request['tools'], tools);
        expect(request['stream'], isTrue);
      }
    },
  );
}
