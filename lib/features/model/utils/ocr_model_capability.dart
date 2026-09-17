import '../../../core/models/assistant.dart';
import '../../../core/providers/model_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/model_override_resolver.dart';

bool modelSupportsOcrImageInput(
  SettingsProvider settings,
  String providerKey,
  String modelId,
) {
  final cfg = settings.getProviderConfig(providerKey);
  final rawOverride = cfg.modelOverrides[modelId];
  final override = rawOverride is Map
      ? {for (final e in rawOverride.entries) e.key.toString(): e.value}
      : null;

  var baseId = modelId;
  final rawApiModelId = (override?['apiModelId'] ?? override?['api_model_id'])
      ?.toString()
      .trim();
  if (rawApiModelId != null && rawApiModelId.isNotEmpty) {
    baseId = rawApiModelId;
  }

  var info = ModelRegistry.infer(ModelInfo(id: baseId, displayName: baseId));
  if (override != null) {
    info = ModelOverrideResolver.applyModelOverride(info, override);
  }
  return info.input.contains(Modality.image);
}

/// Resolves whether the current send should run OCR instead of sending images
/// raw, based on the per-assistant [Assistant.ocrMode]:
/// - 'never' -> never OCR (images go to the model or are stripped upstream);
/// - 'always' -> always OCR (requires a configured OCR model);
/// - 'auto' (default) -> OCR only when the resolved model lacks image input.
/// A missing OCR model config disables OCR in every mode.
bool resolveOcrActive({
  required SettingsProvider settings,
  required Assistant? assistant,
  required String providerKey,
  required String modelId,
}) {
  final mode = assistant?.ocrMode ?? 'auto';
  if (mode == 'never') return false;
  if (!settings.ocrEnabled) return false;
  if (settings.ocrModelProvider == null || settings.ocrModelId == null) {
    return false;
  }
  if (mode == 'always') return true;
  return !modelSupportsOcrImageInput(settings, providerKey, modelId);
}
