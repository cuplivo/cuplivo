import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';

Future<String> _generateTextAgainst(String responseContent) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() async {
    await server.close(force: true);
  });

  server.listen((request) async {
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'id': 'chatcmpl-minimax',
        'object': 'chat.completion',
        'created': 0,
        'model': 'MiniMax-M2.1',
        'choices': [
          {
            'index': 0,
            'message': {'role': 'assistant', 'content': responseContent},
            'finish_reason': 'stop',
          },
        ],
        'usage': {
          'prompt_tokens': 10,
          'completion_tokens': 10,
          'total_tokens': 20,
        },
      }),
    );
    await request.response.close();
  });

  final config = ProviderConfig(
    id: 'MiniMax',
    enabled: true,
    name: 'MiniMax',
    apiKey: 'sk-test',
    baseUrl: 'http://${server.address.address}:${server.port}/v1',
    providerType: ProviderKind.openai,
  );
  return ChatApiService.generateText(
    config: config,
    modelId: 'MiniMax-M2.1',
    prompt: 'test prompt',
  );
}

void main() {
  group('generateText strips thinking tokens for utility text', () {
    test(
      'strips balanced inline <think> blocks from non-streaming content',
      () async {
        final result = await _generateTextAgainst(
          '<think>用户想要一个标题</think>番茄炒蛋家常做法',
        );
        expect(result, '番茄炒蛋家常做法');
      },
    );

    test('drops truncated unclosed <think> block', () async {
      final result = await _generateTextAgainst('<think>用户想要一个标题');
      expect(result, '');
    });

    test('keeps plain content unchanged', () async {
      final result = await _generateTextAgainst('温泉之旅');
      expect(result, '温泉之旅');
    });
  });
}
