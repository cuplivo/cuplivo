/// The model a delegation runs on.
///
/// A subagent inherits the assistant and the workspace of the conversation that
/// started it, and by default it also inherits that conversation's model — which
/// is what the user is already paying for and what the parent's own turns use. An
/// assistant may override it once, for assistants that delegate to something
/// cheaper or stronger; the override lives on the assistant's JSON next to the
/// drawing model, so the schema stays at 5.
///
/// The resolution takes the target as well as the delegator. Today both kinds of
/// target answer the same thing — a named assistant runs on its own model
/// because its conversation carries its id — but the question ("should `general`
/// and a named assistant be allowed to differ?") is the one this signature
/// leaves room for, and the tests pin a cell per kind.
library;

import '../../../core/models/assistant.dart';
import 'subagent_target.dart';

/// A model pair chosen for delegations.
final class SubagentModelBinding {
  const SubagentModelBinding({required this.providerId, required this.modelId});

  final String providerId;
  final String modelId;
}

/// The model a child should run on, or null to let the child's assistant decide.
///
/// One tier plus "inherit": the parent conversation already carries the user's
/// choice for this chat, and a global default on top of that would only give the
/// picker a third place to hide in.
///
/// The delegator's override wins for both kinds of target: it is the user saying
/// "everything this assistant delegates runs on that model", which is a stronger
/// statement than the target's own default. With no override the child follows
/// its own assistant — for `general` that is the delegator, for a named target it
/// is the assistant the user picked, which is the point of picking it.
SubagentModelBinding? resolveSubagentModel(
  Assistant? delegator, {
  SubagentTarget? target,
}) {
  final provider = delegator?.subagentModelProvider?.trim();
  final model = delegator?.subagentModelId?.trim();
  if (provider == null || provider.isEmpty) return null;
  if (model == null || model.isEmpty) return null;
  return SubagentModelBinding(providerId: provider, modelId: model);
}
