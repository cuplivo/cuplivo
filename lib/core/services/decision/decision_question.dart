/// A question for a decision model: context plus a typed judgement, never a
/// prompt that expects prose back.
///
/// The wire shape belongs to a dialect (see `systemone_dialect.dart`); callers
/// only ever name a question and read the typed answer. [state] is the context
/// verbatim — a decision model is asked about what was said, so the text is
/// never translated to match the English instructions.
sealed class DecisionQuestion {
  const DecisionQuestion({
    required this.key,
    required this.instructions,
    required this.state,
  });

  /// Answer key: mirrors this question's key in the response.
  final String key;

  /// One English sentence naming the judgement wanted.
  final String instructions;

  /// The context, as the model receives it: a string, a map or a list.
  final Object state;
}

/// A yes/no judgement. Answered as P(yes); a decision model has no confidence
/// for this type, so a caller who needs one has to ask a choice instead.
final class YesNoQuestion extends DecisionQuestion {
  const YesNoQuestion({
    required super.key,
    required super.instructions,
    required super.state,
    this.trueCriteria,
    this.falseCriteria,
  });

  /// What "yes" means, when the sentence alone leaves it ambiguous.
  final String? trueCriteria;

  /// What "no" means, on the same terms.
  final String? falseCriteria;
}

/// One answer out of a named set. Each option is a stable id plus the sentence
/// the model reads; the id never appears in the instructions.
final class ChoiceQuestion extends DecisionQuestion {
  const ChoiceQuestion({
    required super.key,
    required super.instructions,
    required super.state,
    required this.options,
  });

  /// Option id → what the option means. At most 255 entries.
  final Map<String, String> options;
}
