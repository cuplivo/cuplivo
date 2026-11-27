import '../../../core/providers/settings_provider.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/conversation.dart';
import '../../../core/services/decision/decision_client.dart';

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

/// Resolves the model a chat sends with, in priority order:
/// conversation override, then assistant default, then global default.
///
/// The conversation layer is skipped entirely when
/// [SettingsProvider.perChatModelEnabled] is off; pins stay in the database so
/// turning the setting back on restores each conversation's own model.
///
/// It is skipped for a group topic as well. A group writes every reply with its
/// speaker's own model, so a pin on the topic cannot mean anything: honouring
/// one would send every reply with that single model while the composer reports
/// the roster, and a pin left over from before the conversation became a topic
/// would do it silently.
///
/// This is the only place that chain should be written. Every caller that means
/// "the model this chat uses" goes through here or [getActiveModelIds].
({String? providerKey, String? modelId}) resolveChatModel(
  SettingsProvider settings, {
  Conversation? conversation,
  Assistant? assistant,
}) {
  final pinned =
      settings.perChatModelEnabled && conversation?.isGroupConversation != true
      ? conversation
      : null;
  final providerKey =
      pinned?.chatModelProvider ??
      assistant?.chatModelProvider ??
      settings.currentModelProvider;
  final modelId =
      pinned?.chatModelId ?? assistant?.chatModelId ?? settings.currentModelId;
  return (providerKey: providerKey, modelId: modelId);
}

/// Resolves the model that writes a conversation's title.
///
/// The title model is a global preference and wins everywhere. Without it a
/// 1:1 chat falls back to the model that chat sends with; a group topic has no
/// chat model of its own — the group's is the director's — so it falls back to
/// the director model and then to the global default.
///
/// A director that is not a chat model is skipped: a decision model answers one
/// typed question and produces no text, so asking it for a title means a
/// request that can only fail — and the group keeps its placeholder name.
///
/// This is the only place the title-model chain is written: both the
/// end-of-round path and the sidebar's "regenerate title" go through it.
({String? providerKey, String? modelId}) resolveTitleModel(
  SettingsProvider settings, {
  Conversation? conversation,
  Assistant? assistant,
}) {
  final titleProvider = settings.titleModelProvider;
  final titleModel = settings.titleModelId;
  if (titleProvider != null && titleModel != null) {
    return (providerKey: titleProvider, modelId: titleModel);
  }
  if (conversation?.isGroupConversation == true) {
    final providerKey =
        settings.directorModelProvider ?? settings.currentModelProvider;
    final modelId = settings.directorModelId ?? settings.currentModelId;
    if (!_isDecisionModel(settings, providerKey, modelId)) {
      return (providerKey: providerKey, modelId: modelId);
    }
  }
  return resolveChatModel(
    settings,
    conversation: conversation,
    assistant: assistant,
  );
}

bool _isDecisionModel(
  SettingsProvider settings,
  String? providerKey,
  String? modelId,
) {
  if (providerKey == null || modelId == null) return false;
  final config = settings.getProviderConfig(providerKey);
  return DecisionClient.canDecide(config, modelId);
}

/// The name a model shows under: the provider's own name for it, else the API
/// id it is sent upstream as, else the raw id.
///
/// This is the one place that rule lives — the chat's model line, the drawing
/// sub-row and the subagent summary all ask here. The name is read when it is
/// shown and never stored beside the ids, so renaming a model renames it
/// everywhere, and a binding whose provider is gone still names its raw id.
String modelDisplayName(
  SettingsProvider settings,
  String providerId,
  String modelId,
) {
  try {
    final override =
        settings.getProviderConfig(providerId).modelOverrides[modelId] as Map?;
    final name = (override?['name'] as String?)?.trim();
    if (name != null && name.isNotEmpty) return name;
    final apiId = (override?['apiModelId'] ?? override?['api_model_id'])
        ?.toString()
        .trim();
    if (apiId != null && apiId.isNotEmpty) return apiId;
  } catch (_) {
    // A malformed override is a display problem, not a reason to drop the row.
  }
  return modelId;
}

/// Extracts model display information from settings, conversation and assistant.
///
/// This consolidates the repeated pattern of resolving the active model and
/// then applying the provider's per-model display overrides.
ModelDisplayInfo getModelDisplayInfo(
  SettingsProvider settings, {
  Conversation? conversation,
  Assistant? assistant,
}) {
  final resolved = resolveChatModel(
    settings,
    conversation: conversation,
    assistant: assistant,
  );
  final providerKey = resolved.providerKey;
  final modelId = resolved.modelId;

  if (providerKey == null || modelId == null) {
    return const ModelDisplayInfo();
  }

  final cfg = settings.getProviderConfig(providerKey);
  final providerName = cfg.name.isNotEmpty ? cfg.name : providerKey;

  return ModelDisplayInfo(
    providerName: providerName,
    modelDisplay: modelDisplayName(settings, providerKey, modelId),
    providerKey: providerKey,
    modelId: modelId,
  );
}

/// Gets just the provider key and model ID without display formatting.
///
/// Use this when you only need the raw identifiers for API calls.
({String? providerKey, String? modelId}) getActiveModelIds(
  SettingsProvider settings, {
  Conversation? conversation,
  Assistant? assistant,
}) => resolveChatModel(
  settings,
  conversation: conversation,
  assistant: assistant,
);

/// Gets the ProviderConfig for the active model.
ProviderConfig? getActiveProviderConfig(
  SettingsProvider settings, {
  Conversation? conversation,
  Assistant? assistant,
}) {
  final providerKey = resolveChatModel(
    settings,
    conversation: conversation,
    assistant: assistant,
  ).providerKey;
  if (providerKey == null) return null;
  return settings.getProviderConfig(providerKey);
}
