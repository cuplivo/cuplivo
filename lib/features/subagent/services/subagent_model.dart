/// The model a delegation runs on.
///
/// A subagent inherits the assistant and the workspace of the conversation that
/// started it, and by default it also inherits that conversation's model — which
/// is what the user is already paying for and what the parent's own turns use. An
/// assistant may override it once, for assistants that delegate to something
/// cheaper or stronger; the override lives on the assistant's JSON next to the
/// drawing model, so the schema stays at 5.
library;

import '../../../core/models/assistant.dart';

/// A model pair chosen for delegations.
final class SubagentModelBinding {
  const SubagentModelBinding({required this.providerId, required this.modelId});

  final String providerId;
  final String modelId;
}

/// The model a child should run on, or null to follow the conversation's own.
///
/// One tier plus "inherit": the parent conversation already carries the user's
/// choice for this chat, and a global default on top of that would only give the
/// picker a third place to hide in.
SubagentModelBinding? resolveSubagentModel(Assistant? assistant) {
  final provider = assistant?.subagentModelProvider?.trim();
  final model = assistant?.subagentModelId?.trim();
  if (provider == null || provider.isEmpty) return null;
  if (model == null || model.isEmpty) return null;
  return SubagentModelBinding(providerId: provider, modelId: model);
}
