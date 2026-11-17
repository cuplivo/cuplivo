/// Which provider + model a job of a given kind runs on.
///
/// Two levels, innermost first: the assistant's own choice, then the global
/// default from 设置 → 默认模型. There is deliberately no conversation level:
/// a conversation already points at an assistant, and a third layer makes
/// "which model drew this" unanswerable.
///
/// The same rule serves every job kind (image today, delegate later): a job is
/// `kind + model`, and the model is resolved here, not chosen by the text model.
library;

final class ModelBinding {
  const ModelBinding({required this.providerId, required this.modelId});

  final String providerId;
  final String modelId;

  bool get isConfigured => providerId.isNotEmpty && modelId.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModelBinding &&
          providerId == other.providerId &&
          modelId == other.modelId;

  @override
  int get hashCode => Object.hash(providerId, modelId);

  @override
  String toString() => 'ModelBinding($providerId, $modelId)';
}

/// Resolution result, so the UI can say *why* this model was picked.
final class ResolvedModel {
  const ResolvedModel({required this.binding, required this.source});

  final ModelBinding? binding;
  final ModelSource source;

  bool get isConfigured => binding != null;
}

enum ModelSource {
  /// The assistant picked it explicitly.
  assistant,

  /// Fallthrough to 设置 → 默认模型.
  global,

  /// Nothing configured anywhere; the tool must answer with a fixable error.
  none,
}

/// Pure resolution: hand it the four ids that can exist and it decides.
///
/// An id pair only counts when *both* halves are non-empty — a provider without
/// a model (or the reverse) is a half-configured row and must not silently win.
ResolvedModel resolveModelBinding({
  String? assistantProviderId,
  String? assistantModelId,
  String? globalProviderId,
  String? globalModelId,
}) {
  final assistant = _binding(assistantProviderId, assistantModelId);
  if (assistant != null) {
    return ResolvedModel(binding: assistant, source: ModelSource.assistant);
  }
  final global = _binding(globalProviderId, globalModelId);
  if (global != null) {
    return ResolvedModel(binding: global, source: ModelSource.global);
  }
  return const ResolvedModel(binding: null, source: ModelSource.none);
}

ModelBinding? _binding(String? providerId, String? modelId) {
  final provider = providerId?.trim() ?? '';
  final model = modelId?.trim() ?? '';
  if (provider.isEmpty || model.isEmpty) return null;
  return ModelBinding(providerId: provider, modelId: model);
}
