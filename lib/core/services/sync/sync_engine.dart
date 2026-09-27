import 'dart:async';
import 'dart:convert';
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

  /// Business rows exchanged in either direction (entities + preferences).
  /// One number per face: the card says how much business state moved, and the
  /// per-row detail lives in the logs.
  final int entityRows;
  final int preferenceRows;

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
    this.entityRows = 0,
    this.preferenceRows = 0,
  });

  /// The persistable, localizable form stored on the peer record.
  SyncPeerReport toPeerReport() => SyncPeerReport(
    success: success,
    sent: conversationsSent,
    received: conversationsReceived,
    upsertedMessages: messagesUpserted,
    deletedMessages: messagesDeleted,
    deletedConversations: conversationsDeletedLocally,
    deferred: deferred,
    entityRows: entityRows,
    preferenceRows: preferenceRows,
    refusal: refusal,
    error: success || refusal != null ? null : summary,
  );
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

  /// The port a sync listener prefers, so a firewall rule and a peer's stored
  /// endpoint stay stable across launches. A busy port falls back to an
  /// ephemeral one (two app instances on one machine).
  static const kPreferredPort = 9527;

  /// The port this device's sync listener is bound to, or null when stopped.
  int? get port => server.port;

  bool get isPairingOpen =>
      _pairingPin != null &&
      _pairingExpiresAt != null &&
      DateTime.now().isBefore(_pairingExpiresAt!);

  String? get pairingPin => isPairingOpen ? _pairingPin : null;

  DateTime? get pairingExpiresAt => isPairingOpen ? _pairingExpiresAt : null;

  /// Starts listening on [preferredPort], falling back to an ephemeral port
  /// when it is taken. Returns the bound port.
  Future<int> start({int preferredPort = kPreferredPort}) async {
    await store.ensureDirectories();
    try {
      return await server.start(requestedPort: preferredPort);
    } on SocketException {
      return server.start(requestedPort: 0);
    }
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
    final result = await client.pair(
      host: host,
      port: port,
      pin: pin,
      listenPort: this.port,
    );
    final answer = result.answer;
    final peer = SyncPeerRecord(
      deviceId: answer.deviceId,
      certPem: result.certPem,
      secret: answer.secret,
      name: answer.deviceName.isEmpty ? answer.deviceId : answer.deviceName,
      platform: answer.platform,
      lastHost: host,
      lastPort: port,
    );
    await store.savePeer(peer);
    // This listener must accept the peer too: pairing may have been initiated
    // from this side, in which case the answer (not a request) carried the
    // secret.
    server.rememberPeer(peer);
    onStateChanged();
    return peer;
  }

  Future<void> unpair(String deviceId) async {
    await store.deletePeer(deviceId);
    server.forgetPeer(deviceId);
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
      return await _finish(
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
        return await _finish(
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
        return await _finish(
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
      final businessPlan = planBusinessSync(
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

      // Business rows this device owes the peer.
      final outgoingEntityIds = <String, Set<String>>{};
      final outgoingPreferenceKeys = <String>{};
      for (final item in businessPlan) {
        if (item.action != SyncConvAction.iSend &&
            item.action != SyncConvAction.bothSend) {
          continue;
        }
        if (item.kindWire == kSyncPreferenceWire) {
          outgoingPreferenceKeys.add(item.id);
        } else {
          (outgoingEntityIds[item.kindWire] ??= <String>{}).add(item.id);
        }
      }
      final outgoingRead = await dataPlane.readBusinessRows(
        entityIds: outgoingEntityIds,
        preferenceKeys: outgoingPreferenceKeys,
      );
      final outgoingBusiness = outgoingRead.payload;
      // A row the manifest promised but the read did not deliver (deleted in
      // between) is not sent, and must not advance the checkpoint.
      final sentBusiness = outgoingRead.keys;

      if (outgoing.isNotEmpty || !outgoingBusiness.isEmpty) {
        await session.pushDelta(
          SyncDeltaBatch(outgoing, business: outgoingBusiness),
        );
      }

      final requested = [
        for (final item in plan)
          if (item.action == SyncConvAction.peerSends ||
              item.action == SyncConvAction.bothSend)
            item.conversationId,
      ];
      final requestedEntityIds = <String, Set<String>>{};
      final requestedPreferenceKeys = <String>{};
      for (final item in businessPlan) {
        if (item.action != SyncConvAction.peerSends &&
            item.action != SyncConvAction.bothSend) {
          continue;
        }
        if (item.kindWire == kSyncPreferenceWire) {
          requestedPreferenceKeys.add(item.id);
        } else {
          (requestedEntityIds[item.kindWire] ??= <String>{}).add(item.id);
        }
      }

      final outcomes = <String, SyncSubtreeApplyOutcome>{};
      final missingIncoming = <String>{};
      // The fetch beat always runs, even with an empty request: it is where the
      // responder executes its own plan — the deletions it must apply, its
      // checkpoint advance and its report. Skipping it when this device wants
      // nothing would leave a conversation this device deleted alive on an
      // unmodified peer, which the dropped checkpoint entry then re-adopts.
      final incoming = await session.fetchSubtrees(
        SyncFetchRequest(
          conversationIds: requested,
          entityIds: {
            for (final entry in requestedEntityIds.entries)
              entry.key: entry.value.toList(growable: false),
          },
          preferenceKeys: requestedPreferenceKeys.toList(growable: false),
        ),
      );
      final delivered = {
        for (final subtree in incoming.subtrees)
          subtree.conversation['id'] as String,
      };
      missingIncoming.addAll(requested.where((id) => !delivered.contains(id)));
      outcomes.addAll(
        await dataPlane.applySubtrees(
          incoming.subtrees,
          myDeviceId: identity.deviceId,
          peerDeviceId: peer.deviceId,
          checkpointRowsByConversation: _rowsOf(previous, delivered),
        ),
      );

      final receivedBusiness = dataPlane.businessKeysOf(incoming.business);
      final businessOutcome = await dataPlane.applyBusiness(
        incoming.business,
        myDeviceId: identity.deviceId,
        peerDeviceId: peer.deviceId,
      );

      final deleted = <String>{};
      final failedDeletes = <String>{};
      for (final item in plan) {
        if (item.action != SyncConvAction.iDelete) continue;
        final ok = await dataPlane.deleteConversation(item.conversationId);
        (ok ? deleted : failedDeletes).add(item.conversationId);
      }
      if (deleted.isNotEmpty) await dataPlane.reload();

      final deletedBusiness = <String>{};
      final failedBusinessDeletes = <String>{};
      for (final item in businessPlan) {
        if (item.action != SyncConvAction.iDelete) continue;
        final key = syncBusinessKey(item.kindWire, item.id);
        final ok = await dataPlane.deleteBusinessRow(item.kindWire, item.id);
        (ok ? deletedBusiness : failedBusinessDeletes).add(key);
      }
      // A deletion writes through the repository, not through
      // BusinessPreferences, so the in-memory view the providers read has to be
      // refreshed here — the apply path only refreshes when it wrote something.
      if (deletedBusiness.isNotEmpty) await dataPlane.reloadBusiness();

      final next = await _advanceCheckpoint(
        previous: previous,
        plan: plan,
        skippedSends: skippedSends,
        missingIncoming: missingIncoming,
        outcomes: outcomes,
        deletedIds: deleted,
        failedDeletes: failedDeletes,
      );
      final nextBusiness = await _advanceBusinessCheckpoint(
        previous: previous,
        plan: businessPlan,
        sentKeys: sentBusiness,
        receivedKeys: receivedBusiness,
        deletedKeys: deletedBusiness,
        failedDeleteKeys: failedBusinessDeletes,
        applyDeferred: businessOutcome.deferred,
      );
      await store.saveCheckpoint(
        peer.deviceId,
        SyncCheckpoint(
          next.conversations,
          entities: nextBusiness.entities,
          preferences: nextBusiness.preferences,
        ),
      );
      return await _finish(
        _report(
          sent: outgoing.length,
          received: outcomes.length,
          outcomes: outcomes.values,
          deferred: skippedSends.length + missingIncoming.length,
          deletedLocally: deleted.length,
          business: outgoingBusiness,
          receivedBusiness: incoming.business,
          appliedBusiness: businessOutcome,
        ),
        peer: peer,
        host: endpointHost,
        port: endpointPort,
      );
    } catch (error) {
      return await _finish(
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
      businessPlan: planBusinessSync(
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
    SyncDeltaBatch batch,
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
    // Business rows arrive in the same push; the responder's own plan already
    // decided what it needs from the initiator, so this is purely an apply.
    // One push per session, so the payload is kept as-is for the checkpoint
    // and the report.
    session.receivedBusiness = batch.business;
    session.businessOutcome = await dataPlane.applyBusiness(
      batch.business,
      myDeviceId: identity.deviceId,
      peerDeviceId: peerDeviceId,
    );
    return outcomes.length;
  }

  @override
  Future<SyncDeltaBatch> handleFetchSubtrees(
    String peerDeviceId,
    SyncFetchRequest request,
  ) async {
    final session = _sessions[peerDeviceId];
    if (session == null) throw StateError('sync_session_missing');
    final outgoing = <SyncSubtreePayload>[];
    final skipped = <String>{};
    for (final id in request.conversationIds) {
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
    final missing = request.conversationIds.toSet().difference(delivered);

    final businessRead = await dataPlane.readBusinessRows(
      entityIds: {
        for (final entry in request.entityIds.entries)
          entry.key: entry.value.toSet(),
      },
      preferenceKeys: request.preferenceKeys.toSet(),
    );

    final deleted = <String>{};
    final failedDeletes = <String>{};
    for (final item in session.plan) {
      if (item.action != SyncConvAction.iDelete) continue;
      final ok = await dataPlane.deleteConversation(item.conversationId);
      (ok ? deleted : failedDeletes).add(item.conversationId);
    }
    if (deleted.isNotEmpty) await dataPlane.reload();

    final deletedBusiness = <String>{};
    final failedBusinessDeletes = <String>{};
    for (final item in session.businessPlan) {
      if (item.action != SyncConvAction.iDelete) continue;
      final key = syncBusinessKey(item.kindWire, item.id);
      final ok = await dataPlane.deleteBusinessRow(item.kindWire, item.id);
      (ok ? deletedBusiness : failedBusinessDeletes).add(key);
    }
    // Deletions bypass BusinessPreferences, so refresh the in-memory view the
    // providers read; the apply above only refreshes when it wrote a row.
    if (deletedBusiness.isNotEmpty) await dataPlane.reloadBusiness();

    final next = await _advanceCheckpoint(
      previous: session.checkpoint,
      plan: session.plan,
      skippedSends: skipped,
      missingIncoming: missing,
      outcomes: session.outcomes,
      deletedIds: deleted,
      failedDeletes: failedDeletes,
    );
    final nextBusiness = await _advanceBusinessCheckpoint(
      previous: session.checkpoint,
      plan: session.businessPlan,
      // What this device actually packed into the response; a row the plan
      // promised but the read did not deliver stays at its previous entry.
      sentKeys: businessRead.keys,
      receivedKeys: dataPlane.businessKeysOf(session.receivedBusiness),
      deletedKeys: deletedBusiness,
      failedDeleteKeys: failedBusinessDeletes,
      applyDeferred: session.businessOutcome?.deferred ?? false,
    );
    await store.saveCheckpoint(
      peerDeviceId,
      SyncCheckpoint(
        next.conversations,
        entities: nextBusiness.entities,
        preferences: nextBusiness.preferences,
      ),
    );
    final peer = await store.findPeer(peerDeviceId);
    if (peer != null) {
      peer.lastSyncedAt = DateTime.now();
      peer.lastReport = _report(
        sent: outgoing.length,
        received: session.outcomes.length,
        outcomes: session.outcomes.values,
        deferred: skipped.length + missing.length,
        deletedLocally: deleted.length,
        business: businessRead.payload,
        receivedBusiness: session.receivedBusiness,
        appliedBusiness: session.businessOutcome,
      ).toPeerReport();
      await store.savePeer(peer);
    }
    _sessions.remove(peerDeviceId);
    onStateChanged();
    return SyncDeltaBatch(outgoing, business: businessRead.payload);
  }

  @override
  Future<SyncPairAnswer?> handlePair(
    SyncPairRequest request,
    String? initiatorHost,
  ) async {
    if (!isPairingOpen) return null;
    if (request.pin != _pairingPin) return null;
    // One-shot: a PIN is spent on first success.
    _pairingPin = null;
    _pairingExpiresAt = null;
    // The per-peer secret binds later sessions to this pairing: the listener
    // has no TLS client certificate to authenticate the caller with, so this
    // is what a paired peer must present (see [SyncServer]).
    final secret = _newSecret();
    final peer = SyncPeerRecord(
      deviceId: request.deviceId,
      certPem: request.certPem,
      secret: secret,
      name: request.deviceName.isEmpty ? request.deviceId : request.deviceName,
      platform: request.platform,
      // Endpoint learned from the pairing itself: where the initiator
      // connected from + the listener port it advertised. Null when the
      // initiator had no listener running; the address can be fixed by hand.
      lastHost: initiatorHost,
      lastPort: request.listenPort,
    );
    await store.savePeer(peer);
    // The pairing request arrived on this listener, so the peer is known here
    // already; the initiator learns the same secret from the answer.
    server.rememberPeer(peer);
    onStateChanged();
    return SyncPairAnswer(
      deviceId: identity.deviceId,
      deviceName: identity.name,
      platform: platformTag(),
      certPem: identity.certPem,
      secret: secret,
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

  /// Advances the business half of the checkpoint. The rule mirrors
  /// conversations: an entry moves to the current shared state (read back from
  /// local, which *is* the shared state once the exchange succeeded) only when
  /// both sides demonstrably reached it; anything skipped, undelivered or
  /// deferred keeps its previous entry so the next session retries it. A row
  /// gone on both sides drops its entry.
  Future<SyncCheckpoint> _advanceBusinessCheckpoint({
    required SyncCheckpoint previous,
    required List<SyncBusinessPlanItem> plan,
    required Set<String> sentKeys,
    required Set<String> receivedKeys,
    required Set<String> deletedKeys,
    required Set<String> failedDeleteKeys,
    required bool applyDeferred,
  }) async {
    final entities = <String, Map<String, SyncCheckpointEntry>>{
      for (final entry in previous.entities.entries)
        entry.key: Map<String, SyncCheckpointEntry>.of(entry.value),
    };
    final preferences = <String, SyncCheckpointEntry>{...previous.preferences};

    for (final item in plan) {
      final key = syncBusinessKey(item.kindWire, item.id);
      final prior = item.kindWire == kSyncPreferenceWire
          ? preferences[item.id]
          : entities[item.kindWire]?[item.id];

      Future<void> setFromLocal() async {
        final entry = await dataPlane.checkpointBusinessFromLocal(
          item.kindWire,
          item.id,
        );
        if (item.kindWire == kSyncPreferenceWire) {
          if (entry == null) {
            preferences.remove(item.id);
          } else {
            preferences[item.id] = entry;
          }
          return;
        }
        final rows = entities[item.kindWire] ??=
            <String, SyncCheckpointEntry>{};
        if (entry == null) {
          rows.remove(item.id);
        } else {
          rows[item.id] = entry;
        }
      }

      void keepPrior() {
        if (prior == null) return;
        if (item.kindWire == kSyncPreferenceWire) {
          preferences[item.id] = prior;
        } else {
          (entities[item.kindWire] ??=
                  <String, SyncCheckpointEntry>{})[item.id] =
              prior;
        }
      }

      void drop() {
        if (item.kindWire == kSyncPreferenceWire) {
          preferences.remove(item.id);
        } else {
          entities[item.kindWire]?.remove(item.id);
        }
      }

      switch (item.action) {
        case SyncConvAction.none:
          await setFromLocal();
        case SyncConvAction.iSend:
          if (sentKeys.contains(key)) {
            await setFromLocal();
          } else {
            keepPrior();
          }
        case SyncConvAction.peerSends:
          if (applyDeferred || !receivedKeys.contains(key)) {
            keepPrior();
          } else {
            await setFromLocal();
          }
        case SyncConvAction.bothSend:
          if (applyDeferred ||
              !sentKeys.contains(key) ||
              !receivedKeys.contains(key)) {
            keepPrior();
          } else {
            await setFromLocal();
          }
        case SyncConvAction.iDelete:
          if (failedDeleteKeys.contains(key)) {
            keepPrior();
          } else {
            drop();
          }
        case SyncConvAction.peerDeletes:
        case SyncConvAction.bothDeleted:
          drop();
      }
    }

    // A kind whose rows all disappeared would otherwise leave an empty map
    // behind and grow the checkpoint file for no reason.
    entities.removeWhere((_, rows) => rows.isEmpty);
    return SyncCheckpoint(
      previous.conversations,
      entities: entities,
      preferences: preferences,
    );
  }

  SyncSessionReport _report({
    required int sent,
    required int received,
    required Iterable<SyncSubtreeApplyOutcome> outcomes,
    required int deferred,
    required int deletedLocally,
    SyncBusinessPayload business = const SyncBusinessPayload(),
    SyncBusinessPayload receivedBusiness = const SyncBusinessPayload(),
    SyncBusinessApplyOutcome? appliedBusiness,
  }) {
    var upserted = 0;
    var deleted = 0;
    for (final outcome in outcomes) {
      upserted += outcome.upsertedMessages;
      deleted += outcome.deletedMessages;
    }
    final entityRows =
        _entityRowCount(business) + _entityRowCount(receivedBusiness);
    final preferenceRows =
        business.preferences.length + receivedBusiness.preferences.length;
    final parts = <String>[
      'sent $sent',
      'received $received',
      if (upserted > 0) '+$upserted msgs',
      if (deleted > 0) '-$deleted msgs',
      if (deletedLocally > 0) '-$deletedLocally convs',
      if (entityRows > 0) 'entities $entityRows',
      if (preferenceRows > 0) 'prefs $preferenceRows',
      if (deferred > 0) 'deferred $deferred',
      if (appliedBusiness?.deferred == true) 'business deferred',
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
      entityRows: entityRows,
      preferenceRows: preferenceRows,
    );
  }

  static int _entityRowCount(SyncBusinessPayload payload) {
    var total = 0;
    for (final rows in payload.entities.values) {
      total += rows.length;
    }
    return total;
  }

  /// Completes a session: records the outcome on the peer record and returns
  /// the report. The save is awaited — the caller sees a report only once it is
  /// durable, and nothing is left writing when the session is already over.
  Future<SyncSessionReport> _finish(
    SyncSessionReport report, {
    SyncPeerRecord? peer,
    String? host,
    int? port,
  }) async {
    lastReport = report;
    if (peer != null) {
      peer.lastSyncedAt = DateTime.now();
      peer.lastReport = report.toPeerReport();
      if (host != null) peer.lastHost = host;
      if (port != null) peer.lastPort = port;
      await store.savePeer(peer);
    }
    onStateChanged();
    return report;
  }

  /// A fresh 32-byte secret for a newly paired peer, base64 in a form that is
  /// safe in an HTTP header.
  static String _newSecret() {
    final random = Random.secure();
    return base64Encode(
      List<int>.generate(32, (_) => random.nextInt(256), growable: false),
    );
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
    required this.businessPlan,
    required this.checkpoint,
    required this.startedAt,
  });

  final SyncHello initiatorHello;
  final List<SyncConvPlan> plan;
  final List<SyncBusinessPlanItem> businessPlan;
  final SyncCheckpoint checkpoint;
  final DateTime startedAt;
  final Map<String, SyncSubtreeApplyOutcome> outcomes = {};

  /// Business rows the initiator pushed in this session's one PUT.
  SyncBusinessPayload receivedBusiness = const SyncBusinessPayload();

  /// Result of applying them, for the checkpoint and the report.
  SyncBusinessApplyOutcome? businessOutcome;
}
