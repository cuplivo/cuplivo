import '../../providers/model_provider.dart';
import '../../providers/settings_provider.dart';

/// Single source of truth for model ability overrides and registry inference.
class ModelCapabilityService {
  const ModelCapabilityService._();

  static bool supportsTools(
    SettingsProvider settings,
    String providerKey,
    String modelId,
  ) => supportsToolsForConfig(settings.getProviderConfig(providerKey), modelId);

  static bool supportsToolsForConfig(ProviderConfig config, String modelId) =>
      _abilitiesForConfig(config, modelId).contains('tool');

  static bool supportsReasoning(
    SettingsProvider settings,
    String providerKey,
    String modelId,
  ) => _abilitiesForConfig(
    settings.getProviderConfig(providerKey),
    modelId,
  ).contains('reasoning');

  static Set<String> _abilitiesForConfig(
    ProviderConfig config,
    String modelId,
  ) {
    final override = config.modelOverrides[modelId] as Map?;
    if (override != null && override.containsKey('abilities')) {
      return (override['abilities'] as List? ?? const <Object>[])
          .map((ability) => ability.toString().trim().toLowerCase())
          .where((ability) => ability.isNotEmpty)
          .toSet();
    }

    final inferred = ModelRegistry.infer(
      ModelInfo(id: modelId, displayName: modelId),
    );
    return inferred.abilities.map((ability) => ability.name).toSet();
  }
}
