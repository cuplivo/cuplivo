import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../support/business_test_harness.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/group_chat.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/group_chat/services/group_director.dart';

/// The director answers through exactly one tool call, so these tests drive that
/// call against a local server: the decision rules and the prompt they rest on
/// are checked without a model, and a change that quietly loosens either one
/// fails here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late SettingsProvider settings;
  final requests = <Map<String, dynamic>>[];

  // What the fake model answers with.
  late String toolName;
  late Map<String, dynamic> toolArgs;

  /// When true the fake model answers in prose instead of calling a tool, which
  /// is what the retry exists for.
  late bool plainText;

  final members = [
    Assistant(id: 'a', name: 'A'),
    Assistant(id: 'b', name: 'B'),
    Assistant(id: 'c', name: 'C'),
  ];
  final group = GroupChat(
    id: 'g1',
    name: 'Reading club',
    memberIds: const ['a', 'b', 'c'],
    maxSpeakerTurns: 3,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );
  final transcript = [
    ChatMessage(
      id: 'u1',
      role: 'user',
      content: 'who is reading chapter three?',
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
    // The test binding answers every HttpClient with a 400 of its own; the fake
    // model server below is only reachable with that override gone.
    HttpOverrides.global = null;
    requests.clear();
    toolName = GroupDirector.selectSpeakerTool;
    toolArgs = const {'assistant_id': 'b'};
    plainText = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      requests.add(body);
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      final message = plainText
          ? <String, dynamic>{
              'role': 'assistant',
              'content': 'B should answer next.',
            }
          : <String, dynamic>{
              'role': 'assistant',
              'content': null,
              'tool_calls': [
                {
                  'id': 'call-1',
                  'type': 'function',
                  'function': {
                    'name': toolName,
                    'arguments': jsonEncode(toolArgs),
                  },
                },
              ],
            };
      request.response.write(
        jsonEncode({
          'id': 'completion-1',
          'object': 'chat.completion',
          'choices': [
            {
              'index': 0,
              'message': message,
              'finish_reason': plainText ? 'stop' : 'tool_calls',
            },
          ],
          'usage': {
            'prompt_tokens': 10,
            'completion_tokens': 5,
            'total_tokens': 15,
          },
        }),
      );
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
        apiKey: 'director-test-key',
        baseUrl: 'http://${server.address.address}:${server.port}/v1',
        providerType: ProviderKind.openai,
        // The director never asks a model that cannot hold to a tool call; the
        // fake model has to declare the ability to be asked at all.
        modelOverrides: const {
          'director': {
            'abilities': ['tool'],
          },
        },
      ),
    );
    await settings.setDirectorModel('Fake', 'director');
  });

  tearDown(() async {
    try {
      await server.close(force: true);
    } catch (_) {}
  });

  GroupDirector director() => GroupDirector(settings: settings);

  Future<GroupDirectorDecision> decide({
    Set<String> spokeThisRound = const {},
    int remainingTurns = 3,
  }) {
    return director().decide(
      group: group,
      members: members,
      transcript: transcript,
      spokeThisRound: spokeThisRound,
      resolve: resolve,
      remainingTurns: remainingTurns,
    );
  }

  test('asks the model and returns the member it named', () async {
    final decision = await decide();

    expect(decision, isA<GroupDirectorSpeak>());
    expect((decision as GroupDirectorSpeak).assistantId, 'b');
    expect(requests, hasLength(1));

    final body = requests.single;
    final toolNames = [
      for (final tool in body['tools'] as List)
        (tool as Map)['function']['name'],
    ];
    expect(toolNames, contains(GroupDirector.selectSpeakerTool));
    expect(toolNames, contains(GroupDirector.endTurnTool));

    final system = (body['messages'] as List).first as Map;
    expect(system['role'], 'system');
    // The rule the round runner enforces: one reply per member per round, then
    // end the turn. A prompt that invites a repeat would be rewarding an answer
    // the runner throws away.
    expect(system['content'], contains('A member replies at most once'));
    expect(system['content'], contains('end_turn'));
    // Nobody has spoken yet, so no roster entry carries the mark.
    expect(system['content'], isNot(contains('"already_replied":true')));
  });

  test(
    'marks who already replied, and the round ceiling it can still spend',
    () async {
      await decide(spokeThisRound: {'a'}, remainingTurns: 2);

      final system = (requests.single['messages'] as List).first as Map;
      expect(system['content'], contains('"already_replied":true'));
      expect(system['content'], contains('At most 2 more replies remain'));
    },
  );

  test('an id nobody has is refused at once', () async {
    toolArgs = const {'assistant_id': 'ghost'};

    final decision = await decide();

    expect(decision, isA<GroupDirectorUnavailable>());
    expect((decision as GroupDirectorUnavailable).failure, 'unknown_speaker');
    // A named id the roster does not contain is a wrong answer, not a missing
    // one: only an empty answer is worth asking again.
    expect(requests, hasLength(1));
  });

  test(
    'a member who already spoke is refused even if the model picks them',
    () async {
      toolArgs = const {'assistant_id': 'a'};

      final decision = await decide(spokeThisRound: {'a'});

      expect(decision, isA<GroupDirectorUnavailable>());
      expect(
        (decision as GroupDirectorUnavailable).failure,
        'repeated_speaker',
      );
      // The model is given one more chance to answer with someone else.
      expect(requests, hasLength(GroupDirector.attempts));
    },
  );

  test('a text answer is retried with the rule and the ids restated', () async {
    plainText = true;

    final decision = await decide();

    expect(decision, isA<GroupDirectorUnavailable>());
    expect((decision as GroupDirectorUnavailable).failure, 'no_decision');
    expect(requests, hasLength(GroupDirector.attempts));

    final first = (requests[0]['messages'] as List).cast<Map>();
    final second = (requests[1]['messages'] as List).cast<Map>();
    // The second attempt is a different request: the same question plus the
    // one thing the first answer missed. At `temperature: 0` an unchanged
    // request would be a byte-identical repeat, not a second chance.
    expect(second.length, first.length + 1);
    final reminder = second.last;
    expect(reminder['role'], 'user');
    expect(reminder['content'], contains(GroupDirector.selectSpeakerTool));
    expect(reminder['content'], contains('a, b, c'));
    expect(
      first.map((message) => message['content']),
      isNot(contains(reminder['content'])),
    );
  });

  test('end_turn ends the round', () async {
    toolName = GroupDirector.endTurnTool;
    toolArgs = const {'reason': 'everyone had a turn'};

    final decision = await decide();

    expect(decision, isA<GroupDirectorEndTurn>());
    expect((decision as GroupDirectorEndTurn).reason, 'everyone had a turn');
  });

  test('a round with no turns left is not a question for the model', () async {
    final decision = await decide(remainingTurns: 0);

    expect(decision, isA<GroupDirectorUnavailable>());
    expect((decision as GroupDirectorUnavailable).failure, 'turn_limit');
    expect(requests, isEmpty);
  });

  test('a model that cannot call tools is never asked', () async {
    await settings.setProviderConfig(
      'NoTools',
      ProviderConfig(
        id: 'NoTools',
        enabled: true,
        name: 'NoTools',
        apiKey: 'director-test-key',
        baseUrl: 'http://${server.address.address}:${server.port}/v1',
        providerType: ProviderKind.openai,
      ),
    );
    await settings.setDirectorModel('NoTools', 'plain-model');

    final decision = await decide();

    expect(decision, isA<GroupDirectorUnavailable>());
    expect((decision as GroupDirectorUnavailable).failure, 'no_tools');
    expect(requests, isEmpty);
  });

  test('a stopped round is not asked again', () async {
    var stopped = false;

    final decision = await director().decide(
      group: group,
      members: members,
      transcript: transcript,
      spokeThisRound: const {},
      resolve: resolve,
      remainingTurns: 3,
      isCancelled: () => stopped,
    );
    expect(decision, isA<GroupDirectorSpeak>());

    // Once the user stops the round, a decision already in flight must not be
    // retried: the round is over, whatever the model is about to say.
    stopped = true;
    requests.clear();
    final afterStop = await director().decide(
      group: group,
      members: members,
      transcript: transcript,
      spokeThisRound: const {},
      resolve: resolve,
      remainingTurns: 3,
      isCancelled: () => stopped,
    );

    expect(afterStop, isA<GroupDirectorUnavailable>());
    expect((afterStop as GroupDirectorUnavailable).failure, 'cancelled');
    expect(requests, isEmpty);
  });

  test('no configured model and no global default is a normal state', () async {
    await settings.resetDirectorModel();
    await settings.resetCurrentModel();

    final decision = await decide();

    expect(decision, isA<GroupDirectorUnavailable>());
    expect((decision as GroupDirectorUnavailable).failure, 'no_model');
    expect(requests, isEmpty);
  });
}
