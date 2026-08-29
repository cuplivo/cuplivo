import '../../../core/providers/settings_provider.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/conversation.dart';

/// Helper class for extracting model display information.
///
/// This class eliminates repetitive code patterns for getting provider/model
/// information that was duplicated across multiple locations in home_page.dart.
class ModelDisplayInfo {
  const ModelDisplayInfo({
    this.providerName,
    this.modelDisplay,
    this.providerKey,
    this.modelId,
  });

  /// Display name of the provider (e.g., "OpenAI", "Anthropic")
  final String? providerName;

  /// Display name of the model (from override, apiModelId, or raw modelId)
  final String? modelDisplay;

  /// Raw provider key used in settings
  final String? providerKey;

  /// Raw model ID
  final String? modelId;

  /// Check if both provider and model are configured
  bool get isConfigured => providerKey != null && modelId != null;

  /// Get the ProviderConfig for this model (if configured)
  ProviderConfig? getConfig(SettingsProvider settings) {
    if (providerKey == null) return null;
    return settings.getProviderConfig(providerKey!);
  }
}

/// Extracts model display information from settings and assistant.
///
/// This consolidates the repeated pattern of:
/// ```dart
/// final providerKey = assistant?.chatModelProvider ?? settings.currentModelProvider;
/// final modelId = assistant?.chatModelId ?? settings.currentModelId;
/// if (providerKey != null && modelId != null) {
///   final cfg = settings.getProviderConfig(providerKey);
///   final ov = cfg.modelOverrides[modelId] as Map?;
///   // ...handle overrides
/// }
/// ```
ModelDisplayInfo getModelDisplayInfo(
  SettingsProvider settings, {
  Assistant? assistant,
  Conversation? conversation,
}) {
  // Determine provider and model: conversation binding → assistant → global
  final resolved = resolveChatModel(settings, assistant, conversation);
  final providerKey = resolved.providerKey;
  final modelId = resolved.modelId;

  if (providerKey == null || modelId == null) {
    return const ModelDisplayInfo();
  }

  final cfg = settings.getProviderConfig(providerKey);
  final providerName = cfg.name.isNotEmpty ? cfg.name : providerKey;

  // Extract model display name from overrides or use raw modelId
  String modelDisplay = modelId;
  final ov = cfg.modelOverrides[modelId] as Map?;
  if (ov != null) {
    // Priority: override name > apiModelId > api_model_id > raw modelId
    final overrideName = (ov['name'] as String?)?.trim();
    if (overrideName != null && overrideName.isNotEmpty) {
      modelDisplay = overrideName;
    } else {
      final apiId = (ov['apiModelId'] ?? ov['api_model_id'])?.toString().trim();
      if (apiId != null && apiId.isNotEmpty) {
        modelDisplay = apiId;
      }
    }
  }

  return ModelDisplayInfo(
    providerName: providerName,
    modelDisplay: modelDisplay,
    providerKey: providerKey,
    modelId: modelId,
  );
}

/// The effective chat model chain (ADR-0045):
/// conversation binding → assistant binding → global default.
/// Toggle-agnostic — the toggle only gates write/creation-time behavior.
({String? providerKey, String? modelId}) resolveChatModel(
  SettingsProvider settings,
  Assistant? assistant,
  Conversation? conversation,
) {
  return (
    providerKey:
        conversation?.chatModelProvider ??
        assistant?.chatModelProvider ??
        settings.currentModelProvider,
    modelId:
        conversation?.chatModelId ??
        assistant?.chatModelId ??
        settings.currentModelId,
  );
}

/// Gets just the provider key and model ID without display formatting.
///
/// Use this when you only need the raw identifiers for API calls.
({String? providerKey, String? modelId}) getActiveModelIds(
  SettingsProvider settings, {
  Assistant? assistant,
  Conversation? conversation,
}) {
  return resolveChatModel(settings, assistant, conversation);
}

/// Gets the ProviderConfig for the active model.
ProviderConfig? getActiveProviderConfig(
  SettingsProvider settings, {
  Assistant? assistant,
  Conversation? conversation,
}) {
  final providerKey = resolveChatModel(
    settings,
    assistant,
    conversation,
  ).providerKey;
  if (providerKey == null) return null;
  return settings.getProviderConfig(providerKey);
}
