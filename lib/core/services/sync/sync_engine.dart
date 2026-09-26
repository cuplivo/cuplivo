import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'sync_client.dart';
import 'sync_data_plane.dart';
import 'sync_identity.dart';
import 'sync_merge.dart';
import 'sync_models.dart';
import 'sync_server.dart';
import 'sync_store.dart';

/// Outcome of one session, for the peer card and the sync report.
class SyncSessionReport {
  final bool success;
  final String summary;
  final SyncRefusalReason? refusal;
  final int conversationsSent;
  final int conversationsReceived;
  final int messagesUpserted;
  final int messagesDeleted;
  final int deferred;
  final int conversationsDeletedLocally;

  const SyncSessionReport({
    required this.success,
    required this.summary,
    this.refusal,
    this.conversationsSent = 0,
    this.conversationsReceived = 0,
    this.messagesUpserted = 0,
    this.messagesDeleted = 0,
    this.deferred = 0,
    this.conversationsDeletedLocally = 0,
  });
}

/// Orchestrates LAN sync sessions (ADR-0002, slice 1: conversations only).
///
/// The engine owns both roles. As the initiator it drives the six-beat session;
/// as the responder it implements [SyncServerHandler], keeping one bounded
/// session per initiator so `hello`, the incoming apply and the outgoing
/// subtree fetch share a single plan and checkpoint.
class SyncEngine implements SyncServerHandler {
  SyncEngine({
    required this.identity,
    required this.store,
    required this.dataPlane,
    required this.onStateChanged,
  });

  final SyncDeviceIdentity identity;
  final SyncStore store;
  final SyncDataPlane dataPlane;

  /// Called whenever engine-visible state changes (pairing window, session
  /// progress, peer list) so the UI can rebuild.
  final void Function() onStateChanged;

  late final SyncServer server = SyncServer(
    identity: identity,
    store: store,
    handler: this,
  );
  late final SyncClient client = SyncClient(identity: identity);

  final Random _random = Random.secure();
  final Map<String, _ResponderSession> _sessions = {};

  String? _pairingPin;
  DateTime? _pairingExpiresAt;
  SyncSessionReport? lastReport;

  static const _pairingWindow = Duration(minutes: 5);
  static const _sessionTtl = Duration(minutes: 2);

  bool get isPairingOpen =>
      _pairingPin != null &&
      _pairingExpiresAt != null &&
      DateTime.now().isBefore(_pairingExpiresAt!);

  String? get pairingPin => isPairingOpen ? _pairingPin : null;

  DateTime? get pairingExpiresAt => isPairingOpen ? _pairingExpiresAt : null;

  /// Starts listening. Returns the bound port.
  Future<int> start({int requestedPort = 0}) async {
    await store.ensureDirectories();
    return server.start(requestedPort: requestedPort);
  }

  Future<void> stop() async {
    await server.stop();
    _sessions.clear();
    _pairingPin = null;
    _pairingExpiresAt = null;
  }

  /// Opens a one-shot pairing window and returns the PIN to type on the other
  /// device.
  String openPairing() {
    final pin = List.generate(6, (_) => _random.nextInt(10)).join();
    _pairingPin = pin;
    _pairingExpiresAt = DateTime.now().add(_pairingWindow);
    onStateChanged();
    return pin;
  }

  void cancelPairing() {
    _pairingPin = null;
    _pairingExpiresAt = null;
    onStateChanged();
  }

  /// Pairs with a peer showing [pin] at `host:port`.
  Future<SyncPeerRecord> pairWith({
    required String host,
    required int port,
    required String pin,
  }) async {
    final result = await client.pair(host: host, port: port, pin: pin);
    final answer = result.answer;
    final peer = SyncPeerRecord(
      deviceId: answer.deviceId,
      certPem: result.certPem,
      name: answer.deviceName.isEmpty ? answer.deviceId : answer.deviceName,
      platform: answer.platform,
      lastHost: host,
      lastPort: port,
    );
    await store.savePeer(peer);
    onStateChanged();
    return peer;
  }

  Future<void> unpair(String deviceId) async {
    await store.deletePeer(deviceId);
    onStateChanged();
  }

  /// Runs one session against a paired peer. This is the initiator role.
  Future<SyncSessionReport> syncWithPeer(
    SyncPeerRecord peer, {
    String? host,
    int? port,
  }) async {
    final endpointHost = host ?? peer.lastHost;
    final endpointPort = port ?? peer.lastPort;
    if (endpointHost == null || endpointPort == null) {
      return _finish(
        const SyncSessionReport(success: false, summary: 'no_endpoint'),
      );
    }
    onStateChanged();
    final session = client.openSession(
      peer,
      host: endpointHost,
      port: endpointPort,
    );
    try {
      final myManifest = await dataPlane.buildManifest();
      final hello = await session.hello(
        SyncHello(
          protocolVersion: kSyncProtocolVersion,
          schemaVersion: dataPlane.schemaVersion,
          deviceId: identity.deviceId,
          deviceName: identity.name,
          platform: platformTag(),
          manifest: myManifest,
        ),
      );
      if (hello.refusal != null) {
        return _finish(
          SyncSessionReport(
            success: false,
            summary: 'refused:${hello.refusal!.reason.wire}',
            refusal: hello.refusal!.reason,
          ),
        );
      }
      final peerHello = hello.hello!;
      // Symmetric version gate, our half: refuse a peer whose schema we do not
      // know (the peer enforces its half before answering).
      if (peerHello.schemaVersion > dataPlane.schemaVersion) {
        return _finish(
          const SyncSessionReport(
            success: false,
            summary: 'refused:peer_schema_newer',
            refusal: SyncRefusalReason.peerSchemaNewer,
          ),
        );
      }

      final previous = await store.loadCheckpoint(peer.deviceId);
      final plan = planSync(
        mine: myManifest,
        peers: peerHello.manifest,
        checkpoint: previous,
      );

      final skippedSends = <String>{};
      final outgoing = <SyncSubtreePayload>[];
      for (final item in plan) {
        if (item.action != SyncConvAction.iSend &&
            item.action != SyncConvAction.bothSend) {
          continue;
        }
        if (await dataPlane.isStreaming(item.conversationId)) {
          skippedSends.add(item.conversationId);
          continue;
        }
        final subtree = await dataPlane.readSubtree(item.conversationId);
        if (subtree == null) {
          skippedSends.add(item.conversationId);
          continue;
        }
        outgoing.add(subtree);
      }
      if (outgoing.isNotEmpty) {
        await session.pushSubtrees(SyncSubtreeBatch(outgoing));
      }

      final requested = [
        for (final item in plan)
          if (item.action == SyncConvAction.peerSends ||
              item.action == SyncConvAction.bothSend)
            item.conversationId,
      ];
      final outcomes = <String, SyncSubtreeApplyOutcome>{};
      final missingIncoming = <String>{};
      if (requested.isNotEmpty) {
        final incoming = await session.fetchSubtrees(requested);
        final delivered = {
          for (final subtree in incoming.subtrees)
            subtree.conversation['id'] as String,
        };
        missingIncoming.addAll(
          requested.where((id) => !delivered.contains(id)),
        );
        outcomes.addAll(
          await dataPlane.applySubtrees(
            incoming.subtrees,
            myDeviceId: identity.deviceId,
            peerDeviceId: peer.deviceId,
            checkpointRowsByConversation: _rowsOf(previous, delivered),
          ),
        );
      }

      final deleted = <String>{};
      final failedDeletes = <String>{};
      for (final item in plan) {
        if (item.action != SyncConvAction.iDelete) continue;
        final ok = await dataPlane.deleteConversation(item.conversationId);
        (ok ? deleted : failedDeletes).add(item.conversationId);
      }
      if (deleted.isNotEmpty) await dataPlane.reload();

      final next = await _advanceCheckpoint(
        previous: previous,
        plan: plan,
        skippedSends: skippedSends,
        missingIncoming: missingIncoming,
        outcomes: outcomes,
        deletedIds: deleted,
        failedDeletes: failedDeletes,
      );
      await store.saveCheckpoint(peer.deviceId, next);
      return _finish(
        _report(
          sent: outgoing.length,
          received: outcomes.length,
          outcomes: outcomes.values,
          deferred: skippedSends.length + missingIncoming.length,
          deletedLocally: deleted.length,
        ),
        peer: peer,
        host: endpointHost,
        port: endpointPort,
      );
    } catch (error) {
      return _finish(
        SyncSessionReport(success: false, summary: 'error:$error'),
        peer: peer,
        host: endpointHost,
        port: endpointPort,
      );
    } finally {
      session.close();
      onStateChanged();
    }
  }

  // ---- responder role (SyncServerHandler) ----

  @override
  Future<Object> handleHello(
    String peerDeviceId,
    SyncHello initiatorHello,
  ) async {
    _dropExpiredSessions();
    if (initiatorHello.protocolVersion != kSyncProtocolVersion) {
      return const SyncHelloRefusal(
        SyncRefusalReason.protocolUnknown,
        'This device speaks a different sync protocol. Update it first.',
      );
    }
    if (initiatorHello.schemaVersion > dataPlane.schemaVersion) {
      return const SyncHelloRefusal(
        SyncRefusalReason.peerSchemaNewer,
        'The other device has a newer database schema. Update this device '
        'before syncing.',
      );
    }
    if (await store.findPeer(initiatorHello.deviceId) == null) {
      return const SyncHelloRefusal(
        SyncRefusalReason.notPaired,
        'This device is not paired with the caller.',
      );
    }
    final active = _sessions.isEmpty ? null : _sessions.keys.first;
    if (active != null && active != initiatorHello.deviceId) {
      return const SyncHelloRefusal(
        SyncRefusalReason.busy,
        'Another sync session is already running.',
      );
    }

    final myManifest = await dataPlane.buildManifest();
    final checkpoint = await store.loadCheckpoint(initiatorHello.deviceId);
    _sessions[initiatorHello.deviceId] = _ResponderSession(
      initiatorHello: initiatorHello,
      plan: planSync(
        mine: myManifest,
        peers: initiatorHello.manifest,
        checkpoint: checkpoint,
      ),
      checkpoint: checkpoint,
      startedAt: DateTime.now(),
    );
    return SyncHello(
      protocolVersion: kSyncProtocolVersion,
      schemaVersion: dataPlane.schemaVersion,
      deviceId: identity.deviceId,
      deviceName: identity.name,
      platform: platformTag(),
      manifest: myManifest,
    );
  }

  @override
  Future<int> handleApplySubtrees(
    String peerDeviceId,
    SyncSubtreeBatch batch,
  ) async {
    final session = _sessions[peerDeviceId];
    if (session == null) throw StateError('sync_session_missing');
    final outcomes = await dataPlane.applySubtrees(
      batch.subtrees,
      myDeviceId: identity.deviceId,
      peerDeviceId: peerDeviceId,
      checkpointRowsByConversation: _rowsOf(session.checkpoint, {
        for (final subtree in batch.subtrees)
          subtree.conversation['id'] as String,
      }),
    );
    session.outcomes.addAll(outcomes);
    return outcomes.length;
  }

  @override
  Future<SyncSubtreeBatch> handleFetchSubtrees(
    String peerDeviceId,
    List<String> conversationIds,
  ) async {
    final session = _sessions[peerDeviceId];
    if (session == null) throw StateError('sync_session_missing');
    final outgoing = <SyncSubtreePayload>[];
    final skipped = <String>{};
    for (final id in conversationIds) {
      if (await dataPlane.isStreaming(id)) {
        skipped.add(id);
        continue;
      }
      final subtree = await dataPlane.readSubtree(id);
      if (subtree == null) {
        skipped.add(id);
        continue;
      }
      outgoing.add(subtree);
    }
    final delivered = {
      for (final subtree in outgoing) subtree.conversation['id'] as String,
    };
    final missing = conversationIds.toSet().difference(delivered);

    final deleted = <String>{};
    final failedDeletes = <String>{};
    for (final item in session.plan) {
      if (item.action != SyncConvAction.iDelete) continue;
      final ok = await dataPlane.deleteConversation(item.conversationId);
      (ok ? deleted : failedDeletes).add(item.conversationId);
    }
    if (deleted.isNotEmpty) await dataPlane.reload();

    final next = await _advanceCheckpoint(
      previous: session.checkpoint,
      plan: session.plan,
      skippedSends: skipped,
      missingIncoming: missing,
      outcomes: session.outcomes,
      deletedIds: deleted,
      failedDeletes: failedDeletes,
    );
    await store.saveCheckpoint(peerDeviceId, next);
    final peer = await store.findPeer(peerDeviceId);
    if (peer != null) {
      peer.lastSyncedAt = DateTime.now();
      peer.lastResult = _report(
        sent: outgoing.length,
        received: session.outcomes.length,
        outcomes: session.outcomes.values,
        deferred: skipped.length + missing.length,
        deletedLocally: deleted.length,
      ).summary;
      await store.savePeer(peer);
    }
    _sessions.remove(peerDeviceId);
    onStateChanged();
    return SyncSubtreeBatch(outgoing);
  }

  @override
  Future<SyncPairAnswer?> handlePair(SyncPairRequest request) async {
    if (!isPairingOpen) return null;
    if (request.pin != _pairingPin) return null;
    // One-shot: a PIN is spent on first success.
    _pairingPin = null;
    _pairingExpiresAt = null;
    await store.savePeer(
      SyncPeerRecord(
        deviceId: request.deviceId,
        certPem: request.certPem,
        name: request.deviceName.isEmpty
            ? request.deviceId
            : request.deviceName,
        platform: request.platform,
      ),
    );
    onStateChanged();
    return SyncPairAnswer(
      deviceId: identity.deviceId,
      deviceName: identity.name,
      platform: platformTag(),
      certPem: identity.certPem,
    );
  }

  // ---- internals ----

  /// Advances the per-peer checkpoint. A conversation only gets a *new* entry
  /// once this device knows the peer reached the same state: skipped sends,
  /// undelivered fetches and deferred applies all keep the previous entry so
  /// the next session retries them.
  Future<SyncCheckpoint> _advanceCheckpoint({
    required SyncCheckpoint previous,
    required List<SyncConvPlan> plan,
    required Set<String> skippedSends,
    required Set<String> missingIncoming,
    required Map<String, SyncSubtreeApplyOutcome> outcomes,
    required Set<String> deletedIds,
    required Set<String> failedDeletes,
  }) async {
    final next = <String, SyncCheckpointConversation>{};
    for (final item in plan) {
      final id = item.conversationId;
      final prior = previous.conversations[id];
      switch (item.action) {
        case SyncConvAction.none:
          final entry = prior ?? await dataPlane.checkpointFromLocal(id);
          if (entry != null) next[id] = entry;
        case SyncConvAction.iSend:
          if (skippedSends.contains(id)) {
            if (prior != null) next[id] = prior;
          } else {
            final entry = await dataPlane.checkpointFromLocal(id);
            if (entry != null) next[id] = entry;
          }
        case SyncConvAction.peerSends:
        case SyncConvAction.bothSend:
          final outcome = outcomes[id];
          if (outcome == null || outcome.deferred) {
            if (prior != null) next[id] = prior;
            break;
          }
          final conversationRow = outcome.conversationRow;
          if (conversationRow == null) {
            if (prior != null) next[id] = prior;
            break;
          }
          next[id] = buildCheckpointConversation(
            conversationRow: conversationRow,
            messageRows: outcome.messageRows,
          );
        case SyncConvAction.iDelete:
          if (failedDeletes.contains(id) && prior != null) next[id] = prior;
        case SyncConvAction.peerDeletes:
        case SyncConvAction.bothDeleted:
          break; // entry drops: neither side has the conversation any more
      }
    }
    return SyncCheckpoint(next);
  }

  Map<String, Map<String, int>> _rowsOf(
    SyncCheckpoint checkpoint,
    Set<String> conversationIds,
  ) => {
    for (final id in conversationIds)
      if (checkpoint.conversations[id] != null)
        id: checkpoint.conversations[id]!.rows,
  };

  SyncSessionReport _report({
    required int sent,
    required int received,
    required Iterable<SyncSubtreeApplyOutcome> outcomes,
    required int deferred,
    required int deletedLocally,
  }) {
    var upserted = 0;
    var deleted = 0;
    for (final outcome in outcomes) {
      upserted += outcome.upsertedMessages;
      deleted += outcome.deletedMessages;
    }
    final parts = <String>[
      'sent $sent',
      'received $received',
      if (upserted > 0) '+$upserted msgs',
      if (deleted > 0) '-$deleted msgs',
      if (deletedLocally > 0) '-$deletedLocally convs',
      if (deferred > 0) 'deferred $deferred',
    ];
    return SyncSessionReport(
      success: true,
      summary: parts.join(' · '),
      conversationsSent: sent,
      conversationsReceived: received,
      messagesUpserted: upserted,
      messagesDeleted: deleted,
      deferred: deferred,
      conversationsDeletedLocally: deletedLocally,
    );
  }

  SyncSessionReport _finish(
    SyncSessionReport report, {
    SyncPeerRecord? peer,
    String? host,
    int? port,
  }) {
    lastReport = report;
    if (peer != null) {
      peer.lastSyncedAt = DateTime.now();
      peer.lastResult = report.summary;
      if (host != null) peer.lastHost = host;
      if (port != null) peer.lastPort = port;
      unawaited(store.savePeer(peer));
    }
    onStateChanged();
    return report;
  }

  void _dropExpiredSessions() {
    final now = DateTime.now();
    _sessions.removeWhere(
      (_, session) => now.difference(session.startedAt) > _sessionTtl,
    );
  }

  static String platformTag() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }
}

class _ResponderSession {
  _ResponderSession({
    required this.initiatorHello,
    required this.plan,
    required this.checkpoint,
    required this.startedAt,
  });

  final SyncHello initiatorHello;
  final List<SyncConvPlan> plan;
  final SyncCheckpoint checkpoint;
  final DateTime startedAt;
  final Map<String, SyncSubtreeApplyOutcome> outcomes = {};
}
