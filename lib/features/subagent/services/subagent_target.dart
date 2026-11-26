/// Who runs a delegated task.
///
/// One vocabulary, one parser. The tool argument and the child conversation's
/// extras carry the same string, so nothing has to reassemble a target from two
/// keys and no caller writes its own `startsWith('assistant:')`.
///
/// `general` is this conversation's own assistant, and it is also what a
/// conversation with no target configured gets: a delegation then costs the
/// model nothing to address. `assistant:<id>` names one of the user's other
/// assistants; the id is unique and never changes, which a name is not.
///
/// It is the same shape the group director uses: ids travel on the wire, names
/// are what the model reads.
library;

/// The literal strings the vocabulary is made of.
abstract final class SubagentTargetKeys {
  /// The delegating conversation's own assistant.
  static const String general = 'general';

  /// Prefix of an assistant target, followed by the assistant id.
  static const String assistantPrefix = 'assistant:';

  /// The child conversation's extras key holding [SubagentTarget.encode].
  ///
  /// It is the key the first slice already wrote (`subagent.target`), so a
  /// conversation created before this slice reads back as `general`.
  static const String extras = 'subagent.target';
}

/// One delegation's target.
sealed class SubagentTarget {
  const SubagentTarget();

  /// The assistant that runs the task, when it is not the one delegating.
  String? get assistantId => null;

  /// The wire and storage form, which is also what the model is given.
  String encode();

  /// Whether this target names [id].
  bool names(String id) => assistantId == id;

  static SubagentTarget general() => const GeneralSubagentTarget();

  static SubagentTarget assistant(String id) =>
      AssistantSubagentTarget(id.trim());
}

/// The context's own assistant.
final class GeneralSubagentTarget extends SubagentTarget {
  const GeneralSubagentTarget();

  @override
  String encode() => SubagentTargetKeys.general;

  @override
  bool operator ==(Object other) => other is GeneralSubagentTarget;

  @override
  int get hashCode => SubagentTargetKeys.general.hashCode;

  @override
  String toString() => SubagentTargetKeys.general;
}

/// One of the user's other assistants, by id.
final class AssistantSubagentTarget extends SubagentTarget {
  const AssistantSubagentTarget(this.assistantId);

  @override
  final String assistantId;

  @override
  String encode() => '${SubagentTargetKeys.assistantPrefix}$assistantId';

  @override
  bool operator ==(Object other) =>
      other is AssistantSubagentTarget && other.assistantId == assistantId;

  @override
  int get hashCode => encode().hashCode;

  @override
  String toString() => encode();
}

/// Parses [raw]; anything that is neither `general` nor `assistant:<id>` with a
/// non-empty id answers null.
///
/// Null is the refusal, never a fallback: a caller that receives it answers
/// `unknown_target` instead of quietly delegating to somebody the user did not
/// pick.
SubagentTarget? parseSubagentTarget(Object? raw) {
  final value = raw?.toString().trim() ?? '';
  if (value.isEmpty) return null;
  if (value == SubagentTargetKeys.general) return SubagentTarget.general();
  if (!value.startsWith(SubagentTargetKeys.assistantPrefix)) return null;
  final id = value.substring(SubagentTargetKeys.assistantPrefix.length).trim();
  return id.isEmpty ? null : SubagentTarget.assistant(id);
}
