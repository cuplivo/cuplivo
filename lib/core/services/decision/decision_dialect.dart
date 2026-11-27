import '../../providers/settings_provider.dart';

/// Which decision protocol a model speaks.
///
/// Two dialects exist and they are not compatible: System One (TypeSafe Jev,
/// Alibaba Bailian, Turing, Kev, and the Jev routes on gateways) and OpenAI's
/// `/v1/decisions`. A decision model therefore carries its dialect in its own
/// override — the endpoint's host name is not evidence, because a gateway can
/// serve either one.
enum DecisionDialect { systemOne, openAi }

abstract final class DecisionDialectSetting {
  static const String overrideKey = 'decisionDialect';

  /// A full URL the user typed for this model, or null when the dialect's own
  /// path should be used.
  ///
  /// Gateways put decisions on their own path — OpenRouter serves them at
  /// `https://openrouter.ai/api/alpha/decisions`, outside the provider's `/v1`
  /// chat base — so the address cannot be derived from the chat base URL.
  static const String urlOverrideKey = 'decisionUrl';

  /// The dialect [modelId] declares, defaulting to System One.
  static DecisionDialect of(ProviderConfig config, String modelId) {
    final override = config.modelOverrides[modelId];
    final raw = override is Map ? override[overrideKey]?.toString() : null;
    return switch (raw?.trim().toLowerCase()) {
      'openai' || 'decisions' => DecisionDialect.openAi,
      _ => DecisionDialect.systemOne,
    };
  }

  static String? urlOverride(ProviderConfig config, String modelId) {
    final override = config.modelOverrides[modelId];
    if (override is! Map) return null;
    final raw = override[urlOverrideKey]?.toString().trim();
    return raw == null || raw.isEmpty ? null : raw;
  }

  static String encode(DecisionDialect dialect) => switch (dialect) {
    DecisionDialect.systemOne => 'systemone',
    DecisionDialect.openAi => 'openai',
  };
}
