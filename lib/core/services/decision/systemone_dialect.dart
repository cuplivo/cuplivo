import '../../providers/settings_provider.dart';
import 'decision_outcome.dart';
import 'decision_question.dart';

/// The System One wire format, in one place.
///
/// `POST {baseUrl}/systemone` takes `{model, state, questions}` and answers
/// `{answers: {key: …}}`. The same shape is spoken by TypeSafe (Jev), Alibaba
/// Bailian's `decision-model-preview`, Turing's gateway and the open Kev/APUS
/// builds, so this file — not the call sites — is where every field name lives.
///
/// Response contract checked against
/// https://typesafe-jev.com/en/guides/api/ and
/// https://www.alibabacloud.com/help/en/model-studio/decision-model-api
/// (both 2026-11-10): choice answers carry `choice`, `confidence`,
/// `probabilities`; noul answers carry `noul` (P(yes)) and no confidence.
abstract final class SystemOneDialect {
  static Uri endpoint(ProviderConfig config) {
    final base = config.baseUrl.endsWith('/')
        ? config.baseUrl.substring(0, config.baseUrl.length - 1)
        : config.baseUrl;
    return Uri.parse('$base/systemone');
  }

  static Map<String, dynamic> encode({
    required String model,
    required DecisionQuestion question,
  }) {
    return <String, dynamic>{
      'model': model,
      'state': question.state,
      'questions': <String, dynamic>{question.key: _encodeQuestion(question)},
    };
  }

  static Map<String, dynamic> _encodeQuestion(DecisionQuestion question) {
    return switch (question) {
      YesNoQuestion(:final trueCriteria, :final falseCriteria) => {
        'type': 'noul',
        'instructions': question.instructions,
        if (trueCriteria != null || falseCriteria != null)
          'criteria': {
            if (trueCriteria != null) 'true': trueCriteria,
            if (falseCriteria != null) 'false': falseCriteria,
          },
      },
      ChoiceQuestion(:final options) => {
        'type': 'choice',
        'instructions': question.instructions,
        'criteria': options,
      },
    };
  }

  /// Read the answer for [question] out of a decoded response body.
  ///
  /// An option id the question never offered is passed through: the call site
  /// knows whether that is an unknown speaker, a stale candidate or something
  /// worse, and its own fallback names the reason.
  static DecisionOutcome decode({
    required Object? body,
    required DecisionQuestion question,
  }) {
    if (body is! Map) {
      return const DecisionUnavailable(DecisionFailure.malformed);
    }
    final answers = body['answers'];
    if (answers is! Map) {
      return const DecisionUnavailable(DecisionFailure.malformed);
    }
    final answer = answers[question.key];
    if (answer is! Map) {
      return const DecisionUnavailable(DecisionFailure.malformed);
    }
    return switch (question) {
      YesNoQuestion() => _decodeYesNo(answer),
      ChoiceQuestion() => _decodeChoice(answer),
    };
  }

  static DecisionOutcome _decodeYesNo(Map answer) {
    final raw = answer['noul'];
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
    if (raw is! Map) return const <String, double>{};
    return {
      for (final entry in raw.entries)
        if (entry.value is num)
          entry.key.toString(): (entry.value as num).toDouble(),
    };
  }
}
