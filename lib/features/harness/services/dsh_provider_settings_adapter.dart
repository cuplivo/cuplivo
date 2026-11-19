// The real provider-settings seam: reads and writes DSH provider routes over
// `settings/describe` + `settings/mutate` + `credentials/*`.
//
// DeepSeek Harness 0.2.2 has no provider CRUD endpoint; a route's profile is a
// slice of one settings namespace and its credential is a write-only reference
// (docs/cuplivo-dsh/protocol.md §4.4). The 模型 tab codes against
// `DshProviderSettingsGateway`; this class is the translation and the only
// place a `settings/conflict` becomes `DshProviderSettingsFailure.conflict`.

import 'dart:math' as math;

import 'package:Cuplivo/core/dsh/dsh_catalog.dart' as dsh;
import 'package:Cuplivo/core/dsh/dsh_errors.dart' as dsh;
import 'package:Cuplivo/core/dsh/dsh_models.dart' as dsh;

import '../models/dsh_provider_settings.dart';
import '../state/dsh_gateway.dart';
import 'dsh_provider_settings_mapping.dart';

/// Adapts one live [dsh.DshClient] to [DshProviderSettingsGateway].
///
/// The client callback is resolved on every call: the owning gateway replaces
/// its client on reconnect, and a settings page kept open across a reconnect
/// must not keep talking to the old socket.
class DshClientProviderSettings implements DshProviderSettingsGateway {
  DshClientProviderSettings({
    required dsh.DshClient Function() client,
    this.discoveryTimeout = const Duration(seconds: 120),
  }) : _client = client;

  final dsh.DshClient Function() _client;
  final Duration discoveryTimeout;

  dsh.DshClient get _dsh {
    try {
      return _client();
    } on DshGatewayException catch (error) {
      throw DshProviderSettingsException(
        DshProviderSettingsFailure.unreachable,
        detail: error.detail,
      );
    }
  }

  // -------------------------------------------------------------------------
  // Read

  @override
  Future<List<DshProviderEntry>> load() async {
    final client = _dsh;
    try {
      final providers = await client.catalog.listConfigurableProviders();
      final description = await client.catalog.describeSettings();
      final profiles = <String, Map<String, Object?>>{
        for (final provider in providers)
          provider.provider: dshProviderProfileSection(
            description,
            provider.settingsNs,
            provider.settingsPath,
          ),
      };
      final refs = <String>{
        for (final provider in providers)
          dshProviderCredentialRef(provider, profiles[provider.provider]!),
      };
      final credentials = await _describeCredentials(client, refs);
      return [
        for (final provider in providers)
          dshProviderSettingsEntry(
            provider: provider,
            profile: profiles[provider.provider]!,
            revision: dshProviderSettingsRevision(
              description,
              provider.settingsNs,
            ),
            configured:
                credentials[dshProviderCredentialRef(
                      provider,
                      profiles[provider.provider]!,
                    )]
                    ?.configured ??
                false,
          ),
      ];
    } on dsh.DshException catch (error) {
      throw dshProviderSettingsExceptionFromClient(error);
    }
  }

  Future<Map<String, dsh.DshCredentialInfo>> _describeCredentials(
    dsh.DshClient client,
    Set<String> refs,
  ) async {
    final pending = refs
        .map((ref) => ref.trim())
        .where((ref) => ref.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final result = <String, dsh.DshCredentialInfo>{};
    for (
      var start = 0;
      start < pending.length;
      start += dshCredentialDescribeChunk
    ) {
      final end = math.min(start + dshCredentialDescribeChunk, pending.length);
      result.addAll(
        await client.catalog.describeCredentials(pending.sublist(start, end)),
      );
    }
    return result;
  }

  // -------------------------------------------------------------------------
  // Write

  @override
  Future<DshProviderEntry> save(DshProviderDraft draft) async {
    final client = _dsh;
    try {
      final providers = await client.catalog.listConfigurableProviders();
      final description = await client.catalog.describeSettings();
      final namespace = description.namespace(draft.settingsNs);
      if (namespace == null) {
        throw DshProviderSettingsException(
          DshProviderSettingsFailure.unsupported,
          detail: 'the Host does not expose ${draft.settingsNs}',
        );
      }
      final existing = _providerById(providers, draft.providerId);
      if (draft.isNew && existing != null) {
        throw const DshProviderSettingsException(
          DshProviderSettingsFailure.rejected,
          detail: 'that provider id already exists',
        );
      }
      if (!draft.isNew && existing == null) {
        throw const DshProviderSettingsException(
          DshProviderSettingsFailure.unsupported,
          detail: 'that provider route is not configurable on this Host',
        );
      }
      // The page loaded at `expectedRevision`; a newer namespace means another
      // window (or the official UI) wrote first. Reload instead of clobbering.
      if (draft.expectedRevision != null &&
          namespace.revision != draft.expectedRevision) {
        throw const DshProviderSettingsException(
          DshProviderSettingsFailure.conflict,
        );
      }
      final declared = existing?.declared == true;
      final profile = dshMergedProviderProfileJson(
        current: dshProviderProfileSection(
          description,
          draft.settingsNs,
          draft.settingsPath,
        ),
        draft: draft,
        declared: declared,
      );
      final written = await client.catalog.mutateSettings(draft.settingsNs, [
        dsh.DshSettingsSetOp(draft.settingsPath, profile),
      ], expectedRevision: draft.expectedRevision ?? namespace.revision);
      final provider =
          existing ??
          dsh.DshConfigurableProvider(
            provider: draft.providerId,
            displayName: draft.displayName,
            settingsNs: draft.settingsNs,
            settingsPath: draft.settingsPath,
            declared: true,
          );
      final writtenProfile = dshProviderProfileSection(
        dsh.DshSettingsDescription(
          writable: description.writable,
          namespaces: [written],
          hasDocument: description.hasDocument,
        ),
        draft.settingsNs,
        draft.settingsPath,
      );
      final ref = dshProviderCredentialRef(provider, writtenProfile);
      final credentials = await _describeCredentials(client, {ref});
      return dshProviderSettingsEntry(
        provider: provider,
        profile: writtenProfile,
        revision: written.revision,
        configured: credentials[ref]?.configured ?? false,
      );
    } on dsh.DshException catch (error) {
      throw dshProviderSettingsExceptionFromClient(error);
    }
  }

  @override
  Future<void> delete(DshProviderEntry entry) async {
    if (!entry.declared) {
      throw const DshProviderSettingsException(
        DshProviderSettingsFailure.rejected,
        detail: 'routes shipped by the Host cannot be deleted',
      );
    }
    if (entry.settingsPath.isEmpty) {
      throw const DshProviderSettingsException(
        DshProviderSettingsFailure.rejected,
        detail: 'a whole-namespace route cannot be deleted',
      );
    }
    final client = _dsh;
    try {
      final description = await client.catalog.describeSettings();
      final namespace = description.namespace(entry.settingsNs);
      if (namespace == null) {
        throw DshProviderSettingsException(
          DshProviderSettingsFailure.unsupported,
          detail: 'the Host does not expose ${entry.settingsNs}',
        );
      }
      if (entry.revision != null && namespace.revision != entry.revision) {
        throw const DshProviderSettingsException(
          DshProviderSettingsFailure.conflict,
        );
      }
      await client.catalog.mutateSettings(entry.settingsNs, [
        dsh.DshSettingsUnsetOp(entry.settingsPath),
      ], expectedRevision: entry.revision ?? namespace.revision);
    } on dsh.DshException catch (error) {
      throw dshProviderSettingsExceptionFromClient(error);
    }
  }

  @override
  Future<void> setCredential({
    required String ref,
    required String value,
  }) async {
    final client = _dsh;
    try {
      await client.catalog.setCredential(ref, value);
    } on dsh.DshException catch (error) {
      throw dshProviderSettingsExceptionFromClient(error);
    }
  }

  @override
  Future<void> clearCredential(String ref) async {
    final client = _dsh;
    try {
      await client.catalog.unsetCredential(ref);
    } on dsh.DshException catch (error) {
      throw dshProviderSettingsExceptionFromClient(error);
    }
  }

  // -------------------------------------------------------------------------
  // Discovery

  @override
  Future<List<DshDiscoveredModel>> discover({
    required DshProviderApi api,
    required String baseURL,
    required String apiKey,
    String? providerId,
  }) async {
    final client = _dsh;
    try {
      final routeId = providerId?.trim() ?? '';
      // A known route answers from its adapter; a hand-declared draft needs
      // the endpoint. Discovery itself is advisory (the user picks models).
      final settingsNs = routeId.isEmpty
          ? 'llm-pi-ai'
          : _settingsNamespaceFor(client, routeId);
      final discovered = await client.catalog.discoverModels(
        settingsNs,
        dsh.DshModelDiscoveryRequest(
          provider: routeId.isEmpty ? null : routeId,
          baseURL: baseURL.trim().isEmpty ? null : baseURL.trim(),
          api: api.wireValue,
          apiKey: apiKey.trim().isEmpty ? null : apiKey.trim(),
        ),
        timeout: discoveryTimeout,
      );
      return [
        for (final model in discovered)
          DshDiscoveredModel(id: model.id, name: model.name),
      ];
    } on dsh.DshException catch (error) {
      throw dshProviderSettingsExceptionFromClient(error);
    }
  }

  Future<String> _settingsNamespaceFor(
    dsh.DshClient client,
    String providerId,
  ) async {
    try {
      final providers = await client.catalog.listConfigurableProviders();
      return _providerById(providers, providerId)?.settingsNs ?? 'llm-pi-ai';
    } on dsh.DshException {
      return 'llm-pi-ai';
    }
  }

  static dsh.DshConfigurableProvider? _providerById(
    List<dsh.DshConfigurableProvider> providers,
    String providerId,
  ) {
    for (final provider in providers) {
      if (provider.provider == providerId) return provider;
    }
    return null;
  }
}
