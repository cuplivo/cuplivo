import 'dart:convert';

import '../../providers/settings_provider.dart';
import 'decision_outcome.dart';
import 'decision_question.dart';

/// OpenAI's `/v1/decisions` wire format.
///
/// Same question, different field names: `input` instead of `state`, a
/// `questions` **array** whose items carry `name` and `type`, `choices:
/// [{value, description}]` instead of a criteria map, and an answer whose
/// probabilities are an array of objects rather than a map.
///
/// `input` is the text to evaluate, not a JSON document, so the state travels
/// as an encoded string. The answer is an **array** of answers in question
/// order for a `questions` request, and a bare object when a single question is
/// asked directly — both are accepted.
///
/// Contract from the Decisions guide snapshot (2026-10, gpt-6-luna) and the
/// `llm-openai-decisions` plugin's documented request/response shapes; the
/// guide labels its examples illustrative, so only field names and shapes are
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
      'input': jsonEncode(question.state),
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
    final answers = _answers(body);
    if (answers.isEmpty) {
      return const DecisionUnavailable(DecisionFailure.malformed);
    }
    Map? answer;
    for (final entry in answers) {
      if (entry is Map && entry['name'] == question.key) {
        answer = entry;
        break;
      }
    }
    // One question and one answer: the name is redundant, so a server that
    // omits it is still answering what was asked. A *different* name is an
    // answer to another question, and guessing there would name the wrong
    // speaker.
    if (answer == null &&
        answers.length == 1 &&
        answers.first is Map &&
        !(answers.first as Map).containsKey('name')) {
      answer = answers.first as Map;
    }
    if (answer == null) {
      return const DecisionUnavailable(DecisionFailure.malformed);
    }
    if (answer['type'] == 'refusal') {
      return const DecisionUnavailable(DecisionFailure.request);
    }
    return switch (question) {
      YesNoQuestion() => _decodeYesNo(answer),
      ChoiceQuestion() => _decodeChoice(answer),
    };
  }

  /// The answers this body carries: a bare array, an object wrapping one under
  /// `answers`, or a single answer object.
  static List<Object?> _answers(Object? body) {
    if (body is List) return body;
    if (body is Map) {
      final nested = body['answers'];
      if (nested is List) return nested;
      if (nested is Map) return [nested];
      return [body];
    }
    return const [];
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
