import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/decision/decision_client.dart';
import 'package:Cuplivo/core/services/decision/decision_dialect.dart';
import 'package:Cuplivo/core/services/decision/decision_outcome.dart';
import 'package:Cuplivo/core/services/decision/decision_question.dart';
import 'package:Cuplivo/core/services/decision/openai_decisions_dialect.dart';
import 'package:Cuplivo/core/services/decision/systemone_dialect.dart';

void main() {
  ProviderConfig config({Map<String, dynamic> overrides = const {}}) {
    return ProviderConfig(
      id: 'p',
      enabled: true,
      name: 'P',
      apiKey: 'k',
      baseUrl: 'https://example.test/v1',
      providerType: ProviderKind.openai,
      modelOverrides: overrides,
    );
  }

  const choice = ChoiceQuestion(
    key: 'next_speaker',
    instructions: 'Who speaks next?',
    state: {'group': 'g'},
    options: {'b': 'B', 'end_round': 'End the round'},
  );

  group('System One', () {
    test('encodes state, questions and choice criteria', () {
      final body = SystemOneDialect.encode(
        model: 'jev-latest',
        question: choice,
      );
      expect(body['model'], 'jev-latest');
      expect(body['state'], {'group': 'g'});
      final question =
          (body['questions'] as Map)['next_speaker'] as Map<String, dynamic>;
      expect(question['type'], 'choice');
      expect(question['instructions'], 'Who speaks next?');
      expect(question['criteria'], {'b': 'B', 'end_round': 'End the round'});
    });

    test('decodes the answer keyed by the question key', () {
      final outcome = SystemOneDialect.decode(
        body: {
          'answers': {
            'next_speaker': {
              'type': 'choice',
              'choice': 'b',
              'confidence': 0.9,
              'probabilities': {'b': 0.9, 'end_round': 0.1},
            },
          },
        },
        question: choice,
      );
      expect(outcome, isA<DecisionAnswer>());
      final answer = outcome as DecisionAnswer;
      expect(answer.choice, 'b');
      expect(answer.confidence, 0.9);
      expect(answer.probabilities['b'], 0.9);
    });

    test('a noul answer is P(yes) and carries no confidence', () {
      const yesNo = YesNoQuestion(
        key: 'remember',
        instructions: 'Worth remembering?',
        state: 'text',
      );
      final outcome = SystemOneDialect.decode(
        body: {
          'answers': {
            'remember': {'type': 'noul', 'noul': 0.82},
          },
        },
        question: yesNo,
      );
      final answer = outcome as DecisionAnswer;
      expect(answer.yes, 0.82);
      expect(answer.confidence, isNull);
    });

    test('a missing answer is malformed, not a default', () {
      final outcome = SystemOneDialect.decode(
        body: {'answers': <String, dynamic>{}},
        question: choice,
      );
      expect(
        (outcome as DecisionUnavailable).failure,
        DecisionFailure.malformed,
      );
    });
  });

  group('OpenAI decisions', () {
    test('encodes input, an array question and value/description choices', () {
      final body = OpenAiDecisionsDialect.encode(
        model: 'gpt-6-luna',
        question: choice,
      );
      expect(body['model'], 'gpt-6-luna');
      // `input` is the text being evaluated, not a JSON document, so the state
      // travels encoded.
      expect(body['input'], isA<String>());
      expect(jsonDecode(body['input'] as String), {'group': 'g'});
      final question =
          (body['questions'] as List).single as Map<String, dynamic>;
      expect(question['type'], 'choice');
      expect(question['name'], 'next_speaker');
      expect(question['choices'], [
        {'value': 'b', 'description': 'B'},
        {'value': 'end_round', 'description': 'End the round'},
      ]);
    });

    test('decodes the answer array by name, probabilities by value', () {
      final outcome = OpenAiDecisionsDialect.decode(
        body: {
          'answers': [
            {
              'type': 'choice',
              'name': 'next_speaker',
              'choice': 'b',
              'confidence': 0.75,
              'probabilities': [
                {'value': 'b', 'probability': 0.8},
                {'value': 'end_round', 'probability': 0.2},
              ],
            },
          ],
        },
        question: choice,
      );
      final answer = outcome as DecisionAnswer;
      expect(answer.choice, 'b');
      expect(answer.probabilities, {'b': 0.8, 'end_round': 0.2});
    });

    test('a predicate answer reads probability', () {
      const yesNo = YesNoQuestion(
        key: 'remember',
        instructions: 'Worth remembering?',
        state: 'text',
      );
      final outcome = OpenAiDecisionsDialect.decode(
        body: {
          'answers': [
            {'type': 'predicate', 'name': 'remember', 'probability': 0.31},
          ],
        },
        question: yesNo,
      );
      expect((outcome as DecisionAnswer).yes, 0.31);
    });

    test('an answer for another question is malformed', () {
      final outcome = OpenAiDecisionsDialect.decode(
        body: {
          'answers': [
            {'type': 'choice', 'name': 'other', 'choice': 'b'},
          ],
        },
        question: choice,
      );
      expect(
        (outcome as DecisionUnavailable).failure,
        DecisionFailure.malformed,
      );
    });

    test('the answer is the array itself, not an object wrapping it', () {
      final outcome = OpenAiDecisionsDialect.decode(
        body: [
          {
            'type': 'choice',
            'name': 'next_speaker',
            'choice': 'b',
            'probabilities': [
              {'value': 'b', 'probability': 1.0},
            ],
          },
        ],
        question: choice,
      );
      expect((outcome as DecisionAnswer).choice, 'b');
    });

    test('a single question may be answered by a bare object', () {
      final outcome = OpenAiDecisionsDialect.decode(
        body: {'type': 'choice', 'name': 'next_speaker', 'choice': 'b'},
        question: choice,
      );
      expect((outcome as DecisionAnswer).choice, 'b');
    });

    test('a single answer wrapped under answers is still that answer', () {
      final outcome = OpenAiDecisionsDialect.decode(
        body: {
          'answers': {'type': 'choice', 'name': 'next_speaker', 'choice': 'b'},
        },
        question: choice,
      );
      expect((outcome as DecisionAnswer).choice, 'b');
    });

    test('a refusal is a failed request, not a malformed answer', () {
      final outcome = OpenAiDecisionsDialect.decode(
        body: [
          {'type': 'refusal', 'name': 'next_speaker'},
        ],
        question: choice,
      );
      expect((outcome as DecisionUnavailable).failure, DecisionFailure.request);
    });
  });

  test(
    'the dialect comes from the model override, defaulting to System One',
    () {
      expect(
        DecisionDialectSetting.of(config(), 'judge'),
        DecisionDialect.systemOne,
      );
      expect(
        DecisionDialectSetting.of(
          config(
            overrides: {
              'judge': {'type': 'decision', 'decisionDialect': 'openai'},
            },
          ),
          'judge',
        ),
        DecisionDialect.openAi,
      );
    },
  );

  group('endpoint', () {
    test('follows the dialect under the provider base URL', () {
      expect(
        DecisionClient.endpointFor(
          config(),
          'judge',
          DecisionDialect.systemOne,
        ).toString(),
        'https://example.test/v1/systemone',
      );
      expect(
        DecisionClient.endpointFor(
          config(),
          'judge',
          DecisionDialect.openAi,
        ).toString(),
        'https://example.test/v1/decisions',
      );
    });

    test('a URL override wins — gateways serve decisions off /v1', () {
      final cfg = config(
        overrides: {
          'judge': {
            'type': 'decision',
            'decisionUrl': 'https://openrouter.ai/api/alpha/decisions',
          },
        },
      );
      expect(
        DecisionClient.endpointFor(
          cfg,
          'judge',
          DecisionDialect.systemOne,
        ).toString(),
        'https://openrouter.ai/api/alpha/decisions',
      );
    });

    test('a blank override falls back to the dialect path', () {
      final cfg = config(
        overrides: {
          'judge': {'type': 'decision', 'decisionUrl': '   '},
        },
      );
      expect(
        DecisionClient.endpointFor(
          cfg,
          'judge',
          DecisionDialect.systemOne,
        ).toString(),
        'https://example.test/v1/systemone',
      );
    });

    test('an address the parser rejects degrades instead of throwing', () async {
      final cfg = config(
        overrides: {
          'judge': {'type': 'decision', 'decisionUrl': 'https://[::1/api/x'},
        },
      );
      // Nothing validates the stored address, and it is re-parsed per request:
      // the round has to lose its director, not its fallback.
      final outcome = await DecisionClient.ask(
        config: cfg,
        modelId: 'judge',
        question: choice,
      );
      expect((outcome as DecisionUnavailable).failure, DecisionFailure.request);
    });

    test('a whole URL, host+path, or a bare path all resolve', () {
      const base = 'https://openrouter.ai/api/v1';
      expect(
        DecisionClient.resolveDecisionUrl(
          'https://openrouter.ai/api/alpha/decisions',
          providerBaseUrl: base,
        ).toString(),
        'https://openrouter.ai/api/alpha/decisions',
      );
      expect(
        DecisionClient.resolveDecisionUrl(
          'openrouter.ai/api/alpha/decisions',
          providerBaseUrl: base,
        ).toString(),
        'https://openrouter.ai/api/alpha/decisions',
      );
      // A bare path hangs off the origin, not off the provider's `/api/v1`.
      expect(
        DecisionClient.resolveDecisionUrl(
          '/api/alpha/decisions',
          providerBaseUrl: base,
        ).toString(),
        'https://openrouter.ai/api/alpha/decisions',
      );
      // A self-hosted gateway keeps its own scheme and port.
      expect(
        DecisionClient.resolveDecisionUrl(
          '/compatible-mode/v1/systemone',
          providerBaseUrl: 'http://127.0.0.1:8099/v1',
        ).toString(),
        'http://127.0.0.1:8099/compatible-mode/v1/systemone',
      );
      // A path typed without its leading slash is a path, not a host named
      // `api`.
      expect(
        DecisionClient.resolveDecisionUrl(
          'api/alpha/decisions',
          providerBaseUrl: base,
        ).toString(),
        'https://openrouter.ai/api/alpha/decisions',
      );
      // …while a real host still is one, dotted or dotted-free.
      expect(
        DecisionClient.resolveDecisionUrl(
          'localhost/api/x',
          providerBaseUrl: base,
        ).toString(),
        'https://localhost/api/x',
      );
      expect(
        DecisionClient.resolveDecisionUrl(
          'kev.local/api/x',
          providerBaseUrl: base,
        ).toString(),
        'https://kev.local/api/x',
      );
    });
  });
}
