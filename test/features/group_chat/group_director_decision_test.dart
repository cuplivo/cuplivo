import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../support/business_test_harness.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/group_chat.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/group_chat/services/group_director.dart';

/// The director on a decision model: one choice question instead of a tool
/// call. What the request may contain — and what it must never contain — is
/// checked here, because a decision model cannot ask a follow-up question.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late SettingsProvider settings;
  final requests = <({String path, Map<String, dynamic> body})>[];

  // What the fake decision endpoint answers with.
  late int status;
  late Map<String, dynamic> answer;

  final members = [
    Assistant(id: 'a', name: 'A'),
    Assistant(id: 'b', name: 'B'),
    Assistant(id: 'c', name: 'C'),
  ];
  final group = GroupChat(
    id: 'g1',
    name: '阅读会',
    memberIds: const ['a', 'b', 'c'],
    maxSpeakerTurns: 3,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );
  final transcript = [
    ChatMessage(
      id: 'u1',
      role: 'user',
      content: '第三章谁在读？',
      timestamp: DateTime.utc(2026),
      conversationId: 'c1',
    ),
  ];

  Assistant? resolve(String? senderId) {
    for (final member in members) {
      if (member.id == senderId) return member;
    }
    return null;
  }

  setUp(() async {
    HttpOverrides.global = null;
    requests.clear();
    status = 200;
    answer = {
      'answers': {
        'next_speaker': {
          'type': 'choice',
          'choice': 'b',
          'confidence': 0.9,
          'probabilities': {'b': 0.9, 'end_round': 0.1},
        },
      },
    };
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      requests.add((
        path: request.uri.path,
        body: jsonDecode(raw) as Map<String, dynamic>,
      ));
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(answer));
      await request.response.close();
    });

    final prefs = createBusinessTestPreferences();
    await prefs.load();
    settings = SettingsProvider(prefs);
    await settings.loaded;
    await settings.setProviderConfig(
      'Fake',
      ProviderConfig(
        id: 'Fake',
        enabled: true,
        name: 'Fake',
        apiKey: 'decision-test-key',
        baseUrl: 'http://${server.address.address}:${server.port}/v1',
        providerType: ProviderKind.openai,
        // No tools: a decision model answers a typed question, so the director
        // must not ask it for a tool call.
        modelOverrides: const {
          'judge': {'type': 'decision'},
        },
      ),
    );
    await settings.setDirectorModel('Fake', 'judge');
  });

  tearDown(() async {
    try {
      await server.close(force: true);
    } catch (_) {}
  });

  Future<GroupDirectorDecision> decide({
    Set<String> spokeThisRound = const {},
    int remainingTurns = 3,
  }) {
    return GroupDirector(settings: settings).decide(
      group: group,
      members: members,
      transcript: transcript,
      spokeThisRound: spokeThisRound,
      resolve: resolve,
      remainingTurns: remainingTurns,
    );
  }

  Map<String, dynamic> questionOf(
    ({String path, Map<String, dynamic> body}) r,
  ) {
    final questions = r.body['questions'] as Map<String, dynamic>;
    return questions['next_speaker'] as Map<String, dynamic>;
  }

  test(
    'asks the decision endpoint once and returns the chosen member',
    () async {
      final decision = await decide();

      expect(decision, isA<GroupDirectorSpeak>());
      expect((decision as GroupDirectorSpeak).assistantId, 'b');
      expect(requests, hasLength(1));
      expect(requests.single.path, '/v1/systemone');
      expect(requests.single.body['model'], 'judge');
    },
  );

  test('offers only members who have not replied', () async {
    await decide(spokeThisRound: const {'a'});

    final criteria =
        questionOf(requests.single)['criteria'] as Map<String, dynamic>;
    expect(criteria.keys, containsAll(['b', 'c', GroupDirector.endTurnChoice]));
    expect(criteria.keys, isNot(contains('a')));
  });

  test(
    'roster and state carry no per-step flags, so the prefix is stable',
    () async {
      await decide(spokeThisRound: const {'a'});

      final state = requests.single.body['state'] as Map<String, dynamic>;
      expect(state.containsKey('replies_remaining'), isFalse);
      for (final member in state['members'] as List) {
        expect((member as Map).containsKey('already_replied'), isFalse);
      }
      final instructions =
          questionOf(requests.single)['instructions'] as String;
      expect(instructions.contains('more replies'), isFalse);
    },
  );

  test('everyone replied: the round ends without a request', () async {
    final decision = await decide(spokeThisRound: const {'a', 'b', 'c'});

    expect(decision, isA<GroupDirectorEndTurn>());
    expect(requests, isEmpty);
  });

  test('end_round is a decision, not a failure', () async {
    answer = {
      'answers': {
        'next_speaker': {
          'type': 'choice',
          'choice': GroupDirector.endTurnChoice,
          'confidence': 0.8,
          'probabilities': {GroupDirector.endTurnChoice: 0.8},
        },
      },
    };

    expect(await decide(), isA<GroupDirectorEndTurn>());
  });

  test(
    'a choice the question never offered is reported, not trusted',
    () async {
      answer = {
        'answers': {
          'next_speaker': {
            'type': 'choice',
            'choice': 'someone-else',
            'confidence': 0.4,
            'probabilities': {'someone-else': 0.4},
          },
        },
      };

      final decision = await decide();
      expect(decision, isA<GroupDirectorUnavailable>());
      expect((decision as GroupDirectorUnavailable).failure, 'unknown_speaker');
    },
  );

  test('an endpoint failure is unavailable, never a made-up speaker', () async {
    status = 500;
    answer = const {};

    final decision = await decide();
    expect(decision, isA<GroupDirectorUnavailable>());
    expect((decision as GroupDirectorUnavailable).failure, 'failed');
  });

  test(
    'an OpenAI decision model is asked at /decisions, in its own shape',
    () async {
      await settings.setProviderConfig(
        'Fake',
        settings
            .getProviderConfig('Fake')
            .copyWith(
              modelOverrides: const {
                'judge': {'type': 'decision', 'decisionDialect': 'openai'},
              },
            ),
      );
      answer = {
        'answers': [
          {
            'type': 'choice',
            'name': 'next_speaker',
            'choice': 'c',
            'confidence': 0.7,
            'probabilities': [
              {'value': 'c', 'probability': 0.7},
            ],
          },
        ],
      };

      final decision = await decide();
      expect((decision as GroupDirectorSpeak).assistantId, 'c');
      expect(requests.single.path, '/v1/decisions');
      final question =
          (requests.single.body['questions'] as List).single as Map;
      expect(question['name'], 'next_speaker');
      expect(requests.single.body['input'], isA<Map>());
    },
  );

  test(
    'a chat model without tools still reports no_tools (path unchanged)',
    () async {
      await settings.setProviderConfig(
        'Fake',
        settings
            .getProviderConfig('Fake')
            .copyWith(
              modelOverrides: const {
                'judge': {'type': 'chat'},
              },
            ),
      );

      final decision = await decide();
      expect(decision, isA<GroupDirectorUnavailable>());
      expect((decision as GroupDirectorUnavailable).failure, 'no_tools');
      expect(requests, isEmpty);
    },
  );
}
