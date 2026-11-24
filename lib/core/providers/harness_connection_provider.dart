import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/assistant.dart';
import '../services/harness/harness_connection_probe.dart';
import 'assistant_provider.dart';

/// What the app currently knows about one DeepSeek Harness assistant's link.
enum HarnessConnectionPhase { unknown, checking, connected, failed }

/// Tracks the live connection state of every [AssistantKind.deepSeekHarness]
/// assistant, one probe per assistant at a time.
///
/// The state is deliberately not persisted: a DSH launch token is only good
/// until that instance restarts, so "connected" is something to re-prove, not a
/// fact to remember. The assistants list re-proves it lazily (when a harness
/// row is shown) and the settings page re-proves it every time it opens.
class HarnessConnectionProvider extends ChangeNotifier {
  HarnessConnectionProvider({
    required AssistantProvider assistants,
    HarnessConnectionProbe? probe,
  }) : // Public injection name intentionally omits the private-field prefix
       // (same convention as SyncProvider's dependencies).
       // ignore: prefer_initializing_formals
       _assistants = assistants,
       _probe = probe ?? const HarnessConnectionProbe() {
    _assistants.addListener(_prune);
  }

  final AssistantProvider _assistants;
  final HarnessConnectionProbe _probe;
  final Map<String, HarnessConnectionResult> _results =
      <String, HarnessConnectionResult>{};
  final Set<String> _checking = <String>{};
  final Map<String, int> _generations = <String, int>{};
  bool _disposed = false;

  HarnessConnectionPhase phaseOf(String assistantId) {
    if (_checking.contains(assistantId)) {
      return HarnessConnectionPhase.checking;
    }
    final result = _results[assistantId];
    if (result == null) return HarnessConnectionPhase.unknown;
    return result.isConnected
        ? HarnessConnectionPhase.connected
        : HarnessConnectionPhase.failed;
  }

  HarnessConnectionFailure? failureOf(String assistantId) =>
      _results[assistantId]?.failure;

  bool isConnected(String assistantId) =>
      phaseOf(assistantId) == HarnessConnectionPhase.connected;

  /// Proves [assistant]'s saved link again, replacing whatever was known.
  ///
  /// Always runs a fresh exchange: the token's validity is the thing being
  /// checked, and a cached answer would hide a restarted DSH. Concurrent calls
  /// for the same assistant are serialized by generation, so the last one wins
  /// and a slow earlier answer cannot overwrite a newer one.
  Future<HarnessConnectionResult> check(Assistant assistant) async {
    final id = assistant.id;
    final generation = (_generations[id] ?? 0) + 1;
    _generations[id] = generation;
    _checking.add(id);
    _notify();
    HarnessConnectionResult result;
    try {
      result = await _probe.check(assistant.harnessUrl ?? '');
    } catch (_) {
      // The probe turns every expected network failure into a result; anything
      // that leaks out is still a dead link, and must not leave the row
      // spinning in [HarnessConnectionPhase.checking] forever.
      result = const HarnessConnectionResult.failed(
        HarnessConnectionFailure.unreachable,
      );
    }
    if (_disposed || _generations[id] != generation) return result;
    _checking.remove(id);
    _results[id] = result;
    _notify();
    return result;
  }

  /// Starts a check for every harness assistant that has a link but no answer
  /// yet. Called from list surfaces, so opening the page once is enough.
  void ensureChecked(Iterable<Assistant> assistants) {
    for (final assistant in assistants) {
      if (!assistant.isDeepSeekHarness) continue;
      final url = assistant.harnessUrl?.trim() ?? '';
      if (url.isEmpty) continue;
      if (phaseOf(assistant.id) != HarnessConnectionPhase.unknown) continue;
      unawaited(check(assistant));
    }
  }

  /// Forget one assistant's answer — e.g. its link is about to change.
  void reset(String assistantId) {
    final changed = _results.remove(assistantId) != null;
    _generations[assistantId] = (_generations[assistantId] ?? 0) + 1;
    _checking.remove(assistantId);
    if (changed) _notify();
  }

  void forget(String assistantId) {
    _results.remove(assistantId);
    _checking.remove(assistantId);
    _generations.remove(assistantId);
  }

  void _prune() {
    final live = <String>{
      for (final assistant in _assistants.assistants)
        if (assistant.isDeepSeekHarness) assistant.id,
    };
    // A deleted assistant may leave an answer, an in-flight probe, or both.
    final stale = <String>{
      ..._results.keys,
      ..._checking,
      ..._generations.keys,
    }.where((id) => !live.contains(id)).toList();
    if (stale.isEmpty) return;
    final hadAnswer = stale.any(_results.containsKey);
    for (final id in stale) {
      forget(id);
    }
    if (hadAnswer) _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _assistants.removeListener(_prune);
    super.dispose();
  }
}
