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

import '../../../core/models/assistant.dart';
import '../../../core/providers/settings_provider.dart';

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
///
/// [isValid] is the caller's answer to "does this pair still exist?". The
/// assistant's choice is a stored pair, and a stored pair can outlive its
/// provider (deleted, disabled, another device's export): without this hook the
/// dead pair keeps winning over the global default that is still configured, and
/// the job fails with a transport error instead of the tool's honest
/// "not configured" refusal. A rejected pair falls through to the next level.
ResolvedModel resolveModelBinding({
  String? assistantProviderId,
  String? assistantModelId,
  String? globalProviderId,
  String? globalModelId,
  bool Function(ModelBinding binding)? isValid,
}) {
  final assistant = _binding(assistantProviderId, assistantModelId);
  if (assistant != null && (isValid == null || isValid(assistant))) {
    return ResolvedModel(binding: assistant, source: ModelSource.assistant);
  }
  final global = _binding(globalProviderId, globalModelId);
  if (global != null && (isValid == null || isValid(global))) {
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

/// The resolution the app actually runs for a drawing job: the pure rule above
/// plus the one thing only [SettingsProvider] knows — whether the provider a
/// stored pair names still exists. The sub-row and the coordinator both call
/// this, so what the row promises and what the tool does cannot disagree.
ResolvedModel resolveImageModelFor(
  SettingsProvider settings,
  Assistant? assistant,
) {
  return resolveModelBinding(
    assistantProviderId: assistant?.imageModelProvider,
    assistantModelId: assistant?.imageModelId,
    globalProviderId: settings.imageModelProvider,
    globalModelId: settings.imageModelId,
    isValid: (binding) =>
        settings.providerConfigs.containsKey(binding.providerId),
  );
}
