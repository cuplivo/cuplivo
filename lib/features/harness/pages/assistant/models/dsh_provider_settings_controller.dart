import 'package:flutter/foundation.dart';

import 'dsh_provider_settings.dart';

/// The load/save state machine behind the DSH provider list and detail page.
///
/// One controller lives for as long as the 模型 tab's route does. It owns the
/// seam's snapshot so both surfaces read the same list, and it centralizes the
/// revision-conflict rule: a `settings/conflict` never surfaces as an
/// exception to a widget, it marks [lastFailure] and reloads the host's
/// newest state so the user's next save carries the fresh revision.
///
/// No DSH value is cached beyond this object's lifetime; nothing is written to
/// `SettingsProvider` or Cuplivo's provider rows.
class DshProviderSettingsController extends ChangeNotifier {
  DshProviderSettingsController({required this.gateway});

  final DshProviderSettingsGateway gateway;

  List<DshProviderEntry>? _entries;
  bool _loading = false;
  bool _saving = false;
  bool _disposed = false;
  DshProviderSettingsFailure? _lastFailure;

  /// The host's routes, or null before the first successful load.
  List<DshProviderEntry>? get entries =>
      _entries == null ? null : List<DshProviderEntry>.unmodifiable(_entries!);

  bool get isLoading => _loading;
  bool get isSaving => _saving;
  bool get hasLoaded => _entries != null;

  /// The last failed operation, cleared by the next success.
  DshProviderSettingsFailure? get lastFailure => _lastFailure;

  /// Reads the host once. Repeat calls are no-ops unless [force] is true.
  Future<void> ensureLoaded({bool force = false}) async {
    if (_loading) return;
    if (hasLoaded && !force) return;
    await load();
  }

  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    _lastFailure = null;
    _notify();
    try {
      final entries = await gateway.load();
      if (_disposed) return;
      _entries = _sorted(entries);
    } on DshProviderSettingsException catch (error) {
      if (_disposed) return;
      _lastFailure = error.failure;
    } catch (_) {
      if (_disposed) return;
      _lastFailure = DshProviderSettingsFailure.unknown;
    } finally {
      _loading = false;
      _notify();
    }
  }

  /// Writes one profile. Returns the saved entry, or null after a failure
  /// (which [lastFailure] describes).
  Future<DshProviderEntry?> save(DshProviderDraft draft) async {
    if (_saving) return null;
    _saving = true;
    _lastFailure = null;
    _notify();
    try {
      final saved = await gateway.save(draft);
      if (_disposed) return null;
      _entries = _sorted(_replaceOrAppend(_entries ?? const [], saved));
      return saved;
    } on DshProviderSettingsException catch (error) {
      if (_disposed) return null;
      _lastFailure = error.failure;
      if (error.failure == DshProviderSettingsFailure.conflict) {
        // The user's edit is worth keeping; the newest revision is what the
        // next attempt must carry, so reload before returning. The reload
        // clears the failure at its own start, so restore the conflict after
        // it so the page can tell the user why nothing was written.
        await load();
        if (!_disposed) _lastFailure = DshProviderSettingsFailure.conflict;
      }
      return null;
    } catch (_) {
      if (_disposed) return null;
      _lastFailure = DshProviderSettingsFailure.unknown;
      return null;
    } finally {
      _saving = false;
      _notify();
    }
  }

  /// Saves a credential and marks its provider configured.
  Future<bool> setCredential(String ref, String value) async {
    if (_saving) return false;
    _saving = true;
    _lastFailure = null;
    _notify();
    try {
      await gateway.setCredential(ref: ref, value: value);
      if (_disposed) return false;
      _entries = _sorted(_markConfigured(_entries ?? const [], ref));
      return true;
    } on DshProviderSettingsException catch (error) {
      if (_disposed) return false;
      _lastFailure = error.failure;
      return false;
    } catch (_) {
      if (_disposed) return false;
      _lastFailure = DshProviderSettingsFailure.unknown;
      return false;
    } finally {
      _saving = false;
      _notify();
    }
  }

  /// Removes one stored credential.
  Future<bool> clearCredential(String ref) async {
    if (_saving) return false;
    _saving = true;
    _lastFailure = null;
    _notify();
    try {
      await gateway.clearCredential(ref);
      if (_disposed) return false;
      _entries = _sorted(_markConfigured(_entries ?? const [], ref, false));
      return true;
    } on DshProviderSettingsException catch (error) {
      if (_disposed) return false;
      _lastFailure = error.failure;
      return false;
    } catch (_) {
      if (_disposed) return false;
      _lastFailure = DshProviderSettingsFailure.unknown;
      return false;
    } finally {
      _saving = false;
      _notify();
    }
  }

  /// Deletes a declared provider profile.
  Future<bool> delete(DshProviderEntry entry) async {
    if (_saving) return false;
    _saving = true;
    _lastFailure = null;
    _notify();
    try {
      await gateway.delete(entry);
      if (_disposed) return false;
      _entries = [
        for (final current in _entries ?? const <DshProviderEntry>[])
          if (current.id != entry.id) current,
      ];
      return true;
    } on DshProviderSettingsException catch (error) {
      if (_disposed) return false;
      _lastFailure = error.failure;
      return false;
    } catch (_) {
      if (_disposed) return false;
      _lastFailure = DshProviderSettingsFailure.unknown;
      return false;
    } finally {
      _saving = false;
      _notify();
    }
  }

  /// Asks the endpoint for its model list; null on failure.
  Future<List<DshDiscoveredModel>?> discover({
    required DshProviderApi api,
    required String baseURL,
    required String apiKey,
    String? providerId,
  }) async {
    _lastFailure = null;
    try {
      return await gateway.discover(
        api: api,
        baseURL: baseURL,
        apiKey: apiKey,
        providerId: providerId,
      );
    } on DshProviderSettingsException catch (error) {
      if (!_disposed) {
        _lastFailure = error.failure;
        _notify();
      }
      return null;
    } catch (_) {
      if (!_disposed) {
        _lastFailure = DshProviderSettingsFailure.unknown;
        _notify();
      }
      return null;
    }
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  static List<DshProviderEntry> _sorted(Iterable<DshProviderEntry> entries) {
    final list = List<DshProviderEntry>.of(entries);
    list.sort((a, b) {
      final byName = a.effectiveDisplayName.toLowerCase().compareTo(
        b.effectiveDisplayName.toLowerCase(),
      );
      return byName != 0 ? byName : a.id.compareTo(b.id);
    });
    return list;
  }

  static List<DshProviderEntry> _replaceOrAppend(
    List<DshProviderEntry> current,
    DshProviderEntry saved,
  ) {
    final next = <DshProviderEntry>[];
    var replaced = false;
    for (final entry in current) {
      if (entry.id == saved.id) {
        next.add(saved);
        replaced = true;
      } else {
        next.add(entry);
      }
    }
    if (!replaced) next.add(saved);
    return next;
  }

  static List<DshProviderEntry> _markConfigured(
    List<DshProviderEntry> current,
    String ref, [
    bool configured = true,
  ]) => [
    for (final entry in current)
      if (entry.credentialRef == ref || entry.id == ref)
        entry.copyWith(configured: configured)
      else
        entry,
  ];
}
