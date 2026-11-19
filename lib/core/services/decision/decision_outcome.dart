/// What a decision call produced: a typed answer, or why there is none.
///
/// The failure is reported, never absorbed: every call site owns its own
/// fallback (keep the current state, degrade, or hand the round back), and a
/// decision layer that guessed on its own would hide the difference between
/// "the model said no" and "the model never answered".
sealed class DecisionOutcome {
  const DecisionOutcome();
}

/// A typed answer. [choice] is set for a choice question and [yes] for a
/// yes/no question; the other stays null.
final class DecisionAnswer extends DecisionOutcome {
  const DecisionAnswer({
    this.choice,
    this.yes,
    this.confidence,
    this.probabilities = const <String, double>{},
  });

  /// The selected option id, exactly as the question named it.
  final String? choice;

  /// P(yes) in 0…1, for a yes/no question.
  final double? yes;

  /// The model's own confidence in [choice]; null for a yes/no answer.
  final double? confidence;

  /// Choice: probability per option id. Empty when the dialect omits it.
  final Map<String, double> probabilities;
}

enum DecisionFailure {
  /// The call did not finish inside the caller's timeout.
  timeout,

  /// The endpoint answered with an error status, or the transport failed.
  request,

  /// The endpoint answered, but not with this question's answer.
  malformed,
}

/// No usable answer. [status] carries the HTTP status when there was one, for
/// the log line — never for control flow.
final class DecisionUnavailable extends DecisionOutcome {
  const DecisionUnavailable(this.failure, {this.status});

  final DecisionFailure failure;
  final int? status;
}
