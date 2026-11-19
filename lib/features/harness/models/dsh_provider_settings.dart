/// The narrow settings seam behind the DSH 模型 tab.
///
/// DeepSeek Harness 0.2.2 has no provider CRUD RPCs. A provider profile is a
/// slice of engine settings (the adapter's namespace plus a path inside it),
/// its credential is a write-only reference, and both are written through
/// `settings/mutate` and `credentials/set` (docs/cuplivo-dsh/protocol.md
/// §4.4). This file is the *typed contract* the UI codes against: the adapter
/// that translates it into those calls lives in the foundation's services
/// layer and is injected later. Until it is wired, the 模型 tab still lists the
/// remote's live model catalog and the provider detail page says so instead
/// of inventing data.
///
/// Nothing here is persisted by Cuplivo: a load is a read of the remote host,
/// a save writes the remote host, and the UI keeps only what it is editing.
library;

import 'package:flutter/foundation.dart';

/// The API protocol a DSH provider route speaks (pi-ai wire values).
enum DshProviderApi {
  openAiChatCompletions('openai-completions'),
  openAiResponses('openai-responses'),
  anthropicMessages('anthropic-messages');

  const DshProviderApi(this.wireValue);

  /// The value the `api` field of a pi-ai provider profile carries.
  final String wireValue;

  static DshProviderApi? fromWire(String? value) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    for (final api in DshProviderApi.values) {
      if (api.wireValue == normalized) return api;
    }
    return null;
  }

  bool get isAnthropic => this == DshProviderApi.anthropicMessages;
}

/// One input modality a model advertises (`input` in a pi-ai model profile).
enum DshModelInput {
  text('text'),
  image('image');

  const DshModelInput(this.wireValue);

  final String wireValue;

  static DshModelInput? fromWire(String? value) {
    final normalized = value?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) return null;
    for (final input in DshModelInput.values) {
      if (input.wireValue == normalized) return input;
    }
    return null;
  }
}

/// One per-model reasoning-effort choice, only exposed by custom providers.
///
/// [id] is the value sent back as `reasoningEffort`; [name] is optional and
/// only used for display.
@immutable
class DshReasoningChoice {
  const DshReasoningChoice({required this.id, this.name});

  final String id;
  final String? name;

  String get title => (name ?? '').trim().isEmpty ? id : name!.trim();

  DshReasoningChoice copyWith({String? id, String? name}) =>
      DshReasoningChoice(id: id ?? this.id, name: name ?? this.name);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshReasoningChoice && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// One model inside a provider profile (`providers.<id>.models[]`).
@immutable
class DshProviderModel {
  const DshProviderModel({
    required this.id,
    this.name,
    this.contextWindow,
    this.maxTokens,
    this.inputs = const <DshModelInput>{DshModelInput.text},
    this.reasoningEfforts = const <DshReasoningChoice>[],
  });

  final String id;
  final String? name;
  final int? contextWindow;
  final int? maxTokens;
  final Set<DshModelInput> inputs;
  final List<DshReasoningChoice> reasoningEfforts;

  String get displayName => (name ?? '').trim().isEmpty ? id : name!.trim();

  DshProviderModel copyWith({
    String? id,
    String? name,
    int? contextWindow,
    bool clearContextWindow = false,
    int? maxTokens,
    bool clearMaxTokens = false,
    Set<DshModelInput>? inputs,
    List<DshReasoningChoice>? reasoningEfforts,
  }) => DshProviderModel(
    id: id ?? this.id,
    name: name ?? this.name,
    contextWindow: clearContextWindow
        ? null
        : contextWindow ?? this.contextWindow,
    maxTokens: clearMaxTokens ? null : maxTokens ?? this.maxTokens,
    inputs: inputs ?? this.inputs,
    reasoningEfforts: reasoningEfforts ?? this.reasoningEfforts,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshProviderModel &&
          other.id == id &&
          other.name == name &&
          other.contextWindow == contextWindow &&
          other.maxTokens == maxTokens &&
          setEquals(other.inputs, inputs) &&
          listEquals(other.reasoningEfforts, reasoningEfforts);

  @override
  int get hashCode => Object.hash(
    id,
    name,
    contextWindow,
    maxTokens,
    Object.hashAllUnordered(inputs),
    Object.hashAll(reasoningEfforts),
  );
}

/// One provider's editable profile.
@immutable
class DshProviderProfile {
  const DshProviderProfile({
    required this.api,
    this.baseURL,
    this.models = const <DshProviderModel>[],
  });

  final DshProviderApi api;
  final String? baseURL;
  final List<DshProviderModel> models;

  /// True when the profile declares no models, so the adapter supplies its
  /// own catalog ("正在使用适配器默认模型").
  bool get usesAdapterDefaults => models.isEmpty;

  DshProviderProfile copyWith({
    DshProviderApi? api,
    String? baseURL,
    bool clearBaseURL = false,
    List<DshProviderModel>? models,
  }) => DshProviderProfile(
    api: api ?? this.api,
    baseURL: clearBaseURL ? null : baseURL ?? this.baseURL,
    models: models ?? this.models,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshProviderProfile &&
          other.api == api &&
          other.baseURL == baseURL &&
          listEquals(other.models, models);

  @override
  int get hashCode => Object.hash(api, baseURL, Object.hashAll(models));
}

/// One provider route the host reports as configurable.
///
/// Fields mirror `llm/listConfigurableProviders` where they affect the UI:
/// the profile location ([settingsNs]/[settingsPath]), endpoint fallbacks
/// ([defaultBaseURL]/[baseURLEnv]) and authentication shape ([oauth],
/// [nativeAuthEnv]). [configured] comes from `credentials/describe` for the
/// route's credential reference.
@immutable
class DshProviderEntry {
  const DshProviderEntry({
    required this.id,
    required this.displayName,
    required this.settingsNs,
    required this.settingsPath,
    required this.profile,
    this.declared = false,
    this.defaultBaseURL,
    this.baseURLEnv = const <String>[],
    this.nativeAuthEnv = const <String>[],
    this.oauth = false,
    this.configured = false,
    this.credentialRef,
    this.revision,
    this.error,
  });

  /// The provider route id (`deepseek-official`, `anthropic`, …).
  final String id;

  /// The name the host shows; falls back to [id].
  final String displayName;

  /// Settings namespace holding this profile (`llm-deepseek`, `llm-pi-ai`).
  final String settingsNs;

  /// Path inside the namespace; empty for a whole-namespace profile.
  final List<String> settingsPath;

  final DshProviderProfile profile;

  /// `declared: true` means configuration added the route (a hand-added
  /// gateway); the row may then be deleted.
  final bool declared;

  final String? defaultBaseURL;
  final List<String> baseURLEnv;
  final List<String> nativeAuthEnv;
  final bool oauth;

  /// Whether the host reports a stored credential for this route.
  final bool configured;

  /// The credential reference to read/write with `credentials/*`.
  final String? credentialRef;

  /// The namespace revision this profile was read at; a write passes it as
  /// `expectedRevision` and a mismatch is a `settings/conflict`.
  final int? revision;

  /// A configuration diagnostic the host attached to this route.
  final String? error;

  String get effectiveDisplayName =>
      displayName.trim().isEmpty ? id : displayName.trim();

  bool get isCustom => declared;

  DshProviderEntry copyWith({
    String? displayName,
    DshProviderProfile? profile,
    bool? configured,
    int? revision,
  }) => DshProviderEntry(
    id: id,
    displayName: displayName ?? this.displayName,
    settingsNs: settingsNs,
    settingsPath: settingsPath,
    profile: profile ?? this.profile,
    declared: declared,
    defaultBaseURL: defaultBaseURL,
    baseURLEnv: baseURLEnv,
    nativeAuthEnv: nativeAuthEnv,
    oauth: oauth,
    configured: configured ?? this.configured,
    credentialRef: credentialRef,
    revision: revision ?? this.revision,
    error: error,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshProviderEntry &&
          other.id == id &&
          other.displayName == displayName &&
          other.settingsNs == settingsNs &&
          listEquals(other.settingsPath, settingsPath) &&
          other.profile == profile &&
          other.declared == declared &&
          other.defaultBaseURL == defaultBaseURL &&
          listEquals(other.baseURLEnv, baseURLEnv) &&
          listEquals(other.nativeAuthEnv, nativeAuthEnv) &&
          other.oauth == oauth &&
          other.configured == configured &&
          other.credentialRef == credentialRef &&
          other.revision == revision &&
          other.error == error;

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    settingsNs,
    Object.hashAll(settingsPath),
    profile,
    declared,
    defaultBaseURL,
    Object.hashAll(baseURLEnv),
    Object.hashAll(nativeAuthEnv),
    oauth,
    configured,
    credentialRef,
    revision,
    error,
  );
}

/// One write: the draft the detail page collected plus the revision the page
/// was looking at when it loaded.
@immutable
class DshProviderDraft {
  const DshProviderDraft({
    required this.providerId,
    required this.displayName,
    required this.settingsNs,
    required this.settingsPath,
    required this.profile,
    required this.expectedRevision,
    this.isNew = false,
    this.credentialRef,
    this.oauth = false,
  });

  /// The route target: the existing entry or the new provider id.
  final String providerId;
  final String displayName;
  final String settingsNs;
  final List<String> settingsPath;
  final DshProviderProfile profile;
  final int? expectedRevision;

  /// True when the adapter must create the profile instead of updating one.
  final bool isNew;
  final String? credentialRef;
  final bool oauth;
}

/// The remote's answer from `llm/discoverModels`.
@immutable
class DshDiscoveredModel {
  const DshDiscoveredModel({required this.id, this.name});

  final String id;
  final String? name;

  String get displayName => (name ?? '').trim().isEmpty ? id : name!.trim();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshDiscoveredModel && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// A user-actionable failure from the settings seam.
enum DshProviderSettingsFailure {
  /// No settings adapter is wired in this build.
  unavailable,

  /// The remote changed under the editor (`settings/conflict`).
  conflict,

  /// The remote refused the credential or the write.
  rejected,

  /// The link is not ready or the host is unreachable.
  unreachable,

  /// The host does not expose the needed method.
  unsupported,

  /// Anything else.
  unknown,
}

/// Thrown by [DshProviderSettingsGateway]; never a raw protocol error.
class DshProviderSettingsException implements Exception {
  const DshProviderSettingsException(this.failure, {this.detail});

  final DshProviderSettingsFailure failure;

  /// Technical cause for logs only; never rendered as UI copy.
  final String? detail;

  @override
  String toString() =>
      'DshProviderSettingsException(${failure.name}'
      '${detail == null ? '' : ': $detail'})';
}

/// The seam the 模型 tab reads and writes provider settings through.
///
/// Contract:
/// - [load] returns every configurable route with its profile and revision;
///   per-route problems are [DshProviderEntry.error], not a failed load.
/// - [save] and [delete] throw [DshProviderSettingsException] with
///   [DshProviderSettingsFailure.conflict] when [DshProviderDraft
///   .expectedRevision] is stale; the caller re-reads and retries.
/// - [setCredential] passes the plain value to the host and never returns it;
///   [clearCredential] removes one reference.
/// - [discover] asks the endpoint for its model list; a non-zero result is
///   advisory and never written without the user saving.
abstract interface class DshProviderSettingsGateway {
  Future<List<DshProviderEntry>> load();

  Future<DshProviderEntry> save(DshProviderDraft draft);

  /// Removes a declared (hand-added) provider profile.
  Future<void> delete(DshProviderEntry entry);

  Future<void> setCredential({required String ref, required String value});

  Future<void> clearCredential(String ref);

  Future<List<DshDiscoveredModel>> discover({
    required DshProviderApi api,
    required String baseURL,
    required String apiKey,
    String? providerId,
  });
}
