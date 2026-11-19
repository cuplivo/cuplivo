// Pure mapping for the DSH provider-settings seam.
//
// DeepSeek Harness stores a provider route as one slice of settings and its
// credential as a write-only reference; this file turns the client's settings
// JSON and configurable-provider roster into the typed models the 模型 tab
// edits, and turns an edited profile back into `settings/mutate` JSON. No
// sockets, no clocks, no Flutter — the adapter owns those.

import 'package:Cuplivo/core/dsh/dsh_errors.dart' as dsh;
import 'package:Cuplivo/core/dsh/dsh_models.dart' as dsh;

import '../models/dsh_provider_settings.dart';

/// Credential references are batched; the Host caps one `credentials/describe`
/// call (`MAX_DESCRIBE_REFS` in `lib/core/dsh`).
const int dshCredentialDescribeChunk = 64;

// ---------------------------------------------------------------------------
// Failures
// ---------------------------------------------------------------------------

/// The user-actionable failure for one raw client error.
DshProviderSettingsException dshProviderSettingsExceptionFromClient(
  dsh.DshException error,
) {
  final failure = switch (error) {
    dsh.DshUnsupportedException() => DshProviderSettingsFailure.unsupported,
    dsh.DshAuthException() ||
    dsh.DshTransportException() ||
    dsh.DshClosedException() => DshProviderSettingsFailure.unreachable,
    dsh.DshRemoteException(:final code) => _failureForCode(code),
    dsh.DshProtocolException() ||
    dsh.DshEndpointException() => DshProviderSettingsFailure.unknown,
  };
  return DshProviderSettingsException(failure, detail: error.message);
}

DshProviderSettingsFailure _failureForCode(String code) {
  final normalized = code.toLowerCase();
  if (normalized.contains('conflict')) {
    return DshProviderSettingsFailure.conflict;
  }
  if (normalized.contains('credential') || normalized.contains('rejected')) {
    return DshProviderSettingsFailure.rejected;
  }
  if (normalized.contains('not-found') || normalized.contains('unsupported')) {
    return DshProviderSettingsFailure.unsupported;
  }
  if (normalized.contains('auth') || normalized.contains('unauthorized')) {
    return DshProviderSettingsFailure.unreachable;
  }
  return DshProviderSettingsFailure.unknown;
}

// ---------------------------------------------------------------------------
// Reading a provider profile
// ---------------------------------------------------------------------------

/// The profile JSON for one route, read from `settings/describe`.
///
/// `settingsPath` is empty for a whole-namespace route (`llm-deepseek`) and
/// `['providers', <id>]` for a `llm-pi-ai` route; an absent path is `{}` so a
/// route without a stored (user-layer) profile still lists.
Map<String, Object?> dshProviderProfileSection(
  dsh.DshSettingsDescription description,
  String settingsNamespace,
  List<String> settingsPath,
) {
  Object? value = description.namespace(settingsNamespace)?.value;
  for (final key in settingsPath) {
    value = dsh.jsonMap(value)[key];
  }
  return dsh.jsonMap(value);
}

/// The revision of the namespace that holds [settingsPath]'s profile.
int? dshProviderSettingsRevision(
  dsh.DshSettingsDescription description,
  String settingsNamespace,
) => description.namespace(settingsNamespace)?.revision;

/// The stored credential reference for a route: the profile's `apiKeyEnv`,
/// else the official page's derived `<ROUTE>_API_KEY`.
String dshProviderCredentialRef(
  dsh.DshConfigurableProvider provider,
  Map<String, Object?> profile,
) {
  final stored = dsh.jsonString(profile['apiKeyEnv'])?.trim();
  return stored != null && stored.isNotEmpty ? stored : provider.derivedKeyRef;
}

/// One entry in the 模型 tab's provider list.
DshProviderEntry dshProviderSettingsEntry({
  required dsh.DshConfigurableProvider provider,
  required Map<String, Object?> profile,
  required int? revision,
  required bool configured,
  String? credentialRef,
}) {
  final parsed = dshProviderProfileFromJson(
    profile,
    providerId: provider.provider,
    defaultBaseURL: provider.defaultBaseURL,
  );
  final displayName = dsh.jsonString(profile['displayName'])?.trim() ?? '';
  return DshProviderEntry(
    id: provider.provider,
    displayName: displayName.isEmpty ? provider.displayName : displayName,
    settingsNs: provider.settingsNs,
    settingsPath: provider.settingsPath,
    profile: parsed,
    declared: provider.declared == true,
    defaultBaseURL: provider.defaultBaseURL,
    baseURLEnv: provider.baseURLEnv,
    nativeAuthEnv: provider.nativeAuthEnv,
    oauth: provider.nativeAuthOauth,
    configured: configured,
    credentialRef: credentialRef ?? dshProviderCredentialRef(provider, profile),
    revision: revision,
    error: dsh.jsonString(provider.raw['error']),
  );
}

/// Parses one profile value. Unknown fields are ignored here and preserved on
/// save by [dshMergedProviderProfileJson].
DshProviderProfile dshProviderProfileFromJson(
  Map<String, Object?> profile, {
  required String providerId,
  String? defaultBaseURL,
}) {
  final models = <DshProviderModel>[];
  for (final value in dsh.jsonList(profile['models'])) {
    final model = _dshProviderModelFromJson(value);
    if (model != null) models.add(model);
  }
  return DshProviderProfile(
    api:
        DshProviderApi.fromWire(dsh.jsonString(profile['api'])) ??
        _inferredProviderApi(providerId, defaultBaseURL),
    baseURL: dsh.jsonString(profile['baseURL']),
    models: models,
  );
}

DshProviderApi _inferredProviderApi(String providerId, String? defaultBaseURL) {
  // The shipped adapters know their protocol; their stored profile does not
  // repeat it. Anthropic-shaped routes are the only ones the UI's two hints
  // distinguish, so infer those and treat everything else as OpenAI-compatible
  // chat completions (the pi-ai default and DeepSeek's own shape).
  final haystack = '$providerId ${defaultBaseURL ?? ''}'.toLowerCase();
  if (haystack.contains('anthropic') || haystack.contains('claude')) {
    return DshProviderApi.anthropicMessages;
  }
  return DshProviderApi.openAiChatCompletions;
}

DshProviderModel? _dshProviderModelFromJson(Object? value) {
  final map = dsh.jsonMap(value);
  final id = dsh.jsonString(map['id'])?.trim() ?? '';
  if (id.isEmpty) return null;
  final inputs = <DshModelInput>{};
  for (final input in dsh.jsonList(map['input'])) {
    final parsed = DshModelInput.fromWire(dsh.jsonString(input));
    if (parsed != null) inputs.add(parsed);
  }
  if (inputs.isEmpty) inputs.add(DshModelInput.text);
  final efforts = <DshReasoningChoice>[];
  final rawEfforts = map['reasoningEfforts'];
  if (rawEfforts is List) {
    for (final effort in rawEfforts) {
      final choice = _dshReasoningChoiceFromJson(effort);
      if (choice != null) efforts.add(choice);
    }
  } else if (rawEfforts is Map) {
    // The adapter also accepts a `{level: apiValue}` map; display the level.
    for (final entry in rawEfforts.entries) {
      final level = dsh.jsonString(entry.key)?.trim() ?? '';
      if (level.isEmpty) continue;
      final rawName = entry.value;
      efforts.add(
        DshReasoningChoice(id: level, name: rawName is String ? rawName : null),
      );
    }
  }
  return DshProviderModel(
    id: id,
    name: dsh.jsonString(map['name']),
    contextWindow: dsh.jsonInt(map['contextWindow']),
    maxTokens: dsh.jsonInt(map['maxTokens']),
    inputs: inputs,
    reasoningEfforts: efforts,
  );
}

DshReasoningChoice? _dshReasoningChoiceFromJson(Object? value) {
  if (value is String) {
    final id = value.trim();
    return id.isEmpty ? null : DshReasoningChoice(id: id);
  }
  final map = dsh.jsonMap(value);
  final id = dsh.jsonString(map['id'])?.trim() ?? '';
  if (id.isEmpty) return null;
  return DshReasoningChoice(id: id, name: dsh.jsonString(map['name']));
}

// ---------------------------------------------------------------------------
// Writing a provider profile
// ---------------------------------------------------------------------------

/// The profile JSON to store for [draft].
///
/// Existing unknown fields survive: the write replaces the profile slice, so
/// the merge starts from the profile currently on the Host and only touches
/// the fields R11 exposes.
///
/// - a new route and a user-declared (`declared: true`) route rewrite `models`
///   (that is the only place the UI edits them); shipped routes keep the
///   Host's array verbatim, including fields Cuplivo does not render;
/// - `api` is written for a new route and for routes that already store it;
///   shipped routes that omit it keep omitting it (their adapter supplies it);
/// - `baseURL` is written when set and removed when the user cleared it;
/// - `apiKeyEnv` is written for new routes; existing routes keep theirs and the
///   credential ref is used only by `credentials/set`.
Map<String, Object?> dshMergedProviderProfileJson({
  required Map<String, Object?> current,
  required DshProviderDraft draft,
  required bool declared,
}) {
  final value = Map<String, Object?>.of(current);
  if (draft.isNew) {
    final name = draft.displayName.trim();
    if (name.isNotEmpty) value['displayName'] = name;
    final ref = draft.credentialRef?.trim();
    if (ref != null && ref.isNotEmpty) value['apiKeyEnv'] = ref;
  }
  if (draft.isNew || value.containsKey('api')) {
    value['api'] = draft.profile.api.wireValue;
  }
  final baseURL = draft.profile.baseURL?.trim();
  if (baseURL == null || baseURL.isEmpty) {
    value.remove('baseURL');
  } else {
    value['baseURL'] = baseURL;
  }
  if (draft.isNew || declared) {
    value['models'] = [
      for (final model in draft.profile.models) dshProviderModelJson(model),
    ];
  }
  return value;
}

Map<String, Object?> dshProviderModelJson(DshProviderModel model) {
  final name = model.name?.trim();
  final inputs = model.inputs.isEmpty
      ? const <DshModelInput>{DshModelInput.text}
      : model.inputs;
  return {
    'id': model.id,
    if (name != null && name.isNotEmpty) 'name': name,
    if (model.contextWindow != null) 'contextWindow': model.contextWindow,
    if (model.maxTokens != null) 'maxTokens': model.maxTokens,
    'input': [for (final input in inputs) input.wireValue],
    'reasoningEfforts': model.reasoningEfforts.isEmpty
        ? false
        : [
            for (final effort in model.reasoningEfforts)
              {
                'id': effort.id,
                if ((effort.name ?? '').trim().isNotEmpty)
                  'name': effort.name!.trim(),
              },
          ],
  };
}
