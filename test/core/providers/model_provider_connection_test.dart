import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/providers/model_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';

/// "Test connection" has to speak the protocol of the model it is testing: a
/// decision model verified with a chat completion reports a false failure and
/// never contacts the address the user is trying to confirm.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  final requests = <String>[];
  late int decisionStatus;
  late Map<String, dynamic> decisionAnswer;

  ProviderConfig provider({String? decisionUrl}) => ProviderConfig(
    id: 'P',
    enabled: true,
    name: 'P',
    apiKey: 'k',
    baseUrl: 'http://127.0.0.1:${server.port}/v1',
    providerType: ProviderKind.openai,
    modelOverrides: {
      'judge': {
        'type': 'decision',
        if (decisionUrl != null) 'decisionUrl': decisionUrl,
      },
      'chat': {'type': 'chat'},
    },
  );

  setUp(() async {
    HttpOverrides.global = null;
    requests.clear();
    decisionStatus = 200;
    decisionAnswer = {
      'answers': {
        'reachable': {'type': 'noul', 'noul': 0.9},
      },
    };
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await utf8.decoder.bind(request).join();
      requests.add('${request.method} ${request.uri.path}');
      request.response.statusCode = decisionStatus;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(decisionAnswer));
      await request.response.close();
    });
  });

  tearDown(() async {
    try {
      await server.close(force: true);
    } catch (_) {}
  });

  test(
    'a decision model is verified on its own endpoint, not with chat',
    () async {
      final reported = <String>[];
      await ProviderManager.testConnection(
        provider(),
        'judge',
        onRequestUrl: reported.add,
      );

      expect(requests, ['POST /v1/systemone']);
      expect(reported.single, endsWith('/v1/systemone'));
    },
  );

  test('a chat model still goes to chat completions', () async {
    decisionAnswer = {
      'choices': [
        {
          'message': {'content': 'hello'},
        },
      ],
    };
    await ProviderManager.testConnection(provider(), 'chat');

    expect(requests, ['POST /v1/chat/completions']);
  });

  test(
    'a decision endpoint that refuses is reported with its status',
    () async {
      decisionStatus = 404;
      decisionAnswer = {'error': 'no decisions here'};

      await expectLater(
        ProviderManager.testConnection(provider(), 'judge'),
        throwsA(
          predicate<Object>(
            (e) => e.toString().contains('HTTP 404'),
            'mentions the status',
          ),
        ),
      );
      expect(requests, ['POST /v1/systemone']);
    },
  );

  test('the tested address is the configured override', () async {
    final reported = <String>[];
    await ProviderManager.testConnection(
      provider(decisionUrl: '/api/alpha/decisions'),
      'judge',
      onRequestUrl: reported.add,
    );

    expect(reported.single, endsWith('/api/alpha/decisions'));
    expect(requests, ['POST /api/alpha/decisions']);
  });
}
