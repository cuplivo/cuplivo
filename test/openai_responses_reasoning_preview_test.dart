import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';

ProviderConfig _responsesConfig(String baseUrl) {
  return ProviderConfig(
    id: 'ResponsesTest',
    enabled: true,
    name: 'ResponsesTest',
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.openai,
    useResponseApi: true,
  );
}

String _baseUrl(HttpServer server) {
  return 'http://${server.address.address}:${server.port}/v1';
}

void main() {
  group('OpenAI Responses reasoning previews', () {
    test('reads OAuth summary parts from non-stream output', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'output_text': 'Answer',
            'output': [
              {
                'type': 'reasoning',
                'content': const <dynamic>[],
                'summary': const [
                  {'type': 'summary_text', 'text': 'Compare the tenths place.'},
                  {'type': 'summary_text', 'text': 'Choose the larger value.'},
                ],
              },
            ],
          }),
        );
        await request.response.close();
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _responsesConfig(_baseUrl(server)),
        modelId: 'gpt-5',
        messages: const [
          {'role': 'user', 'content': 'which is larger, 3.4 or 3.35?'},
        ],
        stream: false,
      ).toList();

      expect(chunks, hasLength(1));
      expect(chunks.single.content, 'Answer');
      expect(
        chunks.single.reasoning,
        'Compare the tenths place.Choose the larger value.',
      );
    });

    test(
      'streams summary deltas once without duplicating done or terminal text',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async {
          await server.close(force: true);
        });

        server.listen((request) async {
          await utf8.decoder.bind(request).join();
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          void send(Map<String, dynamic> event) {
            request.response.write('data: ${jsonEncode(event)}\n\n');
          }

          send({
            'type': 'response.output_item.added',
            'output_index': 0,
            'item': {
              'id': 'rs_1',
              'type': 'reasoning',
              'content': const <dynamic>[],
              'summary': const <dynamic>[],
              'encrypted_content': 'cipher',
            },
          });
          send({
            'type': 'response.reasoning_summary_text.delta',
            'item_id': 'rs_1',
            'output_index': 0,
            'summary_index': 0,
            'delta': 'First step. ',
          });
          send({
            'type': 'response.reasoning_summary_text.delta',
            'item_id': 'rs_1',
            'output_index': 0,
            'summary_index': 0,
            'delta': 'Second step.',
          });
          // Repeats everything streamed so far; must not be emitted twice.
          send({
            'type': 'response.reasoning_summary_text.done',
            'item_id': 'rs_1',
            'output_index': 0,
            'summary_index': 0,
            'text': 'First step. Second step.',
          });
          send({'type': 'response.output_text.delta', 'delta': 'Hello'});
          send({
            'type': 'response.completed',
            'response': {
              'output': [
                {
                  'id': 'rs_1',
                  'type': 'reasoning',
                  'content': const <dynamic>[],
                  'summary': const [
                    {'type': 'summary_text', 'text': 'First step.'},
                    {'type': 'summary_text', 'text': ' Second step.'},
                  ],
                },
                {
                  'type': 'message',
                  'content': const [
                    {'type': 'output_text', 'text': 'Hello'},
                  ],
                },
              ],
            },
          });
          await request.response.close();
        });

        final chunks = await ChatApiService.sendMessageStream(
          config: _responsesConfig(_baseUrl(server)),
          modelId: 'gpt-5',
          messages: const [
            {'role': 'user', 'content': 'hi'},
          ],
        ).toList();

        expect(chunks.map((c) => c.content).join(), 'Hello');
        // The terminal item repeats the streamed summary; the decoder must
        // emit only what was not streamed yet, so no text is duplicated.
        expect(chunks.map((c) => c.reasoning ?? '').join(), 'First step. Second step.');
      },
    );

    test('replays a reasoning item that never streamed deltas', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        void send(Map<String, dynamic> event) {
          request.response.write('data: ${jsonEncode(event)}\n\n');
        }

        send({
          'type': 'response.output_item.done',
          'output_index': 0,
          'item': {
            'id': 'rs_2',
            'type': 'reasoning',
            'content': const <dynamic>[],
            'summary': const [
              {'type': 'summary_text', 'text': 'Only in the final item.'},
            ],
          },
        });
        send({'type': 'response.output_text.delta', 'delta': 'Hi'});
        send({
          'type': 'response.completed',
          'response': {
            'output': const <dynamic>[],
          },
        });
        await request.response.close();
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _responsesConfig(_baseUrl(server)),
        modelId: 'gpt-5',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
      ).toList();

      expect(chunks.map((c) => c.content).join(), 'Hi');
      expect(
        chunks.map((c) => c.reasoning ?? '').join(),
        'Only in the final item.',
      );
    });

    test('keeps one copy when an item carries both content and summary', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        void send(Map<String, dynamic> event) {
          request.response.write('data: ${jsonEncode(event)}\n\n');
        }

        send({
          'type': 'response.reasoning_text.delta',
          'item_id': 'rs_mixed',
          'output_index': 0,
          'summary_index': 0,
          'delta': 'Visible reasoning',
        });
        send({'type': 'response.output_text.delta', 'delta': 'Answer'});
        send({
          'type': 'response.completed',
          'response': {
            'output': [
              {
                'id': 'rs_mixed',
                'type': 'reasoning',
                'content': const [
                  {'type': 'reasoning_text', 'text': 'Visible reasoning'},
                ],
                'summary': const [
                  {'type': 'summary_text', 'text': 'Summary text'},
                ],
              },
            ],
          },
        });
        await request.response.close();
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _responsesConfig(_baseUrl(server)),
        modelId: 'gpt-5',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
      ).toList();

      expect(chunks.map((c) => c.content).join(), 'Answer');
      // The terminal item prefers `content`; it must be deduped against the
      // `reasoning_text.delta` stream instead of being appended again.
      expect(
        chunks.map((c) => c.reasoning ?? '').join(),
        'Visible reasoning',
      );
    });

    test('dedupes a summary-only terminal item against reasoning deltas', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        void send(Map<String, dynamic> event) {
          request.response.write('data: ${jsonEncode(event)}\n\n');
        }

        send({
          'type': 'response.reasoning_text.delta',
          'item_id': 'rs_namespace',
          'output_index': 0,
          'summary_index': 0,
          'delta': 'Streamed as reasoning text',
        });
        send({'type': 'response.output_text.delta', 'delta': 'Answer'});
        send({
          'type': 'response.completed',
          'response': {
            'output': [
              {
                'id': 'rs_namespace',
                'type': 'reasoning',
                'content': const <dynamic>[],
                // Gateway exposes the same text under `summary` on the
                // terminal item even though the deltas were reasoning parts.
                'summary': const [
                  {'type': 'summary_text', 'text': 'Streamed as reasoning text'},
                ],
              },
            ],
          },
        });
        await request.response.close();
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _responsesConfig(_baseUrl(server)),
        modelId: 'gpt-5',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
      ).toList();

      expect(chunks.map((c) => c.content).join(), 'Answer');
      // The dedup namespace follows the delta stream, not the terminal field.
      expect(
        chunks.map((c) => c.reasoning ?? '').join(),
        'Streamed as reasoning text',
      );
    });

    test('dedupes multi-part summary deltas against the terminal item', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        void send(Map<String, dynamic> event) {
          request.response.write('data: ${jsonEncode(event)}\n\n');
        }

        send({
          'type': 'response.reasoning_summary_text.delta',
          'item_id': 'rs_parts',
          'output_index': 0,
          'summary_index': 0,
          'delta': 'First part. ',
        });
        send({
          'type': 'response.reasoning_summary_text.delta',
          'item_id': 'rs_parts',
          'output_index': 0,
          'summary_index': 1,
          'delta': 'Second part.',
        });
        send({'type': 'response.output_text.delta', 'delta': 'Answer'});
        send({
          'type': 'response.completed',
          'response': {
            'output': [
              {
                'id': 'rs_parts',
                'type': 'reasoning',
                'content': const <dynamic>[],
                'summary': const [
                  {'type': 'summary_text', 'text': 'First part. '},
                  {'type': 'summary_text', 'text': 'Second part.'},
                ],
              },
            ],
          },
        });
        await request.response.close();
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _responsesConfig(_baseUrl(server)),
        modelId: 'gpt-5',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
      ).toList();

      expect(chunks.map((c) => c.content).join(), 'Answer');
      expect(
        chunks.map((c) => c.reasoning ?? '').join(),
        'First part. Second part.',
      );
    });

    test('does not replay the previous round after a tool follow-up', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });
      var requestCount = 0;
      final requestBodies = <Map<String, dynamic>>[];

      server.listen((request) async {
        final rawBody = await utf8.decoder.bind(request).join();
        requestBodies.add(jsonDecode(rawBody) as Map<String, dynamic>);
        requestCount += 1;
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        void send(Map<String, dynamic> event) {
          request.response.write('data: ${jsonEncode(event)}\n\n');
        }

        if (requestCount == 1) {
          send({
            'type': 'response.output_item.done',
            'output_index': 0,
            'item': {
              'id': 'rs_round1',
              'type': 'reasoning',
              'content': const <dynamic>[],
              'summary': const [
                {'type': 'summary_text', 'text': 'ROUND_ONE_REASONING'},
              ],
            },
          });
          send({
            'type': 'response.output_item.added',
            'output_index': 1,
            'item': {
              'id': 'fc_1',
              'type': 'function_call',
              'call_id': 'call_1',
              'name': 'lookup',
              'arguments': '{}',
            },
          });
          send({
            'type': 'response.function_call_arguments.delta',
            'output_index': 1,
            'delta': '{}',
          });
          send({
            'type': 'response.completed',
            'response': {
              'output': [
                {
                  'id': 'rs_round1',
                  'type': 'reasoning',
                  'content': const <dynamic>[],
                  'summary': const [
                    {'type': 'summary_text', 'text': 'ROUND_ONE_REASONING'},
                  ],
                },
                {
                  'id': 'fc_1',
                  'type': 'function_call',
                  'call_id': 'call_1',
                  'name': 'lookup',
                  'arguments': '{}',
                },
              ],
            },
          });
        } else if (requestCount == 2) {
          send({
            'type': 'response.output_item.added',
            'output_index': 1,
            'item': {
              'id': 'fc_2',
              'type': 'function_call',
              'call_id': 'call_2',
              'name': 'lookup',
              'arguments': '{}',
            },
          });
          send({
            'type': 'response.function_call_arguments.delta',
            'output_index': 1,
            'delta': '{}',
          });
          // The terminal payload omits `output`, so the round has to fall back
          // to items captured from streaming events.
          send({
            'type': 'response.completed',
            'response': const <String, dynamic>{},
          });
        } else {
          send({'type': 'response.output_text.delta', 'delta': 'ROUND_THREE'});
          send({
            'type': 'response.completed',
            'response': const <String, dynamic>{},
          });
        }
        await request.response.close();
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _responsesConfig(_baseUrl(server)),
        modelId: 'gpt-5',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        onToolCall: (name, args, {toolCallId}) async => 'tool-result',
      ).toList();

      expect(requestCount, 3);
      expect(chunks.map((c) => c.content).join(), contains('ROUND_THREE'));
      expect(
        'ROUND_ONE_REASONING'.allMatches(
          chunks.map((c) => c.reasoning ?? '').join(),
        ).length,
        1,
      );
      // Multi-round guard: round 1's reasoning is replayed once through the
      // accumulated `input`, and the follow-up round must not forward it a
      // second time.
      expect(
        'ROUND_ONE_REASONING'.allMatches(jsonEncode(requestBodies[2])).length,
        1,
      );
    });

    test('keeps reasoning streamed by the tool follow-up round', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });
      var requestCount = 0;

      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        requestCount += 1;
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        void send(Map<String, dynamic> event) {
          request.response.write('data: ${jsonEncode(event)}\n\n');
        }

        if (requestCount == 1) {
          send({
            'type': 'response.output_item.added',
            'output_index': 0,
            'item': {
              'id': 'fc_1',
              'type': 'function_call',
              'call_id': 'call_1',
              'name': 'lookup',
              'arguments': '{}',
            },
          });
          send({
            'type': 'response.function_call_arguments.delta',
            'output_index': 0,
            'delta': '{}',
          });
          send({
            'type': 'response.completed',
            'response': {
              'output': [
                {
                  'id': 'fc_1',
                  'type': 'function_call',
                  'call_id': 'call_1',
                  'name': 'lookup',
                  'arguments': '{}',
                },
              ],
            },
          });
        } else {
          send({
            'type': 'response.reasoning_summary_text.delta',
            'item_id': 'rs_followup',
            'output_index': 0,
            'summary_index': 0,
            'delta': 'FOLLOW_UP_REASONING',
          });
          send({'type': 'response.output_text.delta', 'delta': 'FINAL'});
          send({
            'type': 'response.completed',
            'response': {
              'output': [
                {
                  'id': 'rs_followup',
                  'type': 'reasoning',
                  'content': const <dynamic>[],
                  'summary': const [
                    {'type': 'summary_text', 'text': 'FOLLOW_UP_REASONING'},
                  ],
                },
              ],
            },
          });
        }
        await request.response.close();
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _responsesConfig(_baseUrl(server)),
        modelId: 'gpt-5',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        onToolCall: (name, args, {toolCallId}) async => 'tool-result',
      ).toList();

      expect(requestCount, 2);
      expect(chunks.map((c) => c.content).join(), contains('FINAL'));
      // Reasoning from the follow-up round used to be dropped entirely.
      expect(
        chunks.map((c) => c.reasoning ?? '').join(),
        'FOLLOW_UP_REASONING',
      );
    });

    test('keeps id-less reasoning items in separate buckets', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        void send(Map<String, dynamic> event) {
          request.response.write('data: ${jsonEncode(event)}\n\n');
        }

        send({'type': 'response.output_text.delta', 'delta': 'Answer'});
        send({
          'type': 'response.completed',
          'response': {
            'output': [
              {
                'type': 'reasoning',
                'content': const <dynamic>[],
                'summary': const [
                  {'type': 'summary_text', 'text': 'Step one.'},
                ],
              },
              {
                'type': 'reasoning',
                'content': const <dynamic>[],
                'summary': const [
                  {'type': 'summary_text', 'text': 'Step one'},
                ],
              },
            ],
          },
        });
        await request.response.close();
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _responsesConfig(_baseUrl(server)),
        modelId: 'gpt-5',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
      ).toList();

      // Without an id the items would share one aggregate, and the second
      // text (a prefix of the first) would be dropped as already streamed.
      expect(
        chunks.map((c) => c.reasoning ?? '').join(),
        'Step one.Step one',
      );
    });

    test('dedupes a done-only stream whose item changes namespace', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        void send(Map<String, dynamic> event) {
          request.response.write('data: ${jsonEncode(event)}\n\n');
        }

        // Only a `done` payload streams the text, under the `reasoning`
        // namespace...
        send({
          'type': 'response.reasoning_text.done',
          'item_id': 'rs_done',
          'output_index': 0,
          'summary_index': 0,
          'text': 'Done only text',
        });
        send({'type': 'response.output_text.delta', 'delta': 'Answer'});
        // ...while the terminal item exposes it as a summary.
        send({
          'type': 'response.completed',
          'response': {
            'output': [
              {
                'id': 'rs_done',
                'type': 'reasoning',
                'content': const <dynamic>[],
                'summary': const [
                  {'type': 'summary_text', 'text': 'Done only text'},
                ],
              },
            ],
          },
        });
        await request.response.close();
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _responsesConfig(_baseUrl(server)),
        modelId: 'gpt-5',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
      ).toList();

      expect(chunks.map((c) => c.content).join(), 'Answer');
      expect(
        chunks.map((c) => c.reasoning ?? '').join(),
        'Done only text',
      );
    });

    test('replays follow-up reasoning items built from streamed events',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });
      var requestCount = 0;
      final requestBodies = <Map<String, dynamic>>[];

      server.listen((request) async {
        final rawBody = await utf8.decoder.bind(request).join();
        requestBodies.add(jsonDecode(rawBody) as Map<String, dynamic>);
        requestCount += 1;
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        void send(Map<String, dynamic> event) {
          request.response.write('data: ${jsonEncode(event)}\n\n');
        }

        if (requestCount == 1) {
          send({
            'type': 'response.output_item.added',
            'output_index': 0,
            'item': {
              'id': 'fc_1',
              'type': 'function_call',
              'call_id': 'call_1',
              'name': 'lookup',
              'arguments': '{}',
            },
          });
          send({
            'type': 'response.completed',
            'response': {
              'output': [
                {
                  'id': 'fc_1',
                  'type': 'function_call',
                  'call_id': 'call_1',
                  'name': 'lookup',
                  'arguments': '{}',
                },
              ],
            },
          });
        } else if (requestCount == 2) {
          send({
            'type': 'response.output_item.done',
            'output_index': 0,
            'item': {
              'id': 'rs_round2',
              'type': 'reasoning',
              'content': const <dynamic>[],
              'summary': const [
                {'type': 'summary_text', 'text': 'ROUND_TWO_REASONING'},
              ],
            },
          });
          send({
            'type': 'response.output_item.added',
            'output_index': 1,
            'item': {
              'id': 'fc_2',
              'type': 'function_call',
              'call_id': 'call_2',
              'name': 'lookup',
              'arguments': '{}',
            },
          });
          // Terminal payload omits `output`; the round has to fall back to
          // the items captured from streaming events.
          send({
            'type': 'response.completed',
            'response': const <String, dynamic>{},
          });
        } else {
          send({'type': 'response.output_text.delta', 'delta': 'FINAL'});
          send({
            'type': 'response.completed',
            'response': const <String, dynamic>{},
          });
        }
        await request.response.close();
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _responsesConfig(_baseUrl(server)),
        modelId: 'gpt-5',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        onToolCall: (name, args, {toolCallId}) async => 'tool-result',
      ).toList();

      expect(requestCount, 3);
      expect(chunks.map((c) => c.content).join(), contains('FINAL'));
      expect(
        'ROUND_TWO_REASONING'.allMatches(
          chunks.map((c) => c.reasoning ?? '').join(),
        ).length,
        1,
      );
      // The captured item is echoed back with the next round's input.
      expect(
        jsonEncode(requestBodies[2]).contains('ROUND_TWO_REASONING'),
        isTrue,
      );
    });
  });
}
