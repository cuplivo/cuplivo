import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/assistant.dart';
import '../services/harness/harness_connection_probe.dart';
import '../services/harness/harness_tailcat_probe.dart';
import '../services/harness/harness_tailcat_tunnels.dart';
import 'assistant_provider.dart';

/// What the app currently knows about one DeepSeek Harness assistant's link.
enum HarnessConnectionPhase { unknown, checking, connected, failed }

/// Tracks the live connection state of every [AssistantKind.deepSeekHarness]
/// assistant, one probe per assistant at a time.
///
/// A harness may reach its instance through the public launch link or through
/// the ds-hu remote-access plugin's tailcat address; the connection mode picks
/// which probe answers. Both answer the same question ("can the embedded WebUI
/// load right now?"), so every surface above this provider stays transport
/// agnostic.
///
/// The state is deliberately not persisted: a DSH launch token is only good
/// until that instance restarts, so "connected" is something to re-prove, not a
/// fact to remember. The assistants list re-proves it lazily (when a harness
/// row is shown) and the settings page re-proves it every time it opens.
class HarnessConnectionProvider extends ChangeNotifier {
  HarnessConnectionProvider({
    required AssistantProvider assistants,
    HarnessConnectionProbe? probe,
    HarnessTailcatProbe? tailcatProbe,
    HarnessTailcatTunnels? tailcatTunnels,
  }) : // Public injection name intentionally omits the private-field prefix
       // (same convention as SyncProvider's dependencies).
       // ignore: prefer_initializing_formals
       _assistants = assistants,
       _probe = probe ?? const HarnessConnectionProbe(),
       // ignore: prefer_initializing_formals
       _tailcatProbe = tailcatProbe,
       // ignore: prefer_initializing_formals
       _tailcatTunnels = tailcatTunnels {
    _assistants.addListener(_prune);
  }

  final AssistantProvider _assistants;
  final HarnessConnectionProbe _probe;

  /// The tailcat half of the probe, absent on builds without a tailcat client
  /// (the web target) and in tests that only exercise the link mode.
  final HarnessTailcatProbe? _tailcatProbe;

  /// The tunnels [check] starts, so an assistant that is gone can stop them.
  final HarnessTailcatTunnels? _tailcatTunnels;
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
      result = await _probeFor(assistant).check(switch (assistant
          .harnessConnectionMode) {
        HarnessConnectionMode.publicLink => assistant.harnessUrl ?? '',
        HarnessConnectionMode.tailcat => assistant.harnessTailcatAddress ?? '',
      }, remotePort: assistant.harnessTailcatPort);
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

  /// The probe [assistant]'s connection mode uses. A tailcat-mode assistant
  /// on a build without the tailcat client gets a probe that always reports
  /// [HarnessConnectionFailure.tailcatUnsupported].
  _HarnessProbe _probeFor(Assistant assistant) =>
      switch (assistant.harnessConnectionMode) {
        HarnessConnectionMode.publicLink => _LinkProbe(_probe),
        HarnessConnectionMode.tailcat =>
          _tailcatProbe == null
              ? const _UnsupportedTailcatProbe()
              : _TailcatProbe(_tailcatProbe),
      };

  /// Starts a check for every harness assistant that has a link but no answer
  /// yet. Called from list surfaces, so opening the page once is enough.
  void ensureChecked(Iterable<Assistant> assistants) {
    for (final assistant in assistants) {
      if (!assistant.isDeepSeekHarness) continue;
      if (!assistant.hasHarnessConnection) continue;
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
    final liveTailcatAddresses = <String>{
      for (final assistant in _assistants.assistants)
        if (assistant.isDeepSeekHarness &&
            assistant.harnessConnectionMode == HarnessConnectionMode.tailcat &&
            assistant.hasHarnessConnection)
          assistant.harnessTailcatAddress!.trim(),
    };
    unawaited(
      _tailcatTunnels?.prune(liveTailcatAddresses) ?? Future<void>.value(),
    );
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

/// One transport's way of answering "can the WebUI load?", so [check] does not
/// carry a branch per mode. [remotePort] is ignored by the link transport.
abstract interface class _HarnessProbe {
  Future<HarnessConnectionResult> check(
    String credential, {
    required int remotePort,
  });
}

class _LinkProbe implements _HarnessProbe {
  const _LinkProbe(this._probe);

  final HarnessConnectionProbe _probe;

  @override
  Future<HarnessConnectionResult> check(
    String credential, {
    required int remotePort,
  }) => _probe.check(credential);
}

class _TailcatProbe implements _HarnessProbe {
  const _TailcatProbe(this._probe);

  final HarnessTailcatProbe _probe;

  @override
  Future<HarnessConnectionResult> check(
    String credential, {
    required int remotePort,
  }) => _probe.check(credential, remotePort: remotePort);
}

class _UnsupportedTailcatProbe implements _HarnessProbe {
  const _UnsupportedTailcatProbe();

  @override
  Future<HarnessConnectionResult> check(
    String credential, {
    required int remotePort,
  }) async => const HarnessConnectionResult.failed(
    HarnessConnectionFailure.tailcatUnsupported,
  );
}
