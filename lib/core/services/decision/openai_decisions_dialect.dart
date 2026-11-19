import '../../providers/settings_provider.dart';
import 'decision_outcome.dart';
import 'decision_question.dart';

/// OpenAI's `/v1/decisions` wire format.
///
/// Same question, different field names: `input` instead of `state`, a
/// `questions` **array** whose items carry `name`, `predicate` instead of
/// `noul`, `choices: [{value, description}]` instead of a criteria map, and an
/// `answers` **array** matched by `name` whose probabilities are an array of
/// objects rather than a map.
///
/// Contract from the Decisions guide snapshot (2026-10, gpt-6-luna); the guide
/// itself labels its examples illustrative, so only field names and shapes are
/// relied on here, never a promised value.
abstract final class OpenAiDecisionsDialect {
  static Uri endpoint(ProviderConfig config) {
    final base = config.baseUrl.endsWith('/')
        ? config.baseUrl.substring(0, config.baseUrl.length - 1)
        : config.baseUrl;
    return Uri.parse('$base/decisions');
  }

  static Map<String, dynamic> encode({
    required String model,
    required DecisionQuestion question,
  }) {
    return <String, dynamic>{
      'model': model,
      'input': question.state,
      'questions': [_encodeQuestion(question)],
    };
  }

  static Map<String, dynamic> _encodeQuestion(DecisionQuestion question) {
    return switch (question) {
      YesNoQuestion() => {
        'type': 'predicate',
        'name': question.key,
        'instructions': question.instructions,
      },
      ChoiceQuestion(:final options) => {
        'type': 'choice',
        'name': question.key,
        'instructions': question.instructions,
        'choices': [
          for (final entry in options.entries)
            {'value': entry.key, 'description': entry.value},
        ],
      },
    };
  }

  static DecisionOutcome decode({
    required Object? body,
    required DecisionQuestion question,
  }) {
    if (body is! Map) {
      return const DecisionUnavailable(DecisionFailure.malformed);
    }
    final answers = body['answers'];
    if (answers is! List) {
      return const DecisionUnavailable(DecisionFailure.malformed);
    }
    Map? answer;
    for (final entry in answers) {
      if (entry is Map && entry['name'] == question.key) {
        answer = entry;
        break;
      }
    }
    if (answer == null) {
      return const DecisionUnavailable(DecisionFailure.malformed);
    }
    return switch (question) {
      YesNoQuestion() => _decodeYesNo(answer),
      ChoiceQuestion() => _decodeChoice(answer),
    };
  }

  static DecisionOutcome _decodeYesNo(Map answer) {
    final raw = answer['probability'];
    if (raw is! num) {
      return const DecisionUnavailable(DecisionFailure.malformed);
    }
    final yes = raw.toDouble();
    if (yes.isNaN || yes < 0 || yes > 1) {
      return const DecisionUnavailable(DecisionFailure.malformed);
    }
    return DecisionAnswer(yes: yes);
  }

  static DecisionOutcome _decodeChoice(Map answer) {
    final raw = answer['choice'];
    if (raw is! String || raw.trim().isEmpty) {
      return const DecisionUnavailable(DecisionFailure.malformed);
    }
    final confidence = answer['confidence'];
    return DecisionAnswer(
      choice: raw.trim(),
      confidence: confidence is num ? confidence.toDouble() : null,
      probabilities: _probabilities(answer['probabilities']),
    );
  }

  static Map<String, double> _probabilities(Object? raw) {
    if (raw is! List) return const <String, double>{};
    final out = <String, double>{};
    for (final entry in raw) {
      if (entry is! Map) continue;
      final value = entry['value']?.toString();
      final probability = entry['probability'];
      if (value == null || probability is! num) continue;
      out[value] = probability.toDouble();
    }
    return out;
  }
}
