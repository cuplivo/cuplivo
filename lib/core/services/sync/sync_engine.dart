import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'blob_sync.dart';
import 'sync_client.dart';
import 'sync_data_plane.dart';
import 'sync_endpoint_prober.dart';
import 'sync_identity.dart';
import 'sync_limits.dart';
import 'sync_local_addresses.dart';
import 'sync_merge.dart';
import 'sync_models.dart';
import 'sync_pairing_prober.dart';
import 'sync_server.dart';
import 'sync_store.dart';
import 'workspace_content_sync.dart';

/// One beat of an initiator session, for the card's progress line.
enum SyncSessionPhase {
  /// Dialing the remembered endpoints.
  connecting,

  /// Hello: exchanging manifests and planning.
  exchanging,

  /// Pushing this device's changes.
  sending,

  /// Fetching the peer's changes.
  receiving,

  /// Pulling file/skill blobs, counting [SyncSessionProgress.done] of [total].
  files,

  /// Applying what arrived to the local database.
  applying,
}

/// What the panel shows while this device initiates a session with a peer.
/// Transient by design — it lives exactly as long as the session.
class SyncSessionProgress {
  const SyncSessionProgress(
    this.phase, {
    this.done = 0,
    this.total = 0,
    this.address,
  });

  final SyncSessionPhase phase;

  /// How many of [total] items the phase has finished. Only
  /// [SyncSessionPhase.files] counts; the other phases are open-ended.
  final int done;
  final int total;

  /// The endpoint this beat is working on, `host:port`. Only
  /// [SyncSessionPhase.connecting] names one: an address that never answers is
  /// the one case where "which address?" is the whole story, and without it the
  /// card showed an opaque spinner while the dial, the handshake and a hello in
  /// flight (up to the hello deadline) all looked like "comparing data". Never
  /// a rank among candidates: the probe already ranked them at once, and how
  /// many addresses the dial has left is not something a user can act on.
  final String? address;
}

/// Outcome of one session, for the peer card and the sync report.
class SyncSessionReport {
  final bool success;
  final String summary;
  final SyncRefusalReason? refusal;

  /// Why the session failed when it was not a refusal — the structured form
  /// the panel localizes. A raw exception never leaves the engine: it carries
  /// the peer's address, and it is not a sentence.
  final SyncFailureReason? failure;
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

  /// Business rows this device *received* — the incoming half alone, where
  /// [entityRows]/[preferenceRows] add both directions because "how much moved"
  /// is what a card wants to say. An arrival gate must not read the aggregate:
  /// a session that only pushed rows to the peer changed nothing here.
  final int entityRowsReceived;
  final int preferenceRowsReceived;

  /// Blobs this device received and landed (slice 3), the bytes they carried,
  /// skill bodies that converged, skills whose local content lost the
  /// deterministic conflict rule, and blobs that could not be fetched.
  final int blobsMoved;
  final int blobBytes;
  final int skillsUpdated;
  final int skillConflicts;
  final int blobsMissing;

  /// Business rows whose local version the peer's newer row replaced (slice
  /// 5). The counters exist so an overwritten local edit is never silent.
  final int entityRowsLost;
  final int preferencesLost;

  /// Workspace content in either direction (slice 18), counted the same way the
  /// blob face is: what this device itself landed, deleted, lost and could not
  /// apply — plus how many workspaces it shared no content for (turned off, or
  /// over the caps), because silence about those is the one thing this face
  /// must never do.
  final int workspaceFiles;
  final int workspaceBytes;
  final int workspaceFilesRemoved;
  final int workspaceConflicts;
  final int workspaceFilesMissing;
  final int workspacesOmitted;

  /// Managed workspace *folders* this device kept on disk after the peer deleted
  /// their row, because the user had switched content sync off for them (slice
  /// 22). The row is gone either way; this is the count of folders the switch
  /// protected, and it exists so that protection is a fact on the report rather
  /// than something the user has to discover in a file manager.
  final int workspaceFoldersKept;

  /// Signed clock divergence observed at hello, in milliseconds — present
  /// only beyond [kClockSkewWarnMs]. The session succeeded anyway.
  final int? clockSkewMs;

  const SyncSessionReport({
    required this.success,
    required this.summary,
    this.refusal,
    this.failure,
    this.conversationsSent = 0,
    this.conversationsReceived = 0,
    this.messagesUpserted = 0,
    this.messagesDeleted = 0,
    this.deferred = 0,
    this.conversationsDeletedLocally = 0,
    this.entityRows = 0,
    this.preferenceRows = 0,
    this.entityRowsReceived = 0,
    this.preferenceRowsReceived = 0,
    this.blobsMoved = 0,
    this.blobBytes = 0,
    this.skillsUpdated = 0,
    this.skillConflicts = 0,
    this.blobsMissing = 0,
    this.entityRowsLost = 0,
    this.preferencesLost = 0,
    this.workspaceFiles = 0,
    this.workspaceBytes = 0,
    this.workspaceFilesRemoved = 0,
    this.workspaceConflicts = 0,
    this.workspaceFilesMissing = 0,
    this.workspaceFoldersKept = 0,
    this.workspacesOmitted = 0,
    this.clockSkewMs,
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
    blobsMoved: blobsMoved,
    blobBytes: blobBytes,
    skillsUpdated: skillsUpdated,
    skillConflicts: skillConflicts,
    blobsMissing: blobsMissing,
    entityRowsLost: entityRowsLost,
    preferencesLost: preferencesLost,
    workspaceFiles: workspaceFiles,
    workspaceBytes: workspaceBytes,
    workspaceFilesRemoved: workspaceFilesRemoved,
    workspaceConflicts: workspaceConflicts,
    workspaceFilesMissing: workspaceFilesMissing,
    workspaceFoldersKept: workspaceFoldersKept,
    workspacesOmitted: workspacesOmitted,
    clockSkewMs: clockSkewMs,
    refusal: refusal,
    failure: success || refusal != null ? null : failure,
  );
}

/// Orchestrates LAN sync sessions (ADR-0003, slice 1: conversations only).
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
    this.onProgressChanged,
    this.onResponderSession,
    this.onProbes,
    this.sessionIdleTtl = kSessionIdleTtl,
    this.yieldedSessionTtl = kYieldedSessionTtl,
    int Function()? clockUs,
    DateTime Function()? now,
  }) : clockUs = clockUs ?? (() => DateTime.now().microsecondsSinceEpoch),
       now = now ?? DateTime.now;

  final SyncDeviceIdentity identity;
  final SyncStore store;
  final SyncDataPlane dataPlane;

  /// How long an accepted session may go *untouched* before it is swept.
  ///
  /// Idle time, not age: the clock starts at the peer's last beat (or at the
  /// hello, for a session that has never been beaten), which is what
  /// [_dropIdleSessions] measures. A parameter only so a test can shrink the
  /// window instead of sleeping through the production one.
  final Duration sessionIdleTtl;

  /// How long a session accepted by yielding this device's own dial waits for
  /// the peer's first beat before it is dropped (see [kYieldedSessionTtl]).
  /// A parameter only so a test can shrink the window instead of sleeping
  /// through the production one; production never passes it.
  final Duration yieldedSessionTtl;

  /// This engine's wall clock. Read for every session timestamp — the hello
  /// stamp, a session's start, each beat — so a test can drive the clocks a
  /// session sweep is defined by without waiting for real minutes to pass.
  ///
  /// The checkpoint's own row clocks do not come from here: those are written by
  /// the database on the write path.
  final DateTime Function() now;

  /// The wall clock stamped into hellos, so tests can manufacture a skew. It
  /// feeds nothing else — row clocks keep coming from the write path.
  final int Function() clockUs;

  /// Called whenever engine-visible state changes (pairing window, peer list,
  /// session start and end) so the UI can rebuild.
  final void Function() onStateChanged;

  /// Called for the beats *inside* a running session, the file counter above
  /// all: it advances once per pulled blob. A consumer that reloads peer
  /// records on [onStateChanged] must not do it here — a beat cannot have
  /// changed a record, and a first sync pulls hundreds of blobs. Defaults to
  /// [onStateChanged], which is always correct and only costs that reload.
  final void Function()? onProgressChanged;

  /// Called when a session this device *answered* completes, with the peer as
  /// this engine last saved it and the report of what that session moved —
  /// the responder's counterpart to the report [syncWithPeer] returns. This
  /// device started nothing, so nothing else can tell the consumer the data
  /// arrived; whether that deserves a user-facing announcement is the
  /// consumer's decision, not the engine's.
  final void Function(SyncPeerRecord peer, SyncSessionReport report)?
  onResponderSession;

  /// This device's own candidate addresses, pushed by the provider whenever it
  /// re-enumerates them. The dial uses them to tell an address on the network
  /// this device is standing on from a memory of another one; empty until the
  /// first enumeration lands, which leaves candidate order untouched.
  List<LanAddress> localAddresses = const [];

  /// The listener port this device advertises in its hello: [port], unless a
  /// test says otherwise.
  ///
  /// The seam exists for one condition a two-peer test cannot otherwise produce:
  /// both sides of a test pair are dialable at 127.0.0.1, so "the peer wants a
  /// file it cannot fetch for itself" — the case the push fallback is for — has
  /// no other way to be constructed.
  @visibleForTesting
  int? advertisedListenPort;

  late final SyncServer server = SyncServer(
    identity: identity,
    store: store,
    handler: this,
  );
  late final SyncClient client = SyncClient(identity: identity);

  final Random _random = Random.secure();
  final Map<String, _ResponderSession> _sessions = {};

  /// Peers this device is currently initiating *to*. Together with [_sessions]
  /// it is the single-flight lock for a pair: both roles write the same
  /// checkpoint file, so they must never run at once (see [syncWithPeer]).
  ///
  /// A round is cancellable only until it hears the peer's hello: at that point
  /// it is a live session and the pair's real outcome is already forming. Before
  /// that it has proved nothing, which is why an arriving hello defeats it
  /// ([_InitiatorRound]).
  final Map<String, _InitiatorRound> _initiatorRounds = {};

  /// The probes this device has for each peer's endpoints, pushed by the
  /// provider so the dial can spend the measurement it already paid for
  /// instead of probing again: the address that answered in 4 ms is the one to
  /// dial, and its round trip is what bounds the connect timeout.
  ///
  /// Each measurement carries its own timestamp, and one older than
  /// [kSyncProbeFreshness] is ignored — it describes a network this device may
  /// have already left. A snapshot is not re-stamped per publish: the figure's
  /// age is the figure's, not the round's.
  Map<String, List<EndpointProbeResult>> endpointProbes = const {};

  /// Called when this engine ran a probe round of its own (a session whose
  /// snapshot had gone stale). The consumer folds the results into the cards'
  /// latency figures and its own snapshot.
  void Function(String deviceId, List<EndpointProbeResult> results)? onProbes;

  /// Live progress of this device's initiator sessions, by peer id — the
  /// provider surfaces it on the peer cards. Entries live exactly as long as
  /// the session in [syncWithPeer]'s `finally`.
  final Map<String, SyncSessionProgress> initiatorProgress = {};

  /// Publishes one progress beat. A phase change is one line of UI; the file
  /// count is the only sub-beat worth a rebuild.
  void _setProgress(
    String deviceId,
    SyncSessionPhase phase, {
    int done = 0,
    int total = 0,
    String? address,
  }) {
    initiatorProgress[deviceId] = SyncSessionProgress(
      phase,
      done: done,
      total: total,
      address: address,
    );
    (onProgressChanged ?? onStateChanged)();
  }

  /// What this device published for a manifest, by content hash: files are
  /// served straight from their canonical path, skill directories are zipped
  /// on demand. Populated whenever a manifest is built or received, so a blob
  /// pending from an earlier session in this launch is still servable.
  final Map<String, File> _publishedBlobs = {};
  final Map<String, String> _publishedSkillIds = {};

  String? _pairingPin;
  DateTime? _pairingExpiresAt;
  int _pairingFailures = 0;
  SyncSessionReport? lastReport;

  static const _pairingWindow = Duration(minutes: 5);

  /// How long an accepted session may go untouched before it is swept. Two
  /// minutes is far longer than any healthy beat, and short enough that a
  /// session abandoned by a peer that vanished does not hold the pair's single
  /// session slot for the rest of the launch.
  ///
  /// It is a *liveness* bound on an idle session, never on a session that is
  /// working: a beat in flight is activity, however long it runs (a first sync
  /// of a large library is one push beat lasting minutes), and the sweep reads
  /// the session's own state to know that ([_ResponderSession.beatsInFlight]).
  /// Measuring age from the hello instead — which this rule used to do — kills
  /// the very session that is transferring, and the peer's next beat then fails
  /// against a session the sweep removed underneath it.
  static const kSessionIdleTtl = Duration(minutes: 2);

  /// How long a session this device accepted by **yielding** its own dial waits
  /// for the peer's first beat before it is treated as abandoned.
  ///
  /// Yielding is a bet: an arriving hello proves the peer reaches this device,
  /// so the round it superseded is dropped and this side answers instead. In a
  /// crossing dial *both* sides make that bet, so neither client is left to
  /// drive either session — each side then holds a session nobody will push to
  /// and refuses its own dials as busy. A yielded session with no beat after
  /// this window is therefore dropped rather than believed, and the pair's next
  /// attempt gets through. The window is short on purpose: the peer that
  /// yielded to us pushes within milliseconds of its hello, so a yielded
  /// session that has never been touched is not a slow session.
  static const kYieldedSessionTtl = Duration(seconds: 4);

  /// The port a sync listener prefers, so a firewall rule and a peer's stored
  /// endpoint stay stable across launches. A busy port falls back to an
  /// ephemeral one (two app instances on one machine).
  static const kPreferredPort = 9527;

  /// The port this device's sync listener is bound to, or null when stopped.
  int? get port => server.port;

  /// Whether this device currently holds an accepted session for [deviceId].
  ///
  /// The state the sweep rules are about, exposed so a test can assert on the
  /// session itself. A refusal is not a substitute: `busy` is produced by a held
  /// session *and* by a peer that is mid-session of its own, so a test that reads
  /// only the refusal cannot tell "the sweep kept my session" from "the peer
  /// refused me".
  @visibleForTesting
  bool hasResponderSession(String deviceId) => _sessions.containsKey(deviceId);

  /// How many beats are in flight on [deviceId]'s session here, or 0 when there
  /// is no session.
  @visibleForTesting
  int beatsInFlightFor(String deviceId) =>
      _sessions[deviceId]?.beatsInFlight ?? 0;

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
    // Transfer scratch and served-zip caches are reproducible, so a launch
    // starts from an empty cache instead of accumulating stale archives.
    await store.clearBlobCache();
    await dataPlane.clearSkillBlobCache();
    try {
      return await server.start(requestedPort: preferredPort);
    } on SocketException {
      return server.start(requestedPort: 0);
    }
  }

  Future<void> stop() async {
    await server.stop();
    _sessions.clear();
    _publishedBlobs.clear();
    _publishedSkillIds.clear();
    _pairingPin = null;
    _pairingExpiresAt = null;
    _pairingFailures = 0;
  }

  /// Opens a one-shot pairing window and returns the PIN to type on the other
  /// device.
  String openPairing() {
    final pin = List.generate(6, (_) => _random.nextInt(10)).join();
    _pairingPin = pin;
    _pairingExpiresAt = DateTime.now().add(_pairingWindow);
    _pairingFailures = 0;
    onStateChanged();
    return pin;
  }

  void cancelPairing() {
    _pairingPin = null;
    _pairingExpiresAt = null;
    onStateChanged();
  }

  /// Pairs with a peer showing [pin] at `host:port`. [expectedDeviceId] is
  /// the QR-scanned certificate fingerprint; see [SyncClient.pair].
  ///
  /// [knownCandidates] are the other endpoints the QR advertised: only `host`
  /// has answered, so the rest are remembered as hints behind it.
  /// [advertisedAddresses] are this device's own addresses, sent so the
  /// responder remembers more than the one address this connection came from.
  Future<SyncPeerRecord> pairWith({
    required String host,
    required int port,
    required String pin,
    String? expectedDeviceId,
    List<(String, int)> knownCandidates = const [],
    List<String> advertisedAddresses = const [],
  }) async {
    final result = await client.pair(
      host: host,
      port: port,
      pin: pin,
      listenPort: this.port,
      expectedDeviceId: expectedDeviceId,
      candidateHosts: advertisedAddresses,
    );
    final answer = result.answer;
    final peer = SyncPeerRecord(
      deviceId: answer.deviceId,
      certPem: result.certPem,
      secret: answer.secret,
      name: answer.deviceName.isEmpty ? answer.deviceId : answer.deviceName,
      platform: answer.platform,
    );
    final existing = await store.findPeer(answer.deviceId);
    _carryPairingFacts(peer, existing);
    peer.noteEndpointSuccess(host, port);
    _reportDroppedEndpoints(
      answer.deviceId,
      peer.rememberEndpointCandidates(knownCandidates),
    );
    // And behind both, the networks the pair has already met: re-pairing is the
    // drift-repair journey, so forgetting them here is what made alternating
    // home and office cost a re-scan every time.
    if (existing != null) {
      _reportDroppedEndpoints(
        answer.deviceId,
        peer.rememberEndpointHistory(existing.endpoints),
      );
    }
    await store.savePeer(peer);
    // This listener must accept the peer too: pairing may have been initiated
    // from this side, in which case the answer (not a request) carried the
    // secret.
    server.rememberPeer(peer);
    onStateChanged();
    return peer;
  }

  /// Pairs with a peer by trying [endpoints] in order until one answers.
  ///
  /// The candidates are probed in parallel first (see [orderPairingCandidates]),
  /// so a black-holed address costs one shared probe instead of a full dial
  /// budget per candidate. This is the one walk that keeps the *bare TCP* probe:
  /// pairing is where no secret exists yet, so there is nothing to authenticate
  /// with until the PIN (or the scanned fingerprint) has been spent.
  ///
  /// What a failing candidate means decides whether the next one is tried:
  ///
  /// - A dead address (refused connection, timeout, failed handshake) moves on:
  ///   the next candidate is still a fair attempt. A failed handshake in
  ///   particular says nothing about the pairing — the pin refuses that address
  ///   inside the handshake, before any request byte leaves this device — so an
  ///   address belonging to someone else disqualifies the *address*.
  /// - A verdict from the scanned device itself (a refused PIN, an identity
  ///   mismatch) ends the attempt: the device answered, and it would answer the
  ///   same way on every other address it holds.
  ///
  /// When nothing answers, the last connectivity error is rethrown for the
  /// caller to classify — unless some address answered as a different device,
  /// which is the more actionable outcome (no retry helps; a fresh code does).
  /// Neither is ever rendered raw.
  ///
  /// Every endpoint this loop does *not* spend the pairing on stays on the
  /// record as a hint behind the winner: the peer's other addresses are
  /// exactly what a later roaming round needs when this one stops working.
  Future<SyncPeerRecord> pairWithCandidates({
    required List<(String, int)> endpoints,
    required String pin,
    String? expectedDeviceId,
    List<String> advertisedAddresses = const [],
  }) async {
    final candidates = await orderPairingCandidates(
      endpoints,
      localAddresses: localAddresses,
    );
    Object? lastConnectivityError;
    var sawWrongCertificate = false;
    for (final (host, port) in candidates) {
      try {
        return await pairWith(
          host: host,
          port: port,
          pin: pin,
          expectedDeviceId: expectedDeviceId,
          // Probe-ordered rather than as scanned: the addresses that answered
          // just now are the ones a later roaming round should try first.
          knownCandidates: candidates,
          advertisedAddresses: advertisedAddresses,
        );
      } on SyncClientException catch (error) {
        if (error.message != 'pair_fingerprint_mismatch') rethrow;
        // Not a verdict from the scanned device: this address presented another
        // certificate, so the pin refused it before the PIN was sent anywhere.
        // The peer's remaining addresses are still untried.
        sawWrongCertificate = true;
      } on SocketException catch (error) {
        lastConnectivityError = error;
      } on TimeoutException catch (error) {
        lastConnectivityError = error;
      }
    }
    if (sawWrongCertificate) {
      // An address answered and it was not the scanned device. That is more
      // actionable than silence: the code in hand is wrong or stale, and
      // retrying the same list changes nothing.
      throw const SyncClientException('pair_fingerprint_mismatch');
    }
    throw lastConnectivityError ??
        const SocketException('no pairing endpoint answered');
  }

  /// Removes a pairing from this device, and — best effort — tells the peer to
  /// forget us too. The remote call is fire-and-forget with the secret we
  /// still hold: unpairing must not wait on a peer that may be gone, and any
  /// failure leaves the fallback intact (the peer's next session ends as a
  /// localized `not_paired` refusal instead of a raw error).
  ///
  /// The notice goes to the best-remembered endpoint only: it is a courtesy
  /// within a three-second budget, and every candidate it did not reach is
  /// covered by the fallback above.
  Future<void> unpair(String deviceId) async {
    final peer = await store.findPeer(deviceId);
    final endpoint = peer?.primaryEndpoint;
    if (peer != null && endpoint != null) {
      unawaited(
        client
            .revoke(peer: peer, host: endpoint.host, port: endpoint.port)
            .catchError((_) {}),
      );
    }
    await store.deletePeer(deviceId);
    server.forgetPeer(deviceId);
    // The pairing is gone, so the files this device advertised for it are not
    // promised to anyone any more.
    dataPlane.clearWorkspacePublication(deviceId);
    onStateChanged();
  }

  /// The other half of unpairing: a paired peer proved its identity and asks
  /// this device to drop the pairing. Only the caller's own record goes — the
  /// per-peer secret is what authenticated the request, so no third device
  /// can revoke someone else's pairing.
  @override
  Future<void> handleRevoke(String peerDeviceId) async {
    _sessions.remove(peerDeviceId);
    dataPlane.clearWorkspacePublication(peerDeviceId);
    await store.deletePeer(peerDeviceId);
    server.forgetPeer(peerDeviceId);
    onStateChanged();
  }

  /// Runs one session against a paired peer. This is the initiator role.
  ///
  /// One session per pair at a time, in both roles. Two sessions for the same
  /// peer (this device initiating while it also answers the peer's hello) would
  /// write the same checkpoint file from two call sites, each computed from the
  /// checkpoint it read at its own hello, so the later write would discard the
  /// other advance. The marker is taken before the first await — Dart's single
  /// isolate makes that the whole lock — and a peer initiating at the same
  /// moment is refused instead of interleaved.
  ///
  /// The remembered endpoints are probed in parallel and the dial spends that
  /// proof: the addresses the probe reached — best measured first — are dialed
  /// in order until one answers, and an address it did not reach is not dialed
  /// at all. The probe already asked every address at once, so re-asking them
  /// one at a time would spend the same parallel answer twice, and pay a full
  /// connect budget for each repetition. An address is a hint from a network
  /// this device may have left — the same laptop sits at a different address at
  /// home, at work and on a phone hotspot — and the certificate pin re-verifies
  /// whoever answers.
  ///
  /// A probe that proved nothing still buys one dial — the best-remembered
  /// address — because a single measurement is not a verdict on the network.
  /// Only "could not be reached at all" falls through to the next proven
  /// candidate; a refusal from the peer is that peer's verdict, and its other
  /// addresses would only repeat it.
  Future<SyncSessionReport> syncWithPeer(
    SyncPeerRecord peer, {
    String? host,
    int? port,
  }) async {
    // Before the refusal below: an abandoned session held for this peer is what
    // would refuse this round, so it has to be reconsidered first (see
    // [_sweepSessions]).
    _sweepSessions();
    if (_sessions.containsKey(peer.deviceId) ||
        _initiatorRounds.containsKey(peer.deviceId)) {
      return await _finish(
        const SyncSessionReport(
          success: false,
          summary: 'refused:busy',
          refusal: SyncRefusalReason.busy,
        ),
        peer: peer,
      );
    }
    final round = _InitiatorRound();
    // Taken before the first await: Dart's single isolate makes the insertion
    // the whole lock, so a hello arriving during the dial either finds this
    // round or finds nothing.
    _initiatorRounds[peer.deviceId] = round;
    try {
      _setProgress(peer.deviceId, SyncSessionPhase.connecting);
      if (round.cancelled) return _superseded(peer);
      // An explicit endpoint (a repair attempt) is the only candidate; the
      // remembered set is the default, best first.
      final candidates = (host != null && port != null)
          ? <(String, int)>[(host, port)]
          : [
              for (final endpoint in peer.endpoints)
                (endpoint.host, endpoint.port),
            ];
      if (candidates.isEmpty) {
        // Recorded on the peer like every other outcome: the card reads
        // `peer.lastReport`, so an unpersisted failure would leave a stale
        // success on screen. `noEndpoint` rather than `unreachable`: nothing
        // was dialed, so the card must ask for an address instead of a retry.
        return await _finish(
          const SyncSessionReport(
            success: false,
            summary: 'no_endpoint',
            failure: SyncFailureReason.noEndpoint,
          ),
          peer: peer,
        );
      }
      final ordered = await _orderCandidates(peer, candidates, round);
      if (round.cancelled) return _superseded(peer);
      // One address is the probe's own degenerate case: there is nothing to
      // choose between, so the dial is the probe and no measurement is needed
      // to justify it.
      final dialable = ordered.length == 1
          ? ordered
          : dialableCandidates(ordered, round.probed);
      // The probe is the dial's parallel pre-step, and the dial spends it: only
      // an address it proved (or was too loaded to judge) is worth a session.
      // Proving nothing is the one case that still gets a single guess — the
      // best-remembered address — because one measurement is not a verdict on
      // the network, and walking every other address one at a time is what made
      // a probe that had already run in parallel look serial.
      final attempts = dialable.isNotEmpty
          ? dialable
          : _oneGuess(ordered, round.lastKnown);
      for (final (candidateHost, candidatePort) in attempts) {
        if (round.cancelled) return _superseded(peer);
        // The dial, the handshake and the hello in flight are one opaque beat
        // from the outside, and it is the one that can hang: naming the address
        // is what turns "it is stuck" into "it is stuck on *this* address".
        _setProgress(
          peer.deviceId,
          SyncSessionPhase.connecting,
          address: formatHostPort(candidateHost, candidatePort),
        );
        final report = await _syncWithPeerAt(
          peer,
          host: candidateHost,
          port: candidatePort,
          round: round,
          connectTimeout: dialTimeoutFor(
            round.probed[(candidateHost, candidatePort)],
          ),
        );
        if (round.cancelled) return _superseded(peer);
        if (report != null) return report;
      }
      // Nothing answered: the peer is off, or it moved to a network this device
      // has not learned yet (re-scan its QR, or type the address on its card).
      return await _finish(
        const SyncSessionReport(
          success: false,
          summary: 'unreachable:no_candidate_answered',
          failure: SyncFailureReason.unreachable,
        ),
        peer: peer,
      );
    } finally {
      if (identical(_initiatorRounds[peer.deviceId], round)) {
        _initiatorRounds.remove(peer.deviceId);
      }
      initiatorProgress.remove(peer.deviceId);
      onStateChanged();
    }
  }

  /// The report of a round that yielded to the peer's own session. It is not a
  /// failure and not a refusal by the peer, so it is recorded nowhere: the
  /// pair's real outcome arrives from the answered side, and a "busy" line on
  /// the card for a session that is about to succeed would be a lie.
  SyncSessionReport _superseded(SyncPeerRecord peer) {
    debugPrint(
      'sync: ${peer.deviceId} superseded by the peer\'s own session with us',
    );
    onStateChanged();
    return const SyncSessionReport(
      success: false,
      summary: 'superseded',
      refusal: SyncRefusalReason.superseded,
    );
  }

  /// Orders [candidates] for the serial dial, from the freshest measurement
  /// available.
  ///
  /// The provider's snapshot is used as-is — that is the whole point of probing
  /// on a timer, the session must not pay for it twice — but each measurement is
  /// judged on its own timestamp: the provider reuses the answers for endpoints
  /// a tick did not visit, so a snapshot can hold one figure from four seconds
  /// ago and another from a minute ago. Only the fresh ones count, and when none
  /// is left this round probes for itself. Either way the order is "answered,
  /// fastest first", and the same measurements set each candidate's connect
  /// budget.
  Future<List<(String, int)>> _orderCandidates(
    SyncPeerRecord peer,
    List<(String, int)> candidates,
    _InitiatorRound round,
  ) async {
    if (candidates.length <= 1) return candidates;
    final snapshot = endpointProbes[peer.deviceId];
    if (snapshot != null) {
      final now = DateTime.now();
      round.probed = {
        for (final result in snapshot)
          if (now.difference(result.measuredAt) <= kSyncProbeFreshness)
            result.endpoint: result,
      };
      // Kept whole, freshness aside: only the fallback below reads it, and there
      // a stale answer is the best thing known about an address nothing could
      // prove this round.
      round.lastKnown = {
        for (final result in snapshot) result.endpoint: result,
      };
      if (round.probed.isNotEmpty) {
        return orderCandidatesByProbe(candidates, round.probed, localAddresses);
      }
    }
    final results = await probePeerEndpoints(
      endpoints: candidates,
      probe: syncEndpointProbe(client, peer),
    );
    round.probed = {for (final result in results) result.endpoint: result};
    round.lastKnown = round.probed;
    onProbes?.call(peer.deviceId, results);
    return orderCandidatesByProbe(candidates, round.probed, localAddresses);
  }

  /// The one address a round that proved nothing still dials.
  ///
  /// The raw head of the order is the memory's first address, which may be one
  /// that has *never* answered while the address that worked last time sits
  /// behind it: the freshness rule ([kSyncProbeFreshness]) keeps an old figure
  /// from ordering the dial, but it does not make the address that figure names
  /// a bad bet — and the address that answered last is exactly what the round is
  /// trying to reach again. Candidates whose last answer was silence are only
  /// reached when *none* ever answered, and the order is preserved inside each
  /// half, so topology still breaks the tie among the last-known-answered.
  ///
  /// One guess, never two: this is the state in which the probe has already
  /// asked every address, and the session may not turn into a second serial
  /// probe.
  static List<(String, int)> _oneGuess(
    List<(String, int)> ordered,
    Map<(String, int), EndpointProbeResult> lastKnown,
  ) {
    for (final candidate in ordered) {
      if (lastKnown[candidate]?.answered ?? false) return [candidate];
    }
    return ordered.take(1).toList();
  }

  /// Runs the session body against one fixed endpoint. Returns the report, or
  /// null when the endpoint never answered — the caller then tries the next
  /// remembered candidate.
  ///
  /// A `TlsException` — a `HandshakeException` among them — is a null too, on
  /// purpose: it means the address now belongs to another device (a recycled
  /// lease) or something claims to be the peer. The pin refused it inside the
  /// handshake, before any request byte, so nothing leaked towards the wrong
  /// endpoint and the next candidate is still a fair attempt.
  Future<SyncSessionReport?> _syncWithPeerAt(
    SyncPeerRecord peer, {
    required String host,
    required int port,
    required _InitiatorRound round,
    Duration? connectTimeout,
  }) async {
    onStateChanged();
    if (round.cancelled) return null;
    final session = client.openSession(
      peer,
      host: host,
      port: port,
      connectTimeout: connectTimeout,
    );
    // Published on the round so a hello arriving while this one is in flight
    // can break it: a round that yields must not keep a socket, a request or a
    // checkpoint write alive behind the session that superseded it.
    round.session = session;
    try {
      final myManifest = await dataPlane.buildManifest();
      if (round.cancelled) return null;
      final myClockUs = clockUs();
      // Read before the hello: the checkpoint carries what this device owes
      // itself from last session (applies it had to defer), and the peer needs
      // that in the hello to tell "never delivered" from "deleted here".
      final previous = await store.loadCheckpoint(peer.deviceId);
      final myEpoch = await store.readDataEpoch();
      if (round.cancelled) return null;
      final SyncHelloOutcome hello;
      try {
        hello = await session.hello(
          SyncHello(
            protocolVersion: kSyncProtocolVersion,
            schemaVersion: dataPlane.schemaVersion,
            deviceId: identity.deviceId,
            deviceName: identity.name,
            platform: platformTag(),
            manifest: myManifest,
            // Advertised so the responder can pull its blobs back over this
            // device's listener (slice 3). `this.port` on purpose: the method's
            // own `port` parameter is the peer's endpoint, not ours.
            listenPort: advertisedListenPort ?? this.port,
            // ...and where that listener can be reached (slice 23). The address
            // the responder sees this connection come from can be its own, so
            // these are the addresses it falls back to when it has to dial back.
            candidateHosts: [
              for (final address in localAddresses) address.address,
            ],
            clockUs: myClockUs,
            unappliedConversations: previous.unappliedConversations,
            unappliedBusiness: previous.unappliedBusiness,
            // Deletions this device has not seen confirmed by the peer.
            deletedConversations: _deletionsToAnnounce(previous, myManifest),
            // This device's data epoch: a bulk replacement since the last session
            // tells the peer not to read this device's missing rows as deletions.
            epoch: myEpoch,
          ),
        );
      } on SocketException catch (error) {
        // Refused, unroutable: nothing answered at this address. The caller
        // tries the next one.
        debugPrint('sync: ${peer.deviceId} unreachable at $host:$port: $error');
        return null;
      } on TlsException catch (error) {
        // The address answered, and the pin refused what answered: a recycled
        // lease a second install now holds, or an identity that rotated after a
        // wipe. That is a verdict on the *address*, so the walk continues — the
        // same reading the pairing walk gives it. A `HandshakeException`
        // implements `TlsException` (it is **not** a `SocketException`), and the
        // refusal happens inside the handshake, before any request byte, so
        // nothing leaked towards the endpoint that answered.
        debugPrint(
          'sync: ${peer.deviceId} answered as another device at $host:$port: '
          '$error',
        );
        return null;
      } on TimeoutException catch (error) {
        debugPrint('sync: ${peer.deviceId} timed out at $host:$port: $error');
        return null;
      }
      // The peer answered *this* round, so it is a live session: from here on a
      // hello from the peer is refused as busy instead of superseding us. The
      // flag is set synchronously when the await resumes, so a hello handled
      // after this point cannot race it.
      round.answered = true;
      if (round.cancelled) return null;
      if (hello.refusal != null) {
        return await _finish(
          SyncSessionReport(
            success: false,
            summary: 'refused:${hello.refusal!.reason.wire}',
            refusal: hello.refusal!.reason,
          ),
          peer: peer,
          host: host,
          port: port,
        );
      }
      final peerHello = hello.hello!;
      // Yellow-flag clock divergence (slice 5): informational only, the
      // session proceeds regardless.
      final clockSkewMs = _clockSkewMs(myClockUs, peerHello.clockUs);
      // Symmetric version gate, our half: refuse a peer whose schema we do not
      // know (the peer enforces its half before answering).
      if (peerHello.schemaVersion > dataPlane.schemaVersion) {
        return await _finish(
          const SyncSessionReport(
            success: false,
            summary: 'refused:peer_schema_newer',
            refusal: SyncRefusalReason.peerSchemaNewer,
          ),
          peer: peer,
          host: host,
          port: port,
        );
      }
      // Both manifests are in hand and the peer answered: this is the beat the
      // label can honestly call "comparing data". It must not be set any
      // earlier — the hello round trip is where a silent address spends its
      // whole budget, and showing that as "comparing data" is what made a
      // hanging dial look like a hung comparison.
      _setProgress(peer.deviceId, SyncSessionPhase.exchanging);

      // Conversations the peer says it could not apply: its copy is stale or
      // absent, so re-send rather than read its silence as a deletion. Its
      // announced deletions are the mirror image and take precedence: they name
      // deletions rather than absences.
      final peerUnapplied = peerHello.unappliedConversations.toSet();
      // A different epoch means the peer's database was bulk-replaced: rows it
      // lacks were dropped by that replacement, not deleted, so no absence of
      // its may justify a deletion here.
      final peerReplaced = peerHello.epoch != previous.peerEpoch;
      var plan = _applyDeletionAnnouncements(
        _reSendUnapplied(
          planSync(
            mine: myManifest,
            peers: peerHello.manifest,
            checkpoint: previous,
          ),
          peerUnapplied,
        ),
        peerHello.deletedConversations,
        myManifest,
      );
      var businessPlan = _keepRowsPeerMayNeverHaveSeen(
        planBusinessSync(
          mine: myManifest,
          peers: peerHello.manifest,
          checkpoint: previous,
        ),
        peerHello.unappliedBusiness,
      );
      if (peerReplaced) {
        // A deletion this device made itself still stands (it plans
        // `peerDeletes`, carried to the peer by the announcement); what is
        // overridden is deleting our own rows to match a peer that lost them.
        plan = _reSendInsteadOfDelete(plan);
        businessPlan = _keepInsteadOfDelete(businessPlan);
      }
      final skillPlan = planSkillContentSync(
        mine: myManifest,
        peers: peerHello.manifest,
        checkpoint: previous,
        skillWire: SyncDataPlane.skillWire,
      );
      // Skill directory hashes as they stand *before* anything is applied:
      // both the outgoing manifest and the content verdict are read from here.
      final mySkillHashes = await dataPlane.skillDirHashes();

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

      // The push payload exactly as it was read. A sent conversation's
      // checkpoint entry must describe what crossed the wire: re-reading local
      // state at advance time would record a message written during the session
      // as peer-seen, and the next session's deletion oracle would then remove
      // it from this device — the peer never received it.
      final sentSubtrees = {
        for (final subtree in outgoing)
          subtree.conversation['id'] as String: subtree,
      };

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

      // What the responder acknowledged about this push: a conversation it
      // deferred is *not* state the peer holds, and an entry advanced as if it
      // were would turn the peer's older copy into a deletion next session.
      var peerDeferred = const <String>{};
      var peerBusinessDeferred = false;
      var peerDeferredSkills = const <String>{};
      // The push beat always runs, even with nothing to push. It is where the
      // responder executes its own blob pull — including the retries its
      // checkpoint still owes — and skipping it would both lose that retry and
      // persist the empty pull outcome over the pending list.
      final outgoingAssets = await dataPlane.buildBlobManifest(
        subtrees: outgoing,
        business: outgoingBusiness,
      );
      _rememberPublished(outgoingAssets);
      // Workspace content (slice 18). The walk and the publish happen here,
      // just before the push, because the responder fetches whatever it decides
      // it needs *inside* that beat: a file this device has not advertised and
      // published by then cannot be served, and the responder would have to
      // wait a whole session for it.
      final myWorkspaceSnapshots = await dataPlane.workspaceSnapshots();
      final advertised = dataPlane.workspaceTables(myWorkspaceSnapshots);
      dataPlane.publishWorkspaceContent(peer.deviceId, myWorkspaceSnapshots);
      // Only the skill bodies this push actually carries advertise a hash.
      final sentSkillIds =
          outgoingEntityIds[SyncDataPlane.skillWire] ?? const <String>{};
      _setProgress(peer.deviceId, SyncSessionPhase.sending);
      final ack = await session.pushDelta(
        SyncDeltaBatch(
          outgoing,
          business: outgoingBusiness,
          assets: outgoingAssets,
          skillHashes: {
            for (final id in sentSkillIds)
              if (mySkillHashes[id] != null) id: mySkillHashes[id]!,
          },
          workspaceFiles: advertised.tables,
        ),
      );
      peerDeferred = ack.deferred;
      peerBusinessDeferred = ack.businessDeferred;
      peerDeferredSkills = ack.deferredSkills;

      // Files the responder could not fetch for itself (slice 23). It asked for
      // them in the acknowledgement, and this connection is the direction the
      // pair is known to have; pushing here — before the fetch beat — means the
      // responder's own file walk, taken while it answers that beat, already
      // sees them, so its reply describes what it holds rather than what it
      // hoped to.
      final pushed = await _pushRequestedWorkspaceFiles(
        session: session,
        peerDeviceId: peer.deviceId,
        requests: ack.workspaceRequests,
      );

      // The blobs the responder could not fetch for itself (slice 24), for the
      // same reason and in the same place: a message's image, an avatar or a
      // skill body reaches a peer that cannot be dialled back only because the
      // side that holds it sends it, and sending it before the fetch beat means
      // the responder's own walk — taken while it answers that beat — already
      // describes what it holds.
      final pushedBlobs = await _pushRequestedBlobs(
        session: session,
        peerDeviceId: peer.deviceId,
        requests: ack.blobRequests,
      );

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
      _setProgress(peer.deviceId, SyncSessionPhase.receiving);
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
      _rememberPublished(incoming.assets);

      // Blob beat: what this device must pull from the peer, in one pass —
      // the files the incoming rows reference, any skill body whose content
      // arc says the peer wins, and whatever a previous session still owes.
      final adoptions = _planSkillAdoptions(
        plan: skillPlan,
        mine: myManifest,
        peers: peerHello.manifest,
        peerSkillHashes: incoming.skillHashes,
        mySkillHashes: mySkillHashes,
        myDeviceId: identity.deviceId,
        peerDeviceId: peer.deviceId,
      );
      final neededAssets = await dataPlane.neededFileBlobs(incoming.assets);
      final wanted = _foldBlobWanted([
        ...neededAssets,
        ...adoptions.wanted,
      ], previous.pendingBlobs.values);
      final pulled = await _pullBlobs(
        wanted.values.toList(),
        session,
        onProgress: (done, total) => _setProgress(
          peer.deviceId,
          SyncSessionPhase.files,
          done: done,
          total: total,
        ),
      );
      final deferredSkills = {
        ...adoptions.deferred,
        for (final id in adoptions.wantedSkillIds)
          if (!pulled.landedSkillIds.contains(id)) id,
      };

      final delivered = {
        for (final subtree in incoming.subtrees)
          subtree.conversation['id'] as String,
      };
      missingIncoming.addAll(requested.where((id) => !delivered.contains(id)));
      _setProgress(peer.deviceId, SyncSessionPhase.applying);
      outcomes.addAll(
        await dataPlane.applySubtrees(
          incoming.subtrees,
          myDeviceId: identity.deviceId,
          peerDeviceId: peer.deviceId,
          // A conversation the peer reported as unapplied is one whose rows it
          // may never have seen: the merge must not treat this device's local
          // rows as rows the peer deleted.
          checkpointRowsByConversation: _rowsOf(
            previous,
            // A replaced peer's absences prove nothing about this device's
            // rows: its old copy never carried them at all.
            peerReplaced ? const <String>{} : delivered,
            unconfirmed: peerUnapplied,
          ),
        ),
      );
      // Registration keys off the peer's whole advertisement, not what the
      // pull landed: a blob whose fetch failed still gets its reference now,
      // so the retry that lands it in a later session is already protected.
      await dataPlane.registerLandedAssets(
        subtrees: incoming.subtrees,
        outcomes: outcomes,
        advertisedByUri: {
          for (final entry in incoming.assets) entry.key: entry,
        },
      );

      // A skill record whose body did not converge is deferred: a record
      // without its directory would only install a broken skill here.
      final applicableBusiness = dataPlane.withoutSkillRows(
        incoming.business,
        deferredSkills,
      );
      final receivedBusiness = dataPlane.businessKeysOf(applicableBusiness);
      final businessOutcome = await dataPlane.applyBusiness(
        applicableBusiness,
        myDeviceId: identity.deviceId,
        peerDeviceId: peer.deviceId,
      );
      // A swapped-in or deleted skill body changes what the skills service
      // exposes even when the record row itself did not move.
      if (pulled.landedSkillIds.isNotEmpty) await dataPlane.reloadBusiness();

      // Workspace files (slice 18). The peer's table arrived with the fetch
      // response, and the responder published its own files before answering
      // it, so everything this device decides it needs is servable right now
      // over the connection that is already open.
      //
      // The walk is taken *here*, after the business apply, and deliberately not
      // reused from the pre-push one: a workspace record that just arrived is
      // what makes its folder this device's to populate, and it is absent from a
      // list walked before the apply — so the whole direction would wait a
      // session for content the peer is advertising right now. The pre-push walk
      // stays what it is for (what this device serves inside the push beat), and
      // the responder walks twice per session in exactly the same way.
      final planningSnapshots = await dataPlane.workspaceSnapshots();
      final workspaceOutcome = await dataPlane.applyWorkspaceContent(
        myDeviceId: identity.deviceId,
        peerDeviceId: peer.deviceId,
        mine: planningSnapshots,
        peerTables: incoming.workspaceFiles,
        ledger: previous.workspaceFiles,
        // A bulk-replaced peer's missing files prove nothing: they were
        // dropped, not deleted, so they are re-offered rather than removed
        // here.
        allowDeletes: !peerReplaced,
        fetch: (workspaceId, relPath, destination) =>
            session.fetchWorkspaceFile(
              workspaceId: workspaceId,
              relPath: relPath,
              destination: destination,
            ),
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
      final deletedSkillIds = <String>{};
      var keptWorkspaceFolders = 0;
      for (final item in businessPlan) {
        if (item.action != SyncConvAction.iDelete) continue;
        final key = syncBusinessKey(item.kindWire, item.id);
        final outcome = await dataPlane.deleteBusinessRow(
          item.kindWire,
          item.id,
        );
        (outcome.removed ? deletedBusiness : failedBusinessDeletes).add(key);
        if (outcome.folderKept) keptWorkspaceFolders++;
        if (outcome.removed && item.kindWire == SyncDataPlane.skillWire) {
          deletedSkillIds.add(item.id);
        }
      }
      // A deletion writes through the repository, not through
      // BusinessPreferences, so the in-memory view the providers read has to be
      // refreshed here — the apply path only refreshes when it wrote something.
      if (deletedBusiness.isNotEmpty) await dataPlane.reloadBusiness();

      final next = await _advanceCheckpoint(
        myManifest: myManifest,
        previous: previous,
        plan: plan,
        skippedSends: skippedSends,
        missingIncoming: missingIncoming,
        outcomes: outcomes,
        deletedIds: deleted,
        failedDeletes: failedDeletes,
        peerDeferredConversations: peerDeferred,
        sentSubtrees: sentSubtrees,
      );
      final nextBusiness = await _advanceBusinessCheckpoint(
        previous: previous,
        plan: businessPlan,
        sentKeys: sentBusiness,
        receivedKeys: receivedBusiness,
        deletedKeys: deletedBusiness,
        failedDeleteKeys: failedBusinessDeletes,
        applyDeferred: businessOutcome.deferred,
        peerApplyDeferred: peerBusinessDeferred,
        // A skill whose body never landed was stripped on the peer, so the
        // push delivered nothing for it: keep the entry and re-send.
        peerDeferredSkillIds: peerDeferredSkills,
      );
      // Read back after every apply: on both sides the local hash *is* the
      // converged value once the exchange succeeded. A skill the peer deferred
      // keeps its previous baseline for the same reason its row does.
      final nextSkillHashes = await _advanceSkillHashes(
        previous: previous,
        plan: skillPlan,
        deferredSkills: {...deferredSkills, ...peerDeferredSkills},
        deletedSkills: deletedSkillIds,
        localHashes: await dataPlane.skillDirHashes(),
      );
      await store.saveCheckpoint(
        peer.deviceId,
        SyncCheckpoint(
          next.conversations,
          entities: nextBusiness.entities,
          preferences: nextBusiness.preferences,
          pendingBlobs: pulled.failed,
          skillHashes: nextSkillHashes,
          // What both sides now demonstrably hold of every workspace's files.
          // The content plan reads it next session, and it is the only thing
          // that lets a missing file be read as a deletion.
          workspaceFiles: workspaceOutcome.ledger,
          // What this device could not apply is owed to the peer as a report
          // on the next hello: it is the only way the peer can tell "never
          // delivered" from "deleted on the other device".
          unappliedConversations: [
            for (final entry in outcomes.entries)
              if (entry.value.deferred) entry.key,
          ],
          unappliedBusiness: businessOutcome.deferred,
          peerEpoch: peerHello.epoch,
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
          receivedBusiness: applicableBusiness,
          appliedBusiness: businessOutcome,
          blobPull: pulled,
          skillConflicts: adoptions.conflicts.length,
          deferredSkills: deferredSkills.length,
          workspace: workspaceOutcome,
          workspaceFoldersKept: keptWorkspaceFolders,
          workspacePushed: pushed.files,
          workspacePushedBytes: pushed.bytes,
          // The tables this device advertised are the ones it could have dropped
          // a shared workspace from: the peer then reads that workspace as "not
          // shared" and plans nothing, so this is where the silence has to be
          // counted.
          workspacesDroppedByCap: advertised.droppedWorkspaces,
          blobsPushed: pushedBlobs.blobs,
          blobBytesPushed: pushedBlobs.bytes,
          clockSkewMs: clockSkewMs,
        ),
        peer: peer,
        host: host,
        port: port,
      );
    } catch (error, stack) {
      // A round that yielded does not report: the socket it had is being torn
      // down under it, so every exception from here on is the consequence of
      // that decision, not evidence about the peer. Persisting one would put a
      // failure on the card for a session that is about to succeed elsewhere.
      if (round.cancelled) return null;
      // The machine summary stays for the logs; the card and the persisted
      // record get the classified reason instead, so no exception text (with
      // the peer's address) is ever rendered.
      debugPrint('sync: session with ${peer.deviceId} failed: $error\n$stack');
      return await _finish(
        SyncSessionReport(
          success: false,
          summary: 'error:$error',
          failure: _failureReason(error),
        ),
        peer: peer,
        host: host,
        port: port,
      );
    } finally {
      session.close();
      if (identical(round.session, session)) round.session = null;
      // The round is over, so the files it advertised for the peer are no longer
      // promised to anyone: the peer's own reverse pulls inside this round are
      // done by now (they run inside the push beat, before this device's fetch
      // beat), and a table that outlived the round would answer a later request
      // from a walk taken before the user switched the workspace off.
      dataPlane.clearWorkspacePublication(peer.deviceId);
      onStateChanged();
    }
  }

  // ---- responder role (SyncServerHandler) ----

  @override
  Future<Object> handleHello(
    String peerDeviceId,
    SyncHello initiatorHello, {
    String? remoteAddress,
  }) async {
    _sweepSessions();
    // A new session replaces the previous session's advertisement: it was
    // published *inside* that session and is not this one's promise. Cleared at
    // the hello rather than at the beat that published it, because the initiator
    // pulls the files this device advertised *after* the fetch response — a table
    // dropped when that response was written would 404 the very pull it exists
    // for.
    dataPlane.clearWorkspacePublication(peerDeviceId);
    // The authenticated identity is the only one this session may act as:
    // [peerDeviceId] is the device whose per-peer secret authenticated the
    // request, and a hello body naming some other paired device would
    // otherwise look up, plan against and store the session under that
    // device's checkpoint — substituting the caller's plan into the named
    // peer's next fetch beat and holding the single session slot under a
    // foreign name.
    if (initiatorHello.deviceId != peerDeviceId) {
      return const SyncHelloRefusal(
        SyncRefusalReason.identityMismatch,
        'The hello names a device other than the authenticated caller.',
      );
    }
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
    // This device is initiating to the caller right now. Answering would give
    // the pair two sessions, each advancing the same checkpoint file from the
    // copy it read, so the later write would discard the other's advance — but
    // only once the local round is a *session*. A round that has not heard the
    // peer's hello has proved nothing, while this hello just proved the peer
    // reaches this device: on a LAN that only works one way, refusing it made
    // both devices fail forever while the reachable direction sat idle (the
    // local dial times out, and every retry collides with the same refusal).
    // The arriving hello therefore wins over a round that is still dialing, and
    // the local round is cancelled before this handler awaits anything. The
    // session this builds is then a *yielded* one: it is a bet that the peer's
    // own client is still there to drive it, which is why one that is never
    // touched is dropped again (see [kYieldedSessionTtl]).
    final round = _initiatorRounds[initiatorHello.deviceId];
    final yielded = round != null && !round.answered;
    if (round != null) {
      if (round.answered) {
        return const SyncHelloRefusal(
          SyncRefusalReason.busy,
          'This device is already syncing with you.',
        );
      }
      round.cancel();
    }

    final myManifest = await dataPlane.buildManifest();
    final checkpoint = await store.loadCheckpoint(initiatorHello.deviceId);
    final myClockUs = clockUs();
    final myEpoch = await store.readDataEpoch();
    // What the initiator reports it could not apply decides whether its silence
    // about a conversation or a business row means "deleted there" or "never
    // arrived there".
    final peerUnapplied = initiatorHello.unappliedConversations.toSet();
    // A different epoch means the caller's database was bulk-replaced: its
    // missing rows were dropped, not deleted, so none of its absences may
    // justify a deletion here.
    final peerReplaced = initiatorHello.epoch != checkpoint.peerEpoch;
    var plan = _applyDeletionAnnouncements(
      _reSendUnapplied(
        planSync(
          mine: myManifest,
          peers: initiatorHello.manifest,
          checkpoint: checkpoint,
        ),
        peerUnapplied,
      ),
      initiatorHello.deletedConversations,
      myManifest,
    );
    var businessPlan = _keepRowsPeerMayNeverHaveSeen(
      planBusinessSync(
        mine: myManifest,
        peers: initiatorHello.manifest,
        checkpoint: checkpoint,
      ),
      initiatorHello.unappliedBusiness,
    );
    if (peerReplaced) {
      plan = _reSendInsteadOfDelete(plan);
      businessPlan = _keepInsteadOfDelete(businessPlan);
    }
    final session = _ResponderSession(
      initiatorHello: initiatorHello,
      plan: plan,
      businessPlan: businessPlan,
      skillPlan: planSkillContentSync(
        mine: myManifest,
        peers: initiatorHello.manifest,
        checkpoint: checkpoint,
        skillWire: SyncDataPlane.skillWire,
      ),
      myManifest: myManifest,
      checkpoint: checkpoint,
      startedAt: now(),
      myHosts: _myHosts,
      initiatorHost: remoteAddress,
      clockSkewMs: _clockSkewMs(myClockUs, initiatorHello.clockUs),
      peerReplaced: peerReplaced,
      yielded: yielded,
    );
    _sessions[initiatorHello.deviceId] = session;
    _assertSessionInvariants();
    return SyncHello(
      protocolVersion: kSyncProtocolVersion,
      schemaVersion: dataPlane.schemaVersion,
      deviceId: identity.deviceId,
      deviceName: identity.name,
      platform: platformTag(),
      manifest: myManifest,
      listenPort: port,
      clockUs: myClockUs,
      // The responder answers with the same report: it too may have deferred
      // an apply, and the initiator needs it before it plans.
      unappliedConversations: checkpoint.unappliedConversations,
      unappliedBusiness: checkpoint.unappliedBusiness,
      deletedConversations: _deletionsToAnnounce(checkpoint, myManifest),
      epoch: myEpoch,
    );
  }

  @override
  Future<SyncApplyAck> handleApplySubtrees(
    String peerDeviceId,
    SyncDeltaBatch batch,
  ) async {
    final session = _sessions[peerDeviceId];
    if (session == null) throw const SyncRequestRefusal.sessionMissing();
    // One push, one fetch — the half of the rule the fetch beat enforces from
    // the other side (see [SyncRequestRefusal.pushRequired]). This beat writes
    // the session's whole outcome (`workspaceOutcome`, `blobPull`,
    // `receivedBusiness`, its apply) and the fetch beat reads it, while the
    // counters a later landing books into keep accumulating: a replayed push
    // would replace the outcome the report is built from and still count its
    // bytes a second time.
    if (session.pushSeen) throw const SyncRequestRefusal.pushAlreadyTaken();
    // The peer's client is alive and pushing: a session this device accepted by
    // yielding its own dial is no longer a bet (see [kYieldedSessionTtl]), and a
    // beat in flight means the idle sweep must leave this session alone however
    // long it runs.
    _beginBeat(session);
    try {
      return await _applyPushedBatch(peerDeviceId, session, batch);
    } finally {
      _endBeat(session);
      _assertSessionInvariants();
    }
  }

  Future<SyncApplyAck> _applyPushedBatch(
    String peerDeviceId,
    _ResponderSession session,
    SyncDeltaBatch batch,
  ) async {
    // The fetch beat answers the same peer on the same session, and it reads the
    // ledger this beat produces. Marked before any await, so a fetch that
    // arrives while the push is still running is refused rather than answered
    // from a half-written session.
    session.pushSeen = true;
    _rememberPublished(batch.assets);

    // Blob beat, responder side. The initiator pushed rows before the fetch
    // beat, so anything those rows reference has to arrive now — and the only
    // way here is back over the initiator's own listener, which its hello
    // advertised. A missing endpoint or a refused connection is not fatal:
    // the blobs go pending and the rows still apply (a skill record waits).
    final mySkillHashes = await dataPlane.skillDirHashes();
    final adoptions = _planSkillAdoptions(
      plan: session.skillPlan,
      mine: session.myManifest,
      peers: session.initiatorHello.manifest,
      peerSkillHashes: batch.skillHashes,
      mySkillHashes: mySkillHashes,
      myDeviceId: identity.deviceId,
      peerDeviceId: peerDeviceId,
    );
    final neededAssets = await dataPlane.neededFileBlobs(batch.assets);
    final wanted = _foldBlobWanted([
      ...neededAssets,
      ...adoptions.wanted,
    ], session.checkpoint.pendingBlobs.values);
    // One reverse connection for the whole beat: the blobs the pushed rows
    // reference and the workspace files the push advertised both have to come
    // back over the initiator's own listener, and a peer that cannot be dialed
    // back is one answer, not two failures to diagnose separately.
    final reverse = await _openReverseConnection(peerDeviceId, session);
    // This batch's per-conversation outcomes, declared outside the connection's
    // lifetime: the acknowledgement below is built after it closes, and what
    // this beat reports must not depend on when a socket went away.
    var outcomes = const <String, SyncSubtreeApplyOutcome>{};
    try {
      session.blobPull = reverse == null
          ? _unreachableBlobPull(wanted.values.toList())
          : await _pullBlobs(wanted.values.toList(), reverse);
      session.deferredSkills = {
        ...adoptions.deferred,
        for (final id in adoptions.wantedSkillIds)
          if (!session.blobPull.landedSkillIds.contains(id)) id,
      };
      session.skillConflicts = adoptions.conflicts;

      outcomes = await dataPlane.applySubtrees(
        batch.subtrees,
        myDeviceId: identity.deviceId,
        peerDeviceId: peerDeviceId,
        checkpointRowsByConversation: _rowsOf(
          session.checkpoint,
          // A replaced caller's absences prove nothing about this device's rows.
          session.peerReplaced
              ? const <String>{}
              : {
                  for (final subtree in batch.subtrees)
                    subtree.conversation['id'] as String,
                },
          // Same protection as on the initiator's side: a conversation the
          // caller said it could not apply proves nothing about the caller's
          // rows.
          unconfirmed: session.initiatorHello.unappliedConversations.toSet(),
        ),
      );
      session.outcomes.addAll(outcomes);
      // Same rule as the initiator's side: the advertisement (not the pull
      // outcome) owns the reference set, scoped to revisions this apply wrote.
      await dataPlane.registerLandedAssets(
        subtrees: batch.subtrees,
        outcomes: outcomes,
        advertisedByUri: {for (final entry in batch.assets) entry.key: entry},
      );
      // Business rows arrive in the same push; the responder's own plan already
      // decided what it needs from the initiator, so this is purely an apply.
      // One push per session, so the payload is kept as-is for the checkpoint
      // and the report.
      final applicable = dataPlane.withoutSkillRows(
        batch.business,
        session.deferredSkills,
      );
      // Kept un-stripped beside it: a skill body the initiator pushes after the
      // acknowledgement arrives with its record already filtered out here, and
      // the push has to be able to put it back (slice 24).
      session.pushedBusiness = batch.business;
      session.receivedBusiness = applicable;
      session.businessOutcome = await dataPlane.applyBusiness(
        applicable,
        myDeviceId: identity.deviceId,
        peerDeviceId: peerDeviceId,
      );
      if (session.blobPull.landedSkillIds.isNotEmpty) {
        await dataPlane.reloadBusiness();
      }

      // Workspace files (slice 18), this side of the push beat. The walk runs
      // after the business apply because a workspace record that just arrived
      // is what makes its folder this device's to populate — and its index is
      // then empty, which is exactly what tells the plan to fetch everything
      // the caller advertised.
      final myWorkspaceSnapshots = await dataPlane.workspaceSnapshots();
      session.workspaceOutcome = await dataPlane.applyWorkspaceContent(
        myDeviceId: identity.deviceId,
        peerDeviceId: peerDeviceId,
        mine: myWorkspaceSnapshots,
        peerTables: batch.workspaceFiles,
        ledger: session.checkpoint.workspaceFiles,
        allowDeletes: !session.peerReplaced,
        fetch: reverse == null
            ? null
            : (workspaceId, relPath, destination) => reverse.fetchWorkspaceFile(
                workspaceId: workspaceId,
                relPath: relPath,
                destination: destination,
              ),
      );
      // Whatever this beat could not land becomes the ask the initiator answers
      // before its fetch beat (slice 23). Every pair named here was advertised
      // in `batch`, so this set is exactly, and only, the writes this session
      // may accept — see [handlePutWorkspaceFile].
      session.workspaceRequests.addAll({
        for (final workspace in session.workspaceOutcome!.unlanded.entries)
          for (final file in workspace.value.entries)
            WorkspaceContentSync.serveKey(
              workspace.key,
              file.key,
            ): SyncWorkspaceFileRequest(
              workspaceId: workspace.key,
              relPath: file.key,
              stamp: file.value,
            ),
      });
      // Which of those requests, if they land, will *replace a local edit*
      // (`peerWins`). Only the plan knows — the request carries the version, not
      // the action — and the landing is the moment the edit is actually lost, so
      // the set is kept until then and the report counts what landed.
      session.workspaceReplacements.addAll(
        session.workspaceOutcome!.replacedUnlanded,
      );
    } finally {
      reverse?.close();
    }
    // The acknowledgement the initiator's checkpoint advance needs: which
    // conversations were accepted but not applied, whether the business
    // apply as a whole was deferred, and which skill records were stripped
    // because their body did not land.
    final deferredSkills = {
      for (final row
          in batch.business.entities[SyncDataPlane.skillWire] ?? const [])
        if (row['id'] is String &&
            session.deferredSkills.contains(row['id'] as String))
          row['id'] as String,
    };
    // Everything this beat planned and could not land becomes the ask the
    // initiator answers over the connection it already holds (slice 24). The
    // set is built from the manifest the initiator itself sent — or asked for in
    // an earlier session and still owes — so it is exactly, and only, the blobs
    // this session may accept. See [handlePutBlob].
    session.blobRequests.addAll({
      for (final entry in session.blobPull.failed.values) entry.target: entry,
    });
    return SyncApplyAck(
      applied: outcomes.length,
      deferred: {
        for (final entry in outcomes.entries)
          if (entry.value.deferred) entry.key,
      },
      businessDeferred: session.businessOutcome?.deferred ?? false,
      deferredSkills: deferredSkills,
      // Files this side wanted and could not take: the initiator pushes them
      // over the connection it already holds, which is the direction that is
      // known to work.
      workspaceRequests: session.workspaceRequests.values.toList(
        growable: false,
      ),
      // The same for blobs, which is what carries a message's images to the
      // side that cannot be dialled back.
      blobRequests: session.blobRequests.values.toList(growable: false),
    );
  }

  /// Opens the connection back to the initiator over its own listener — the only
  /// route to a peer that dialed this device — or null when none of the
  /// addresses this pair knows answers.
  ///
  /// One connection for the whole beat on purpose: the blobs the pushed rows
  /// reference and the workspace files the push advertised are fetched in the
  /// same stretch of time, and opening two sockets to answer "is the peer
  /// dialable back?" would pay the same failure twice.
  ///
  /// Each candidate is *pinged* before it is used, because opening a session is
  /// lazy — nothing connects until the first request — so a session object is
  /// not evidence that the peer is there, and the old single-address version
  /// could not tell "the peer is not reachable" from "the peer refused this
  /// file" at all.
  Future<SyncClientSession?> _openReverseConnection(
    String peerDeviceId,
    _ResponderSession session,
  ) async {
    final port = session.initiatorHello.listenPort;
    if (port == null) return null;
    final peer = await store.findPeer(peerDeviceId);
    if (peer == null) return null;
    for (final (host, candidatePort) in _reverseDialCandidates(session, peer)) {
      final opened = client.openSession(peer, host: host, port: candidatePort);
      try {
        await opened.ping();
        return opened;
      } catch (error) {
        debugPrint('sync: dialling back $host:$candidatePort failed: $error');
        opened.close();
      }
    }
    return null;
  }

  /// The addresses this device may dial the initiator back on, in the order they
  /// are tried and capped at [kMaxReverseDialCandidates].
  ///
  /// The address the caller connected from comes first: on an ordinary LAN it is
  /// the best evidence there is, because it is where the peer demonstrably
  /// reaches out from. It is *not* always the peer's own address — a NAT rewrite
  /// can make it this device's own, which is what the fallbacks are for: the
  /// addresses the peer advertised in its hello, then the ones this pair
  /// remembers. A candidate that is this device's own listener is left in the
  /// list rather than filtered: the ping that follows refuses it in
  /// milliseconds (the certificate pin cannot match), and filtering needs a
  /// port comparison that a same-machine peer at a different port would fail.
  List<(String, int)> _reverseDialCandidates(
    _ResponderSession session,
    SyncPeerRecord peer,
  ) {
    final port = session.initiatorHello.listenPort;
    if (port == null) return const [];
    final candidates = <(String, int)>[];
    final seen = <String>{};
    void add(String? host) {
      if (host == null || host.isEmpty) return;
      if (candidates.length >= kMaxReverseDialCandidates) return;
      final normalized = normalizeHost(host);
      if (!seen.add(normalized)) return;
      candidates.add((normalized, port));
    }

    add(session.initiatorHost);
    for (final host in session.initiatorHello.candidateHosts) {
      add(host);
    }
    for (final endpoint in peer.endpoints) {
      add(endpoint.host);
    }
    return candidates;
  }

  /// This device's own addresses, in the canonical form every layer stores.
  ///
  /// Read from [localAddresses], which the provider keeps current, rather than
  /// enumerated here: the engine has no business opening the network interface
  /// list mid-session, and the provider already does it for the pairing screen.
  ///
  /// It is the fact that separates "the peer is here" from "a NAT rewrote the
  /// peer's source to this device", and both an endpoint being remembered and a
  /// dial being attempted need that answer. Loopback is deliberately *not* in this
  /// set — the enumeration drops it, and it must: another instance of this app on
  /// this machine is a legitimate peer at 127.0.0.1.
  Set<String> get _myHosts => {
    for (final address in localAddresses) normalizeHost(address.address),
  };

  /// Everything a peer owes this device when it cannot be dialed back: every
  /// wanted blob stays pending (the rows still apply — a conversation is still
  /// a conversation without its picture), and no workspace file can move,
  /// which the content plan records by keeping every ledger entry.
  _BlobPullOutcome _unreachableBlobPull(List<SyncBlobEntry> wanted) {
    final outcome = _BlobPullOutcome();
    for (final entry in wanted) {
      outcome.failed[entry.target] = entry;
    }
    return outcome;
  }

  @override
  Future<SyncDeltaBatch> handleFetchSubtrees(
    String peerDeviceId,
    SyncFetchRequest request,
  ) async {
    final session = _sessions[peerDeviceId];
    if (session == null) throw const SyncRequestRefusal.sessionMissing();
    // The fetch beat is the second half of one push: the initiator pushes, then
    // asks for what it lacks. A fetch that arrives first is not a session, and
    // answering it would persist a checkpoint built on nothing — the responder's
    // workspace ledger is produced by the push, so this beat would write an empty
    // one, and the next session would read "we never agreed about these files"
    // and re-transfer, or read a file that was deleted here as one the peer never
    // had.
    if (!session.pushSeen) throw const SyncRequestRefusal.pushRequired();
    _beginBeat(session);
    try {
      return await _serveFetchSubtrees(peerDeviceId, session, request);
    } finally {
      _endBeat(session);
      _assertSessionInvariants();
    }
  }

  Future<SyncDeltaBatch> _serveFetchSubtrees(
    String peerDeviceId,
    _ResponderSession session,
    SyncFetchRequest request,
  ) async {
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
    final deletedSkillIds = <String>{};
    var keptWorkspaceFolders = 0;
    for (final item in session.businessPlan) {
      if (item.action != SyncConvAction.iDelete) continue;
      final key = syncBusinessKey(item.kindWire, item.id);
      final outcome = await dataPlane.deleteBusinessRow(item.kindWire, item.id);
      (outcome.removed ? deletedBusiness : failedBusinessDeletes).add(key);
      if (outcome.folderKept) keptWorkspaceFolders++;
      if (outcome.removed && item.kindWire == SyncDataPlane.skillWire) {
        deletedSkillIds.add(item.id);
      }
    }
    // Deletions bypass BusinessPreferences, so refresh the in-memory view the
    // providers read; the apply above only refreshes when it wrote a row.
    if (deletedBusiness.isNotEmpty) await dataPlane.reloadBusiness();

    final next = await _advanceCheckpoint(
      myManifest: session.myManifest,
      previous: session.checkpoint,
      plan: session.plan,
      skippedSends: skipped,
      missingIncoming: missing,
      outcomes: session.outcomes,
      deletedIds: deleted,
      failedDeletes: failedDeletes,
      // The initiator's report covers its own deferred applies, which must not
      // advance unconfirmed state here either.
      peerDeferredConversations: session.initiatorHello.unappliedConversations
          .toSet(),
      // The fetch response is never acknowledged, so a conversation this beat
      // sends back is not state the peer holds. Advancing it would make the
      // next session read the peer's missing copy as a deletion and destroy
      // the only remaining one; the entry appears one session later, when both
      // manifests agree (`none`).
      sendsConfirmed: false,
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
      peerApplyDeferred: session.initiatorHello.unappliedBusiness,
      // The fetch response is not acknowledged: this beat's sends stay
      // unconfirmed and are healed by `none` once the peer's manifest shows
      // them.
      sendsConfirmed: false,
    );
    final skillHashes = await _advanceSkillHashes(
      previous: session.checkpoint,
      plan: session.skillPlan,
      deferredSkills: session.deferredSkills,
      deletedSkills: deletedSkillIds,
      localHashes: await dataPlane.skillDirHashes(),
    );
    // The response batch carries this side's blob manifest for exactly what it
    // is sending, so the initiator can pull the same way this device just did.
    final responseAssets = await dataPlane.buildBlobManifest(
      subtrees: outgoing,
      business: businessRead.payload,
    );
    _rememberPublished(responseAssets);
    final sentSkillIds = {
      for (final row
          in businessRead.payload.entities[SyncDataPlane.skillWire] ?? const [])
        if (row['id'] is String) row['id'] as String,
    };
    final mySkillHashes = await dataPlane.skillDirHashes();
    // Workspace content, this side of the fetch beat (slice 18). The walk is
    // fresh here — after the push beat's own transfers landed — because this
    // table is what tells the initiator what this device now holds: a stale one
    // would leave its ledger permanently behind, and it would re-offer the same
    // files every session.
    final myWorkspaceSnapshots = await dataPlane.workspaceSnapshots();
    dataPlane.publishWorkspaceContent(peerDeviceId, myWorkspaceSnapshots);
    final advertised = dataPlane.workspaceTables(myWorkspaceSnapshots);
    final responseBatch = SyncDeltaBatch(
      outgoing,
      business: businessRead.payload,
      assets: responseAssets,
      skillHashes: {
        for (final id in sentSkillIds)
          if (mySkillHashes[id] != null) id: mySkillHashes[id]!,
      },
      workspaceFiles: advertised.tables,
    );
    await store.saveCheckpoint(
      peerDeviceId,
      SyncCheckpoint(
        next.conversations,
        entities: nextBusiness.entities,
        preferences: nextBusiness.preferences,
        pendingBlobs: session.blobPull.failed,
        skillHashes: skillHashes,
        // What this session's file plane demonstrably agreed, finalised here
        // because this beat is the last place every transfer is known: the push
        // beat's ledger, plus every file the initiator pushed after it could not
        // be fetched (slice 23).
        //
        // The rule is that the side which *lands* a file advances its entry —
        // not the side that sends it, which cannot know whether its bytes
        // arrived, and not the beat that ran before the file existed.
        //
        // The push is the only producer of the ledger's base, and this beat is
        // refused without it (`push_required`), so the outcome is not optional:
        // `?? const {}` here would erase everything both sides had agreed — the
        // review's second finding — and an empty ledger reads as "never agreed",
        // not as "nothing to say".
        workspaceFiles: _finalWorkspaceLedger(session),
        // The responder answers the initiator with the same report on its next
        // hello: an apply it deferred here must not read as a deletion there.
        unappliedConversations: [
          for (final entry in session.outcomes.entries)
            if (entry.value.deferred) entry.key,
        ],
        unappliedBusiness: session.businessOutcome?.deferred ?? false,
        peerEpoch: session.initiatorHello.epoch,
      ),
    );
    final report = _report(
      sent: outgoing.length,
      received: session.outcomes.length,
      outcomes: session.outcomes.values,
      deferred: skipped.length + missing.length,
      deletedLocally: deleted.length,
      business: businessRead.payload,
      receivedBusiness: session.receivedBusiness,
      appliedBusiness: session.businessOutcome,
      blobPull: session.blobPull,
      skillConflicts: session.skillConflicts.length,
      deferredSkills: session.deferredSkills.length,
      workspace: session.workspaceOutcome,
      workspaceFoldersKept: keptWorkspaceFolders,
      workspacePushed: session.pushedFiles,
      workspacePushedBytes: session.pushedBytes,
      // The responder is the side that can record a miss and then watch a push
      // repair it; the initiator's own misses are never repaired this way.
      workspaceMissesRepaired: session.pushedFiles,
      // The `peerWins` replacements this beat's pushes actually performed: the
      // fetch's own counter never saw them arrive.
      workspaceReplacements: session.pushedReplacements,
      workspacesDroppedByCap: advertised.droppedWorkspaces,
      clockSkewMs: session.clockSkewMs,
    );
    // Merged into the record as it stands now, not written onto the copy read
    // before this beat ran: the panel may have renamed the peer while the push
    // was in flight, and a whole-record write would drop it.
    final peer = await store.mutatePeer(peerDeviceId, (current) {
      current.lastSyncedAt = DateTime.now();
      // The session just ran over the caller's address, so that is where this
      // network reaches it: refresh the memory (and promote it), which is what
      // lets a peer that roamed keep syncing without a re-scan.
      //
      // Unless that address is one of this device's own: a NAT rewrites the
      // source of the caller's connection to whoever forwards it, and the Android
      // emulator's user-mode network rewrites it to the host — so what arrived
      // here as "where the peer connected from" was this machine's own LAN
      // address. Remembering it would put an address in the panel that dials this
      // device itself, and promote it over addresses that might actually work.
      final learnedHost = session.initiatorHost;
      final learnedPort = session.initiatorHello.listenPort;
      if (learnedHost != null &&
          learnedPort != null &&
          !session.myHosts.contains(normalizeHost(learnedHost))) {
        current.noteEndpointSuccess(learnedHost, learnedPort);
      }
      current.lastReport = report.toPeerReport();
      return true;
    });
    _sessions.remove(peerDeviceId);
    onStateChanged();
    if (peer != null) {
      onResponderSession?.call(peer, report);
    }
    return responseBatch;
  }

  @override
  Future<SyncPairAnswer?> handlePair(
    SyncPairRequest request,
    String? initiatorHost,
  ) async {
    if (!isPairingOpen) return null;
    if (request.pin != _pairingPin) {
      // A 6-digit PIN is brute-forceable inside the window unless wrong
      // guesses cost something: five of them close the window (reopening
      // resets the counter and mints a fresh PIN).
      if (++_pairingFailures >= 5) {
        _pairingPin = null;
        _pairingExpiresAt = null;
        onStateChanged();
      }
      return null;
    }
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
    );
    // Same carry-over as the initiator's side: this responder may hold the
    // older (and richer) record of the pair.
    final existing = await store.findPeer(request.deviceId);
    _carryPairingFacts(peer, existing);
    // A source address of this device is not where the peer is: a NAT — the
    // Android emulator's user-mode network included — rewrites the caller's
    // source to whoever forwards it. Read once, for the address and for the
    // candidates below.
    final myHosts = _myHosts;
    // The endpoint that demonstrably works: where the initiator connected from,
    // paired with the listener port it advertised. Null when the initiator had
    // no listener running; the address can be fixed by hand.
    if (initiatorHost != null &&
        request.listenPort != null &&
        !myHosts.contains(normalizeHost(initiatorHost))) {
      peer.noteEndpointSuccess(initiatorHost, request.listenPort!);
    }
    // Its other addresses are hints only: they have not answered anything here.
    // One that is this device's own is not a hint at all — the peer that
    // advertised it was describing the network it reached this device through,
    // and remembering it would only offer the panel an address that dials this
    // device itself.
    if (request.listenPort != null) {
      peer.rememberEndpointCandidates([
        for (final host in request.candidateHosts)
          if (!myHosts.contains(normalizeHost(host)))
            (host, request.listenPort!),
      ]);
    }
    // And the networks this pair already met, behind the fresh ones — the
    // responder's half of the memory the initiator keeps (see [pairWith]).
    if (existing != null) peer.rememberEndpointHistory(existing.endpoints);
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
  /// undelivered fetches, deferred applies — this device's own and, per the
  /// push acknowledgement, the peer's — and a peer deletion the peer reported
  /// as failed all keep the previous entry so the next session retries them.
  ///
  /// [peerDeferredConversations] are the conversations the peer accepted but
  /// did not apply; without it "sent" would be indistinguishable from
  /// "received" and the next session would read the peer's older copy as a
  /// deletion of the rows this device had just written.
  ///
  /// [sentSubtrees] is the push payload as it was read. An `iSend` entry is
  /// built from it rather than from a fresh local read, so the entry describes
  /// what actually crossed the wire — a row written while the session was in
  /// flight was never sent, and recording it as peer-seen would make the next
  /// merge delete it here.
  ///
  /// [sendsConfirmed] is false for the responder's fetch beat, whose response
  /// is never acknowledged: a conversation this device *sent* back is not
  /// state the peer holds, and advancing it would make the next session read
  /// the peer's silence as a deletion. Such an entry is created by [none] one
  /// session later, when the peer's manifest confirms the transfer.
  Future<SyncCheckpoint> _advanceCheckpoint({
    required SyncManifest myManifest,
    required SyncCheckpoint previous,
    required List<SyncConvPlan> plan,
    required Set<String> skippedSends,
    required Set<String> missingIncoming,
    required Map<String, SyncSubtreeApplyOutcome> outcomes,
    required Set<String> deletedIds,
    required Set<String> failedDeletes,
    Set<String> peerDeferredConversations = const {},
    Map<String, SyncSubtreePayload> sentSubtrees = const {},
    bool sendsConfirmed = true,
  }) async {
    final next = <String, SyncCheckpointConversation>{};
    for (final item in plan) {
      final id = item.conversationId;
      final prior = previous.conversations[id];
      switch (item.action) {
        case SyncConvAction.none:
          // Both manifests agree, so local state *is* the shared state: the
          // entry is refreshed rather than kept, healing a stale entry an
          // interrupted session left behind before it can misread a peer
          // deletion as a local edit. The business face has always refreshed
          // here (setFromLocal); this aligns the conversation face with it.
          //
          // The manifest already carries the same digest and row clock, and
          // both are computed from the same rows this refresh would read: when
          // they match the entry, re-reading every message of every settled
          // conversation would rebuild exactly the entry already in hand.
          final mine = myManifest.conversations[id];
          if (prior != null &&
              mine != null &&
              prior.digest == mine.digest &&
              prior.updatedAtUs == mine.updatedAtUs) {
            next[id] = prior;
            break;
          }
          final entry = await dataPlane.checkpointFromLocal(id);
          if (entry != null) {
            next[id] = entry;
          } else if (prior != null) {
            next[id] = prior;
          }
        case SyncConvAction.iSend:
          if (!sendsConfirmed ||
              skippedSends.contains(id) ||
              peerDeferredConversations.contains(id)) {
            if (prior != null) next[id] = prior;
          } else {
            final sent = sentSubtrees[id];
            if (sent != null) {
              next[id] = buildCheckpointConversation(
                conversationRow: sent.conversation,
                messageRows: sent.messages,
              );
            } else if (prior != null) {
              next[id] = prior;
            }
          }
        case SyncConvAction.peerSends:
        case SyncConvAction.bothSend:
          final outcome = outcomes[id];
          if (outcome == null ||
              outcome.deferred ||
              peerDeferredConversations.contains(id)) {
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
          // The peer still holds it and must delete it. The entry must not
          // drop yet: with no entry the next session reads "a conversation
          // the peer has and this device never had" and downloads it back, so
          // a deletion the peer deferred (a generation was writing there)
          // would resurrect the subtree. It is dropped by `bothDeleted`, on
          // the session where the peer's manifest has caught up.
          if (prior != null) next[id] = prior;
        case SyncConvAction.bothDeleted:
          break; // entry drops: neither side has the conversation any more
      }
    }
    return SyncCheckpoint(next);
  }

  /// The peer-observed row state for the conversations in [conversationIds],
  /// which is what the merge's deletion oracle reads. Ids in [unconfirmed] are
  /// left out: the peer reported that its apply of them never happened, so its
  /// copy proves nothing about rows this device holds on top of it.
  Map<String, Map<String, int>> _rowsOf(
    SyncCheckpoint checkpoint,
    Set<String> conversationIds, {
    Set<String> unconfirmed = const {},
  }) => {
    for (final id in conversationIds)
      if (!unconfirmed.contains(id) && checkpoint.conversations[id] != null)
        id: checkpoint.conversations[id]!.rows,
  };

  /// Conversations the peer reported it could not apply. Its copy of them is
  /// stale or missing, so this device re-sends: the alternative reading (the
  /// peer deleted them) would lose rows the peer never received.
  static List<SyncConvPlan> _reSendUnapplied(
    List<SyncConvPlan> plan,
    Set<String> peerUnapplied,
  ) {
    if (peerUnapplied.isEmpty) return plan;
    return [
      for (final item in plan)
        peerUnapplied.contains(item.conversationId)
            ? SyncConvPlan(item.conversationId, SyncConvAction.iSend)
            : item,
    ];
  }

  /// Deletions to announce on this hello: conversations this device still has a
  /// shared-history record for (it and the peer reached that state) but no
  /// longer carries, with the state both sides agreed on — the digest *and* the
  /// conversation row's clock.
  ///
  /// The alternative — letting the peer infer the deletion from this device's
  /// absent manifest — cannot tell a deletion from a transfer the peer never
  /// confirmed, which is exactly what the fetch-beat rule stopped claiming. The
  /// entry stops being announced once the peer's manifest drops it too.
  static Map<String, SyncAnnouncedDeletion> _deletionsToAnnounce(
    SyncCheckpoint checkpoint,
    SyncManifest manifest,
  ) => {
    for (final entry in checkpoint.conversations.entries)
      if (!manifest.conversations.containsKey(entry.key))
        entry.key: SyncAnnouncedDeletion(
          digest: entry.value.digest,
          updatedAtUs: entry.value.updatedAtUs,
        ),
  };

  /// Applies the peer's announced deletions. A local copy the peer still
  /// remembers as it was is a copy the peer really deleted; a copy that differs
  /// — in its messages or in the conversation row's clock — was written here
  /// since, and an edit beats a delete exactly as it does in the plan table.
  ///
  /// The clock is what makes a restore from the recycle bin an edit: the bin
  /// writes the row back with `now()` while the messages come back identical, so
  /// the digest cannot tell the restored copy from the deleted one and only the
  /// row clock can (protocol v8). The comparison is `<=` rather than `!=` on
  /// purpose: deleting too much is recoverable (the copy is staged into the bin
  /// again), while keeping too much resurrects content the peer's user deleted.
  static List<SyncConvPlan> _applyDeletionAnnouncements(
    List<SyncConvPlan> plan,
    Map<String, SyncAnnouncedDeletion> announced,
    SyncManifest mine,
  ) {
    if (announced.isEmpty) return plan;
    return [
      for (final item in plan)
        _announcementKills(
              announced[item.conversationId],
              mine.conversations[item.conversationId],
            )
            ? SyncConvPlan(item.conversationId, SyncConvAction.iDelete)
            : item,
    ];
  }

  /// Whether the peer's announced deletion still describes this device's copy.
  ///
  /// The same question the plan's delete branch asks, so the same function
  /// answers it ([copyWrittenSinceAgreement]): a copy with an identical digest
  /// and a row clock no newer than the announcement is the copy the peer
  /// deleted. The comparison is `<=` rather than `!=` on purpose: deleting too
  /// much is recoverable (the copy is staged into the bin again), while keeping
  /// too much resurrects content the peer's user deleted.
  ///
  /// An announcement without a clock is the v7 shape: the version gate refuses
  /// such a pair, and if one ever slipped through the digest alone is the old —
  /// narrower — rule rather than a wrong one.
  static bool _announcementKills(
    SyncAnnouncedDeletion? announced,
    SyncManifestEntry? mine,
  ) {
    if (announced == null || mine == null) return false;
    return !copyWrittenSinceAgreement(
      digest: mine.digest,
      agreedDigest: announced.digest,
      clock: mine.updatedAtUs,
      agreedClock: announced.updatedAtUs,
    );
  }

  /// Business rows a peer's deferred apply makes ambiguous. A row that peer
  /// lacks may have been deleted there or may simply never have arrived (a
  /// restore held its write fence), and only the second reading is safe: the
  /// row stays here, and the peer requests it in its own plan.
  static List<SyncBusinessPlanItem> _keepRowsPeerMayNeverHaveSeen(
    List<SyncBusinessPlanItem> plan,
    bool peerUnappliedBusiness,
  ) {
    if (!peerUnappliedBusiness) return plan;
    return [
      for (final item in plan)
        item.action == SyncConvAction.iDelete
            ? SyncBusinessPlanItem(item.kindWire, item.id, SyncConvAction.none)
            : item,
    ];
  }

  /// A peer whose database was bulk-replaced lost rows that were never deleted,
  /// so nothing it lacks may make this device delete its own copy. Deleting to
  /// match the peer becomes re-sending to restore it; a deletion this device
  /// made itself is unaffected, because that plans `peerDeletes` (carried to
  /// the peer by the announcement), not `iDelete`.
  static List<SyncConvPlan> _reSendInsteadOfDelete(List<SyncConvPlan> plan) {
    if (!plan.any((item) => item.action == SyncConvAction.iDelete)) return plan;
    return [
      for (final item in plan)
        item.action == SyncConvAction.iDelete
            ? SyncConvPlan(item.conversationId, SyncConvAction.iSend)
            : item,
    ];
  }

  /// The business face of [_reSendInsteadOfDelete].
  static List<SyncBusinessPlanItem> _keepInsteadOfDelete(
    List<SyncBusinessPlanItem> plan,
  ) {
    if (!plan.any((item) => item.action == SyncConvAction.iDelete)) return plan;
    return [
      for (final item in plan)
        item.action == SyncConvAction.iDelete
            ? SyncBusinessPlanItem(item.kindWire, item.id, SyncConvAction.iSend)
            : item,
    ];
  }

  /// Advances the business half of the checkpoint. The rule mirrors
  /// conversations: an entry moves to the current shared state (read back from
  /// local, which *is* the shared state once the exchange succeeded) only when
  /// both sides demonstrably reached it; anything skipped, undelivered or
  /// deferred — here or, per the push acknowledgement, on the peer — keeps its
  /// previous entry so the next session retries it. A row gone on both sides
  /// drops its entry.
  Future<SyncCheckpoint> _advanceBusinessCheckpoint({
    required SyncCheckpoint previous,
    required List<SyncBusinessPlanItem> plan,
    required Set<String> sentKeys,
    required Set<String> receivedKeys,
    required Set<String> deletedKeys,
    required Set<String> failedDeleteKeys,
    required bool applyDeferred,
    bool peerApplyDeferred = false,
    bool sendsConfirmed = true,
    Set<String> peerDeferredSkillIds = const {},
  }) async {
    // A skill the peer stripped (its body never landed) delivered nothing, so
    // its row must keep the previous entry exactly as a deferred apply does.
    final peerDeferredKeys = {
      for (final id in peerDeferredSkillIds)
        syncBusinessKey(SyncDataPlane.skillWire, id),
    };
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
          if (sendsConfirmed &&
              sentKeys.contains(key) &&
              !peerApplyDeferred &&
              !peerDeferredKeys.contains(key)) {
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
              peerApplyDeferred ||
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

  // ---- blobs (slice 3) ----

  /// Advances the per-peer skill-content baseline. The rule is the row rule
  /// applied to bodies: a skill the session resolved converges on the local
  /// hash (which *is* the shared value once the exchange succeeded), a deleted
  /// skill drops its entry, and a deferred body keeps the previous baseline so
  /// the next session re-plans it.
  Future<Map<String, String>> _advanceSkillHashes({
    required SyncCheckpoint previous,
    required List<SkillContentPlan> plan,
    required Set<String> deferredSkills,
    required Set<String> deletedSkills,
    required Map<String, String> localHashes,
  }) async {
    final next = <String, String>{...previous.skillHashes};
    for (final item in plan) {
      final id = item.skillId;
      if (deletedSkills.contains(id)) {
        next.remove(id);
        continue;
      }
      if (deferredSkills.contains(id)) continue; // keep the prior baseline
      switch (item.action) {
        case SyncConvAction.iDelete:
        case SyncConvAction.peerDeletes:
        case SyncConvAction.bothDeleted:
          next.remove(id);
        case SyncConvAction.none:
        case SyncConvAction.iSend:
        case SyncConvAction.peerSends:
        case SyncConvAction.bothSend:
          final hash = localHashes[id];
          if (hash == null) {
            next.remove(id);
          } else {
            next[id] = hash;
          }
      }
    }
    return next;
  }

  /// What the skill plan means for this device's content: the peer bodies to
  /// pull, the records that cannot be verified yet, and the local edits the
  /// deterministic rule discards (reported, never silent).
  _SkillAdoptionPlan _planSkillAdoptions({
    required List<SkillContentPlan> plan,
    required SyncManifest mine,
    required SyncManifest peers,
    required Map<String, String> peerSkillHashes,
    required Map<String, String> mySkillHashes,
    required String myDeviceId,
    required String peerDeviceId,
  }) {
    final out = _SkillAdoptionPlan();
    final mineRows =
        mine.entities[SyncDataPlane.skillWire] ??
        const <String, SyncManifestEntry>{};
    final peerRows =
        peers.entities[SyncDataPlane.skillWire] ??
        const <String, SyncManifestEntry>{};
    for (final item in plan) {
      final bothChanged = item.action == SyncConvAction.bothSend;
      final adopt = switch (item.action) {
        SyncConvAction.peerSends => true,
        // Both bodies changed: the record clock decides, exactly as it does
        // for a row, and both peers reach the same verdict independently.
        SyncConvAction.bothSend => incomingBusinessRowWins(
          localUpdatedAtUs: mineRows[item.skillId]?.updatedAtUs ?? 0,
          incomingUpdatedAtUs: peerRows[item.skillId]?.updatedAtUs ?? 0,
          myDeviceId: myDeviceId,
          peerDeviceId: peerDeviceId,
        ),
        _ => false,
      };
      if (!adopt) continue;
      // Adopting the peer's body means the local edit is gone; that is the
      // "loser" the report must name.
      if (bothChanged) out.conflicts.add(item.skillId);
      final peerHash = peerSkillHashes[item.skillId];
      if (peerHash == null) {
        // A record arrived whose body hash did not: nothing can be verified,
        // so the record waits for a session that carries the hash.
        out.deferred.add(item.skillId);
        continue;
      }
      if (mySkillHashes[item.skillId] == peerHash) {
        continue; // already identical
      }
      out.wanted.add(
        SyncBlobEntry(
          kind: SyncBlobEntry.kindSkillDir,
          key: item.skillId,
          contentHash: peerHash,
        ),
      );
      out.wantedSkillIds.add(item.skillId);
    }
    return out;
  }

  /// The blob set one session will try to land: what this side's plan wants
  /// ([fresh]), plus what earlier sessions still owe ([pending]) — and a fresh
  /// entry always wins.
  ///
  /// A blob's target is `(kind, key)`, so re-referencing an attachment or
  /// editing a skill body keeps the target and changes the hash. The retry set
  /// is keyed by target too and holds the hash that was *pending* — exactly the
  /// hash a fresh advertisement supersedes. Folding it in last would make this
  /// side ask, session after session, for a hash the peer no longer backs, while
  /// the peer skips it as "no longer backed": a permanent stall for that file,
  /// reported by neither side. The initiator and the responder fold one set, so
  /// they fold it the same way — the second implementation is the bug.
  static Map<String, SyncBlobEntry> _foldBlobWanted(
    Iterable<SyncBlobEntry> fresh,
    Iterable<SyncBlobEntry> pending,
  ) {
    final wanted = <String, SyncBlobEntry>{
      for (final entry in fresh) entry.target: entry,
    };
    for (final entry in pending) {
      wanted.putIfAbsent(entry.target, () => entry);
    }
    return wanted;
  }

  /// Pulls and applies every wanted blob over [session], returning what landed
  /// and what must be retried. One blob's failure never aborts the session: a
  /// conversation is still a conversation without its picture, and a skill
  /// record is simply deferred. [onProgress] (if given) is called per blob with
  /// how many are done out of the total — the one beat that can take minutes on
  /// a first sync.
  Future<_BlobPullOutcome> _pullBlobs(
    List<SyncBlobEntry> wanted,
    SyncClientSession session, {
    void Function(int done, int total)? onProgress,
  }) async {
    final outcome = _BlobPullOutcome();
    // Nothing to pull is not a beat: publishing "downloading files" for an
    // empty set would flash a phase this session never enters.
    if (wanted.isEmpty) return outcome;
    for (var i = 0; i < wanted.length; i++) {
      final entry = wanted[i];
      onProgress?.call(i, wanted.length);
      File? temp;
      try {
        temp = await store.newBlobTempFile();
        // The client hashes a file blob into this temp file as it streams, so
        // what `_landStagedBlob` places is bytes this device already verified.
        await session.fetchBlob(entry, temp);
        final landed = await _landStagedBlob(entry, temp);
        if (landed == null) {
          outcome.failed[entry.target] = entry;
        } else {
          _recordLanded(entry, landed, outcome);
        }
      } catch (error) {
        debugPrint('sync blob ${entry.contentHash} failed: $error');
        outcome.failed[entry.target] = entry;
      } finally {
        if (temp != null) {
          try {
            if (await temp.exists()) await temp.delete();
          } catch (_) {}
        }
      }
    }
    onProgress?.call(wanted.length, wanted.length);
    return outcome;
  }

  /// Puts one staged blob where its entry says it belongs, returning the bytes
  /// that landed or null when nothing was installed.
  ///
  /// The one place the two blob kinds' *placement* lives, shared by the fetch
  /// beat and the push route (slice 24): a file is a managed-root check plus an
  /// atomic rename, a skill directory is extracted and re-hashed before it is
  /// swapped in. A pushed blob and a pulled one must pass the same gates.
  Future<int?> _landStagedBlob(SyncBlobEntry entry, File staged) async {
    if (entry.kind == SyncBlobEntry.kindSkillDir) {
      final applied = await dataPlane.applySkillBlob(
        skillId: entry.key,
        dirHash: entry.contentHash,
        zip: staged,
      );
      return applied ? await staged.length() : null;
    }
    return placeFileBlob(entry, staged, resolve: dataPlane.blobPathResolver);
  }

  /// Books one landed blob into [outcome]: the one place the two kinds'
  /// bookkeeping is written, so a pull and a push cannot count differently.
  void _recordLanded(
    SyncBlobEntry entry,
    int landed,
    _BlobPullOutcome outcome,
  ) {
    if (entry.kind == SyncBlobEntry.kindSkillDir) {
      outcome.landedSkillIds.add(entry.key);
    } else {
      outcome.landedByUri[entry.key] = entry.withSize(landed);
    }
    outcome.bytes += landed;
    outcome.failed.remove(entry.target);
  }

  /// Pushes the workspace files the responder could not take for itself, over
  /// the connection this round already holds (slice 23).
  ///
  /// The responder only ever asks for pairs it planned to fetch and could not
  /// land — no reverse connection to this device, or a transfer that failed —
  /// and each request names the version this device advertised in the push. A
  /// file that is no longer that version is skipped here: [WorkspaceContentSync.serve]
  /// re-stats it against the advertised stamp, and pushing bytes the receiver
  /// would refuse only wastes the transfer. A failed push is owed, not fatal:
  /// the file keeps its unadvanced ledger entry and is asked for again next
  /// session.
  ///
  /// Sequential on purpose. The control beats are request/response on one
  /// connection, and a workspace's misses are a handful of files; running them
  /// concurrently would buy nothing and make the failure story per-file
  /// unclear.
  Future<({int files, int bytes})> _pushRequestedWorkspaceFiles({
    required SyncClientSession session,
    required String peerDeviceId,
    required List<SyncWorkspaceFileRequest> requests,
  }) async {
    if (requests.isEmpty) return (files: 0, bytes: 0);
    final content = dataPlane.workspaceContent;
    if (content == null) return (files: 0, bytes: 0);
    var files = 0;
    var bytes = 0;
    for (final request in requests) {
      try {
        final file = await content.serve(
          peerDeviceId: peerDeviceId,
          workspaceId: request.workspaceId,
          relPath: request.relPath,
        );
        if (file == null) {
          debugPrint(
            'sync workspace: not pushing ${request.workspaceId}/'
            '${request.relPath}: it is no longer the advertised version',
          );
          continue;
        }
        await session.pushWorkspaceFile(
          workspaceId: request.workspaceId,
          relPath: request.relPath,
          source: file,
          advertised: request.stamp,
        );
        files++;
        bytes += request.stamp.size;
        debugPrint(
          'sync workspace: pushed ${request.workspaceId}/${request.relPath} '
          '(${request.stamp.size} B) to the peer',
        );
      } catch (error) {
        debugPrint(
          'sync workspace: pushing ${request.workspaceId}/${request.relPath} '
          'failed: $error',
        );
      }
    }
    return (files: files, bytes: bytes);
  }

  /// Pushes the blobs the responder could not take for itself, over the
  /// connection this round already holds (slice 24).
  ///
  /// The same shape as [_pushRequestedWorkspaceFiles], and for the same reason:
  /// the peer that cannot be dialled back is the peer whose pictures never
  /// arrive, so the side that holds them has to send them. The responder asks
  /// only for blobs its own plan named, and a blob this device no longer backs
  /// at the requested hash is skipped here — the receiver would refuse those
  /// bytes anyway, and the entry stays owed rather than half-true.
  ///
  /// Sequential on purpose: these are control-beat requests on one connection,
  /// and pushing several large attachments at once would buy nothing while
  /// making a stalled transfer's cause unclear.
  Future<({int blobs, int bytes})> _pushRequestedBlobs({
    required SyncClientSession session,
    required String peerDeviceId,
    required List<SyncBlobEntry> requests,
  }) async {
    if (requests.isEmpty) return (blobs: 0, bytes: 0);
    var blobs = 0;
    var bytes = 0;
    for (final entry in requests) {
      try {
        final file = await _blobToPush(peerDeviceId, entry);
        if (file == null) {
          debugPrint(
            'sync blob: not pushing ${entry.key}: this device no longer backs '
            '${entry.contentHash}',
          );
          continue;
        }
        final size = await file.length();
        await session.pushBlob(entry: entry, source: file, size: size);
        blobs++;
        bytes += size;
        debugPrint('sync blob: pushed ${entry.key} ($size B) to the peer');
      } catch (error) {
        debugPrint('sync blob: pushing ${entry.key} failed: $error');
      }
    }
    return (blobs: blobs, bytes: bytes);
  }

  /// The local file behind one blob this device is about to push, or null when
  /// it can no longer back that hash.
  ///
  /// Resolution goes through [handleFetchBlob] — the same authority a `GET`
  /// consults, so the push serves exactly what a fetch would have — and a file
  /// blob is hashed again on top of it: a published mapping is a memory of what
  /// the file *was* at manifest time, and the receiver's digest check would
  /// throw the transfer away. The hasher memoises by (path, length, mtime), so
  /// an unchanged file costs a stat.
  Future<File?> _blobToPush(String peerDeviceId, SyncBlobEntry entry) async {
    final file = await handleFetchBlob(peerDeviceId, entry.contentHash);
    if (file == null) return null;
    if (entry.kind == SyncBlobEntry.kindFile) {
      final hash = await dataPlane.fileHasher.hashOf(file);
      if (hash != entry.contentHash) return null;
    }
    return file;
  }

  /// Remembers what this device can serve for a manifest it just published.
  /// The server resolves a blob hash from here first (the common case), then
  /// falls back to the asset registry and a live skill hash scan — which is
  /// what lets a blob pending from an *earlier* session still be served.
  ///
  /// The entries come off the wire, so a file entry is only remembered when it
  /// names a managed blob root — the same allowlist the manifest builder and
  /// the placement path enforce. Without it a paired peer could name any
  /// readable local file and fetch it back by a hash it chose.
  void _rememberPublished(List<SyncBlobEntry> entries) {
    for (final entry in entries) {
      if (entry.kind == SyncBlobEntry.kindFile) {
        if (!isAllowedFileBlobUri(entry.key)) continue;
        final resolved = dataPlane.blobPathResolver(entry.key);
        if (resolved != null) {
          _publishedBlobs[entry.contentHash] = File(resolved);
        }
      } else if (entry.kind == SyncBlobEntry.kindSkillDir) {
        _publishedSkillIds[entry.contentHash] = entry.key;
      }
    }
  }

  @override
  Future<File?> handleFetchBlob(String peerDeviceId, String contentHash) async {
    try {
      final published = _publishedBlobs[contentHash];
      if (published != null && await published.exists()) return published;
      final skillId = _publishedSkillIds[contentHash];
      if (skillId != null) {
        return await dataPlane.skillBlobForHash(
          skillId: skillId,
          dirHash: contentHash,
        );
      }
      // A pending retry from a previous launch: the content-addressed asset
      // registry is the durable authority for what this device holds.
      final registered = await dataPlane.assetFileForContentHash(contentHash);
      if (registered != null && await registered.exists()) return registered;
      // A skill body that still hashes to the requested value.
      return await dataPlane.skillBlobForContentHash(contentHash);
    } catch (error) {
      // A body that changed between the manifest and the fetch is simply not
      // servable: the peer records the miss and retries next session.
      debugPrint('sync: serving blob $contentHash failed: $error');
      return null;
    }
  }

  @override
  Future<File?> handleFetchWorkspaceFile(
    String peerDeviceId,
    String workspaceId,
    String relPath,
  ) async {
    final content = dataPlane.workspaceContent;
    // No content support in this build (conversation-only tests): the route
    // answers 404 and the caller counts an unapplied file, which is exactly
    // what "this device cannot serve it" means.
    if (content == null) return null;
    return content.serve(
      peerDeviceId: peerDeviceId,
      workspaceId: workspaceId,
      relPath: relPath,
    );
  }

  /// Receives one workspace file the initiator pushed because this device could
  /// not fetch it (slice 23).
  ///
  /// Three refusals, in order, before a byte of the body is trusted:
  ///
  /// * the session must exist and have taken its push — a push without one has
  ///   no request set, so it has nothing that could authorize a write;
  /// * the pair must be in that session's request set, which is built from the
  ///   table the initiator itself advertised: a crafted `(workspace, path)` has
  ///   never been advertised and so can never be written;
  /// * the declared size must be the size that was asked for, so a peer cannot
  ///   substitute a different version of the file for the one it offered.
  ///
  /// What is left is the switch and the four landing gates, which the content
  /// plane applies exactly as it does for a fetched file. The landed stamp goes
  /// into the session, not the checkpoint: the ledger is written once, at the
  /// fetch beat, after every file this session moved is known.
  ///
  /// The edit time is not a parameter: it travels in the request set's stamp,
  /// which is the version this device asked for, and that is the only stamp the
  /// landing may put on the file.
  @override
  Future<bool> handlePutWorkspaceFile(
    String peerDeviceId,
    String workspaceId,
    String relPath, {
    required int size,
    required Stream<List<int>> body,
  }) async {
    final session = _sessions[peerDeviceId];
    if (session == null) {
      await _discard(body, size);
      return false;
    }
    // A pushed file is peer work on the session, so it is a beat: the idle sweep
    // must not decide this session is gone while the upload is still arriving.
    // Without this, an upload phase longer than [kSessionIdleTtl] was swept out
    // by this device's own next round — every remaining put then found no
    // session, and the fetch beat that follows failed with `sessionMissing` —
    // which is the long first sync the sweeps exist to protect, killed from the
    // other end.
    _beginBeat(session);
    try {
      return await _receivePutWorkspaceFile(
        session,
        workspaceId,
        relPath,
        size: size,
        body: body,
      );
    } finally {
      _endBeat(session);
    }
  }

  /// [handlePutWorkspaceFile]'s body, run inside that put's beat.
  Future<bool> _receivePutWorkspaceFile(
    _ResponderSession session,
    String workspaceId,
    String relPath, {
    required int size,
    required Stream<List<int>> body,
  }) async {
    if (!session.pushSeen) {
      await _discard(body, size);
      return false;
    }
    final key = WorkspaceContentSync.serveKey(workspaceId, relPath);
    final requested = session.workspaceRequests[key];
    if (requested == null || requested.stamp.size != size) {
      await _discard(body, size);
      debugPrint(
        'sync workspace: refusing a push for $workspaceId/$relPath: this '
        'session did not ask for that version',
      );
      return false;
    }
    final content = dataPlane.workspaceContent;
    if (content == null) {
      await _discard(body, size);
      return false;
    }
    File? staged;
    var received = 0;
    try {
      staged = await store.newBlobTempFile();
      final sink = staged.openWrite();
      try {
        await for (final chunk in body) {
          received += chunk.length;
          // The declared length is the contract; a body that exceeds it is a
          // peer bug or a hostile one, and neither gets to fill this disk.
          if (received > size) throw const _PushTooLarge();
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (received != size) {
        debugPrint(
          'sync workspace: refusing a push for $workspaceId/$relPath: $received '
          'bytes arrived, $size were asked for',
        );
        return false;
      }
      final landed = await content.acceptPushed(
        workspaceId: workspaceId,
        relPath: relPath,
        staged: staged,
        advertised: requested.stamp,
      );
      if (landed == null) return false;
      session.pushedWorkspace.putIfAbsent(
        workspaceId,
        () => <String, SyncAgreedFile>{},
      )[relPath] = SyncAgreedFile(
        landed,
        requested.stamp,
      );
      session.pushedFiles++;
      session.pushedBytes += landed.size;
      // A push that lands a `peerWins` is the replacement the fetch could not
      // perform, and the card has to say so: `peerWins` promises "counted, never
      // silent", and this is the one arrival the fetch's own counter never sees.
      if (session.workspaceReplacements.remove(key)) {
        session.pushedReplacements++;
      }
      // Asked for and delivered: nothing may write that pair again this
      // session, and the next one re-plans from the ledger this produced.
      session.workspaceRequests.remove(key);
      return true;
    } catch (error) {
      debugPrint(
        'sync workspace: receiving the pushed $workspaceId/$relPath failed: '
        '$error',
      );
      return false;
    } finally {
      try {
        if (staged != null && await staged.exists()) await staged.delete();
      } catch (_) {}
    }
  }

  /// Reads and drops up to [limit] bytes of a request body this device is
  /// refusing.
  ///
  /// A refusal answered while the peer is still writing leaves the socket
  /// half-read until the route deadline — and a peer that pushed a workspace
  /// file has spent the send either way, so the only thing left to choose is
  /// whether the connection is left wedged. Nothing here is trusted: the read
  /// stops at the declared length, and a body that dies mid-flight is the same
  /// answer as one that was never read.
  static Future<void> _discard(Stream<List<int>> body, int limit) async {
    var seen = 0;
    try {
      await for (final chunk in body) {
        seen += chunk.length;
        if (seen >= limit) break;
      }
    } catch (_) {}
  }

  /// Receives one blob the initiator pushed because this device could not fetch
  /// it (slice 24) — the blob plane's half of [handlePutWorkspaceFile].
  ///
  /// Three refusals before a byte is trusted, exactly as for a file:
  ///
  /// * the session must exist and have taken its push — no push beat, no request
  ///   set, and therefore nothing that could authorize a write;
  /// * the `(kind, key)` must be an entry this session asked for, and the
  ///   route's hash must be that entry's hash — a crafted target has never been
  ///   advertised and can never be written (the placement allowlist then keeps
  ///   even an advertised URI inside the managed roots);
  /// * a file blob's declared length must be the size that was asked for, so a
  ///   peer cannot substitute a different version for the one it offered.
  ///
  /// The bytes are then checked by the *receiver*, which is where both
  /// directions put that authority: a file is hashed and compared, a skill's zip
  /// is extracted and its directory re-hashed. A skill body that lands is paired
  /// with its record before this returns — the record was stripped from the
  /// business apply while the body was missing, and a body that sits on disk
  /// without one is adopted by the skills rescan as a fresh default record.
  @override
  Future<bool> handlePutBlob(
    String peerDeviceId,
    String contentHash, {
    required String kind,
    required String key,
    required int size,
    required Stream<List<int>> body,
  }) async {
    final session = _sessions[peerDeviceId];
    if (session == null) {
      await _discard(body, size);
      return false;
    }
    // The blob plane's put is a beat for the same reason the file plane's is:
    // a body that takes longer than [kSessionIdleTtl] to arrive is the session
    // being worked on, not the session being abandoned.
    _beginBeat(session);
    try {
      return await _receivePutBlob(
        peerDeviceId,
        session,
        contentHash,
        kind: kind,
        key: key,
        size: size,
        body: body,
      );
    } finally {
      _endBeat(session);
    }
  }

  /// [handlePutBlob]'s body, run inside that put's beat.
  Future<bool> _receivePutBlob(
    String peerDeviceId,
    _ResponderSession session,
    String contentHash, {
    required String kind,
    required String key,
    required int size,
    required Stream<List<int>> body,
  }) async {
    if (!session.pushSeen) {
      await _discard(body, size);
      return false;
    }
    final requested = session.blobRequests[SyncBlobEntry.targetOf(kind, key)];
    if (requested == null ||
        requested.contentHash != contentHash ||
        requested.kind != kind ||
        requested.key != key ||
        (kind == SyncBlobEntry.kindFile && requested.byteSize != size)) {
      await _discard(body, size);
      debugPrint(
        'sync blob: refusing a push for $kind "$key": this session did not ask '
        'for that version',
      );
      return false;
    }
    File? staged;
    var received = 0;
    try {
      staged = await store.newBlobTempFile();
      final sink = staged.openWrite();
      try {
        await for (final chunk in body) {
          received += chunk.length;
          // A chunked body is refused at the route, so this is the peer lying
          // about its own declaration; a skill's zip has no agreed length, so
          // for it this is a self-consistency check rather than a contract.
          if (received > size) throw const _PushTooLarge();
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (received != size) {
        debugPrint(
          'sync blob: refusing a push for "$key": $received bytes arrived, '
          '$size were declared',
        );
        return false;
      }
      if (kind == SyncBlobEntry.kindFile) {
        final digest = await dataPlane.fileHasher.hashOf(staged);
        if (digest != contentHash) {
          // The peer's file changed since the manifest it published. Nothing is
          // placed, and the entry is asked for again from whoever has it.
          debugPrint(
            'sync blob: refusing a push for "$key": the bytes hash to $digest, '
            'not $contentHash',
          );
          return false;
        }
      }
      final landed = await _landStagedBlob(requested, staged);
      if (landed == null) {
        debugPrint('sync blob: the pushed $kind "$key" did not verify');
        return false;
      }
      // Landed: it counts as this side's, it is no longer owed, and it may not
      // be written again this session.
      _recordLanded(requested, landed, session.blobPull);
      session.pushedBlobs++;
      session.pushedBlobBytes += landed;
      session.blobRequests.remove(requested.target);
      if (kind == SyncBlobEntry.kindSkillDir) {
        await _pairPushedSkill(peerDeviceId, session, key);
      }
      return true;
    } catch (error) {
      debugPrint('sync blob: receiving the pushed $kind "$key" failed: $error');
      return false;
    } finally {
      try {
        if (staged != null && await staged.exists()) await staged.delete();
      } catch (_) {}
    }
  }

  /// Deploys the record of a skill whose body just arrived by push.
  ///
  /// The push beat strips the record of every skill whose body it could not
  /// verify, and a pushed body lands *after* that apply — so without this the
  /// session would end with a directory and no row. That is not a harmless
  /// intermediate state: `SkillsService`'s rescan adopts a row-less directory as
  /// a fresh record stamped *now*, which then beats the peer's record in the
  /// next merge and silently replaces the user's skill settings with defaults.
  ///
  /// Only this skill's rows travel through [SyncDataPlane.applyBusiness] — the
  /// rest of the push was applied beats ago — and the row joins
  /// [receivedBusiness], which is what the fetch beat's checkpoint advance reads.
  /// So this is also what makes the skill usable in *this* session rather than
  /// the next one.
  Future<void> _pairPushedSkill(
    String peerDeviceId,
    _ResponderSession session,
    String skillId,
  ) async {
    final rows = [
      for (final row
          in session.pushedBusiness.entities[SyncDataPlane.skillWire] ??
              const <Map<String, dynamic>>[])
        if (row['id'] == skillId) row,
    ];
    if (rows.isEmpty) {
      // The body arrived without its record in the push: the next session's
      // plan brings it, and the rescan window is documented in the ADR.
      return;
    }
    final outcome = await dataPlane.applyBusiness(
      SyncBusinessPayload(entities: {SyncDataPlane.skillWire: rows}),
      myDeviceId: identity.deviceId,
      peerDeviceId: peerDeviceId,
    );
    if (outcome.deferred) {
      // A restore holds the write fence: the record is not ours to write yet,
      // and claiming it in the checkpoint would read as "the peer has it".
      debugPrint(
        'sync blob: the record of the pushed skill $skillId was deferred',
      );
      return;
    }
    final entities = {
      for (final entry in session.receivedBusiness.entities.entries)
        entry.key: List<Map<String, dynamic>>.of(entry.value),
    };
    entities[SyncDataPlane.skillWire] = [
      ...?entities[SyncDataPlane.skillWire],
      ...rows,
    ];
    session.receivedBusiness = SyncBusinessPayload(
      entities: entities,
      preferences: session.receivedBusiness.preferences,
    );
    // The body is here and its record is applied, so the content plan's verdict
    // for this skill is settled: keeping it deferred would keep the skill
    // baseline (and the record) one session behind for no reason.
    session.deferredSkills.remove(skillId);
  }

  /// The file ledger this session ends with: everything the push beat agreed,
  /// plus every file the initiator pushed afterwards.
  ///
  /// One place, at the fetch beat, because a pushed file arrives *after* the
  /// beat that produced the ledger's base — two writers for one checkpoint is
  /// exactly how an advance gets lost.
  Map<String, Map<String, SyncAgreedFile>> _finalWorkspaceLedger(
    _ResponderSession session,
  ) {
    final ledger = session.workspaceOutcome!.ledger;
    final content = dataPlane.workspaceContent;
    if (content == null || session.pushedWorkspace.isEmpty) return ledger;
    return content.ledgerWithPushed(ledger, session.pushedWorkspace);
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
    _BlobPullOutcome? blobPull,
    int skillConflicts = 0,
    int deferredSkills = 0,
    WorkspaceContentOutcome? workspace,
    int workspaceFoldersKept = 0,
    int workspacePushed = 0,
    int workspacePushedBytes = 0,
    int workspaceMissesRepaired = 0,
    int workspaceReplacements = 0,
    int workspacesDroppedByCap = 0,
    int blobsPushed = 0,
    int blobBytesPushed = 0,
    int? clockSkewMs,
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
    // The incoming half on its own, for the arrival gate: it cannot use the
    // aggregates above, which are deliberately bidirectional.
    final entityRowsReceived = _entityRowCount(receivedBusiness);
    final preferenceRowsReceived = receivedBusiness.preferences.length;
    final blobsMoved = blobPull?.landedCount ?? 0;
    final blobBytes = blobPull?.bytes ?? 0;
    final skillsUpdated = blobPull?.landedSkillIds.length ?? 0;
    final blobsMissing = blobPull?.failed.length ?? 0;
    final entityRowsLost = appliedBusiness?.entityRowsLost ?? 0;
    final preferencesLost = appliedBusiness?.preferencesLost ?? 0;
    // Everything the workspace plane moved, whichever side asked for it: a file
    // this device pulled and one the peer pushed both arrived here, and the
    // count is what the user sees on the card.
    final workspaceFetched = workspace?.filesLanded ?? 0;
    final workspaceFiles = workspaceFetched + workspacePushed;
    final workspaceBytes = (workspace?.bytesLanded ?? 0) + workspacePushedBytes;
    // A file the peer pushed is a miss that was repaired: the fetch failed when
    // this device counted it, and the bytes arrived over the other direction.
    // Reporting both would name the same file missing and present in one card,
    // which is worse than either alone. What remains missing is what no
    // direction moved — a deletion the filesystem refused, or a push that never
    // arrived.
    final workspaceMissing = max(
      0,
      (workspace?.filesMissing ?? 0) - workspaceMissesRepaired,
    );
    // A local edit replaced by the peer's version, however the bytes arrived: the
    // fetch counts what it lands, and the push counts a `peerWins` the fetch
    // could not land and this device asked for instead.
    final workspaceReplaced =
        (workspace?.filesReplaced ?? 0) + workspaceReplacements;
    // "Shared no content for this session", both reasons in one number: the
    // switch/caps the plan recorded, plus the shared workspaces the advertised
    // tables had to drop to stay inside their own cap. The second is the reason
    // nobody could see — the peer reads a dropped workspace as "not shared" and
    // plans nothing — which is exactly the silence this count exists against.
    final workspacesOmitted =
        (workspace?.workspacesOmitted ?? 0) + workspacesDroppedByCap;
    final skewMinutes = clockSkewMs == null
        ? null
        : (clockSkewMs.abs() / 60000).round();
    final parts = <String>[
      'sent $sent',
      'received $received',
      if (upserted > 0) '+$upserted msgs',
      if (deleted > 0) '-$deleted msgs',
      if (deletedLocally > 0) '-$deletedLocally convs',
      if (entityRows > 0) 'entities $entityRows',
      if (preferenceRows > 0) 'prefs $preferenceRows',
      if (blobsMoved > 0) 'blobs $blobsMoved ($blobBytes B)',
      if (blobsPushed > 0) 'blobs pushed $blobsPushed ($blobBytesPushed B)',
      if (skillsUpdated > 0) 'skills $skillsUpdated',
      if (workspaceFetched > 0)
        'workspace files $workspaceFetched (${workspace!.bytesLanded} B)',
      if (workspacePushed > 0)
        'workspace files pushed $workspacePushed ($workspacePushedBytes B)',
      if ((workspace?.filesRemoved ?? 0) > 0)
        'workspace files removed ${workspace!.filesRemoved}',
      if (workspaceReplaced > 0) 'workspace files replaced $workspaceReplaced',
      // Gated on what is left after the repair, not on the raw miss count: a miss
      // a push repaired is not a miss, and "workspace files missing 0" is what
      // the raw gate printed for the one case the fallback exists for.
      if (workspaceMissing > 0) 'workspace files missing $workspaceMissing',
      if (workspacesOmitted > 0) 'workspaces omitted $workspacesOmitted',
      if (skillConflicts > 0) '$skillConflicts skill conflicts',
      if (blobsMissing > 0) '$blobsMissing blobs missing',
      if (deferredSkills > 0) 'deferred $deferredSkills skills',
      if (deferred > 0) 'deferred $deferred',
      if (appliedBusiness?.deferred == true) 'business deferred',
      if (entityRowsLost > 0) 'lost $entityRowsLost entity rows',
      if (preferencesLost > 0) 'lost $preferencesLost prefs',
      if (skewMinutes != null) 'clock skew ~$skewMinutes min',
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
      entityRowsReceived: entityRowsReceived,
      preferenceRowsReceived: preferenceRowsReceived,
      blobsMoved: blobsMoved,
      blobBytes: blobBytes,
      skillsUpdated: skillsUpdated,
      skillConflicts: skillConflicts,
      blobsMissing: blobsMissing,
      entityRowsLost: entityRowsLost,
      preferencesLost: preferencesLost,
      workspaceFiles: workspaceFiles,
      workspaceBytes: workspaceBytes,
      workspaceFilesRemoved: workspace?.filesRemoved ?? 0,
      workspaceConflicts: workspaceReplaced,
      workspaceFilesMissing: workspaceMissing,
      workspaceFoldersKept: workspaceFoldersKept,
      workspacesOmitted: workspacesOmitted,
      clockSkewMs: clockSkewMs,
    );
  }

  /// Signed clock divergence against a peer, in milliseconds, or null when
  /// either reading is absent or the gap sits inside the warn threshold. The
  /// comparison uses each side's own clock at hello-build time, so LAN
  /// latency (~ms) is noise against a threshold measured in minutes.
  static int? _clockSkewMs(int? myClockUs, int? peerClockUs) {
    if (myClockUs == null || peerClockUs == null) return null;
    final skewMs = ((myClockUs - peerClockUs) / 1000).round();
    return skewMs.abs() > kClockSkewWarnMs ? skewMs : null;
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
  ///
  /// [host]/[port] are the endpoint the session ran over. A session that got as
  /// far as an answer proves that address reaches the peer on this network
  /// (refusals included), so it is promoted to the front of the remembered set.
  ///
  /// A failed session updates [SyncPeerRecord.lastReport] but not
  /// [SyncPeerRecord.lastSyncedAt]: "last synced" is a claim about the data the
  /// user sees, and an unreachable peer changed none of it. The stamp otherwise
  /// regressed to "just now" on every failure — exactly when nothing synced.
  Future<SyncSessionReport> _finish(
    SyncSessionReport report, {
    SyncPeerRecord? peer,
    String? host,
    int? port,
  }) async {
    // A superseded round records nothing: it is not the peer's verdict, it did
    // not run, and the session that did run reports for the pair. Writing it
    // would leave the card claiming a failed attempt over a live one.
    if (report.refusal == SyncRefusalReason.superseded) return report;
    lastReport = report;
    if (peer != null) {
      // Merged into the record as it stands now, not written onto the instance
      // this session has held since before it started: the session's own beats
      // make the provider re-read the list from disk, so a copy that old is a
      // copy without whatever the user changed meanwhile — and writing it whole
      // is how a rename made during a session used to be lost.
      await store.mutatePeer(peer.deviceId, (current) {
        if (report.success) current.lastSyncedAt = DateTime.now();
        current.lastReport = report.toPeerReport();
        if (host != null && port != null) {
          current.noteEndpointSuccess(host, port);
        }
        return true;
      });
    }
    onStateChanged();
    return report;
  }

  /// Classifies a failed session. The transport failures get their own
  /// reasons so the panel can say what happened; everything else is internal,
  /// which is the only case where the logs hold the detail.
  static SyncFailureReason _failureReason(Object error) {
    if (error is TimeoutException) return SyncFailureReason.timeout;
    if (error is SocketException ||
        error is HttpException ||
        error is HandshakeException) {
      return SyncFailureReason.unreachable;
    }
    if (error is SyncClientException) {
      final status = error.statusCode;
      if (status != null && status >= 500) return SyncFailureReason.peerError;
    }
    return SyncFailureReason.internal;
  }

  /// A fresh 32-byte secret for a newly paired peer, base64 in a form that is
  /// safe in an HTTP header.
  static String _newSecret() {
    final random = Random.secure();
    return base64Encode(
      List<int>.generate(32, (_) => random.nextInt(256), growable: false),
    );
  }

  /// Carries the facts a re-pair must not lose from [existing] onto [peer].
  ///
  /// Pairing rebuilds the record — a new certificate pin, a rotated secret, a
  /// fresh address set — but a re-pair is the *drift-repair journey*, not a new
  /// relationship, so three fields of the old record are still true: the manual
  /// rename (a fact about this device's user, not about the peer), and the
  /// last-sync stamp and report (the sessions that produced them happened, and
  /// the checkpoint they advanced survives the re-pair untouched — it is keyed
  /// by deviceId, which pairing does not change).
  ///
  /// Endpoints are deliberately *not* here: they have to land behind the
  /// address this pairing just proved and the candidates it advertised, so each
  /// caller appends the old set after its own endpoint writes
  /// ([SyncPeerRecord.rememberEndpointHistory]).
  static void _carryPairingFacts(
    SyncPeerRecord peer,
    SyncPeerRecord? existing,
  ) {
    if (existing == null) return;
    peer.customName = existing.customName;
    peer.lastSyncedAt = existing.lastSyncedAt;
    peer.lastReport = existing.lastReport;
  }

  /// Drops the responder sessions that cannot be running any more.
  ///
  /// Two rules, two states, and they must not be confused with each other:
  ///
  /// * [_dropIdleSessions] — nothing has happened on this session for
  ///   [kSessionIdleTtl]. The clock starts at the peer's last beat, so a session
  ///   that is *working* (a beat in flight, however long) is never a candidate.
  ///   A beat is the hello that opened the session, its push, its fetch — and
  ///   every file or blob body the initiator is still uploading: the put routes
  ///   run inside a beat for exactly this reason, because a first sync's upload
  ///   phase can outlast the window with nothing else to show for it.
  /// * [_dropAbandonedYieldedSessions] — a session this device accepted by
  ///   yielding its own dial which the peer never came back to drive, after the
  ///   short [yieldedSessionTtl].
  ///
  /// Both used to be one `removeWhere` keyed on `startedAt`, which is why a
  /// twenty-minute first sync was swept out from under its own beat. Called from
  /// the top of [handleHello] and, more importantly, from the top of
  /// [syncWithPeer]: a session nobody drives is exactly what makes that call
  /// refuse its own round as busy, so the sweep has to run *before* the refusal
  /// or nothing this device does on its own would ever clear it.
  void _sweepSessions() {
    _dropIdleSessions();
    _dropAbandonedYieldedSessions();
    _assertSessionInvariants();
  }

  void _dropIdleSessions() {
    final now = this.now();
    _sessions.removeWhere((_, session) {
      if (session.beatsInFlight > 0) return false;
      final since = session.lastBeatAt ?? session.startedAt;
      return now.difference(since) > sessionIdleTtl;
    });
  }

  void _dropAbandonedYieldedSessions() {
    final now = this.now();
    _sessions.removeWhere((_, session) {
      if (session.beatsInFlight > 0) return false;
      return session.yielded &&
          session.lastBeatAt == null &&
          now.difference(session.startedAt) > yieldedSessionTtl;
    });
  }

  /// Debug-only: the facts every session in [_sessions] has to satisfy,
  /// whichever path put it there.
  ///
  /// This is the cheap half of the state table the round-2 review asked for: the
  /// sweep's rules are only correct if a session can never be in a state nobody
  /// enumerated (no beat, a beat in flight, yielded, answered), and an assertion
  /// at the transitions catches the caller that invents a fifth state — in
  /// debug, at the moment it happens, instead of as a wedged pair in the field.
  void _assertSessionInvariants() {
    assert(() {
      for (final entry in _sessions.entries) {
        final session = entry.value;
        assert(
          session.initiatorHello.deviceId == entry.key,
          'a session is keyed by the device its hello named',
        );
        assert(
          session.beatsInFlight >= 0,
          'a beat cannot end more times than it began',
        );
        assert(
          !(session.beatsInFlight > 0 && session.lastBeatAt == null),
          'a beat in flight is a session the peer has touched',
        );
        assert(
          session.pushSeen || session.workspaceRequests.isEmpty,
          'the upload requests are the push beat\'s product: a session that '
          'has not taken it has nothing to ask for',
        );
        assert(
          session.pushSeen || session.blobRequests.isEmpty,
          'the blob requests are the push beat\'s product too: a session that '
          'has not taken it has nothing to ask for',
        );
        assert(
          session.pushedWorkspace.isEmpty || session.pushSeen,
          'a pushed file can only land on a session that has taken its push',
        );
        assert(
          session.pushedBlobs == 0 || session.pushSeen,
          'a pushed blob can only land on a session that has taken its push',
        );
      }
      return true;
    }());
  }

  /// Opens one beat on [peerDeviceId]'s session: the session is alive, and a
  /// sweep must not touch it while the beat runs.
  ///
  /// The stamp is written on both ends of the beat, so "idle" means "nothing has
  /// happened for the idle window", not "nothing has *started*" — a beat that
  /// began two minutes ago and finished now is recent activity.
  void _beginBeat(_ResponderSession session) {
    session.beatsInFlight++;
    session.lastBeatAt = now();
  }

  void _endBeat(_ResponderSession session) {
    session.beatsInFlight--;
    session.lastBeatAt = now();
    _assertSessionInvariants();
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
    required this.skillPlan,
    required this.myManifest,
    required this.checkpoint,
    required this.startedAt,
    required this.myHosts,
    this.initiatorHost,
    this.clockSkewMs,
    this.peerReplaced = false,
    this.yielded = false,
  });

  final SyncHello initiatorHello;
  final List<SyncConvPlan> plan;
  final List<SyncBusinessPlanItem> businessPlan;
  final List<SkillContentPlan> skillPlan;

  /// This device's manifest as built for the hello: the skill-content verdict
  /// and the response batch are both read from it.
  final SyncManifest myManifest;
  final SyncCheckpoint checkpoint;
  final DateTime startedAt;

  /// The address the initiator connected from, as this listener saw it: with
  /// `initiatorHello.listenPort` it is the endpoint used to pull blobs back.
  final String? initiatorHost;

  /// This device's own addresses, read once when the session was accepted.
  ///
  /// The one fact that tells a NAT-rewritten caller address from a real one: a
  /// source address of *this* device is never where the peer is, and recording it
  /// as an endpoint would hand the panel an address that can only ever dial this
  /// device itself.
  final Set<String> myHosts;

  /// Clock divergence against the initiator, when it exceeded the warn
  /// threshold — lands in this side's report at the fetch beat.
  final int? clockSkewMs;

  /// The caller advertised a different data epoch than the last session: its
  /// database was bulk-replaced, so its absences may not justify a deletion
  /// here (see [SyncStore.readDataEpoch]).
  final bool peerReplaced;

  /// This session exists because the arriving hello superseded this device's own
  /// unanswered dial. Such a session is a bet on the peer's client still being
  /// alive to drive it — see [SyncEngine.kYieldedSessionTtl].
  final bool yielded;

  /// When this session's first beat arrived *or ended*, or null while the peer's
  /// client has not touched it yet (the state [SyncEngine.kYieldedSessionTtl]
  /// bounds). The idle sweep measures from here, so it is written at both ends of
  /// a beat: a beat that was in flight for minutes is recent activity when it
  /// finishes.
  DateTime? lastBeatAt;

  /// How many beats are running on this session right now.
  ///
  /// The one thing the idle sweep must not confuse with idleness. A first sync of
  /// a large library is a single push beat that runs for minutes with no other
  /// traffic, and sweeping it out from under itself is what made the peer's next
  /// beat fail with `sync_session_missing` (the round-2 review's first finding).
  int beatsInFlight = 0;

  /// Whether this session has taken the push beat it is built around.
  ///
  /// Every session is one push followed by one fetch; the fetch is answered only
  /// after the push, because the workspace ledger (and the whole checkpoint this
  /// side writes at the fetch beat) is produced by the push.
  bool pushSeen = false;

  final Map<String, SyncSubtreeApplyOutcome> outcomes = {};

  /// Business rows the initiator pushed in this session's one PUT.
  SyncBusinessPayload receivedBusiness = const SyncBusinessPayload();

  /// The same push, exactly as it arrived — including the skill rows
  /// [receivedBusiness] had stripped because their body had not landed.
  ///
  /// A body pushed *after* the business apply is one of those, so this is where
  /// the late apply finds the record that belongs to it (slice 24).
  SyncBusinessPayload pushedBusiness = const SyncBusinessPayload();

  /// Result of applying them, for the checkpoint and the report.
  SyncBusinessApplyOutcome? businessOutcome;

  /// Blobs this responder pulled from the initiator in this session — and, for
  /// the ones it could not pull, the same object the pushes land into, so the
  /// report counts a blob exactly once whichever direction delivered it.
  _BlobPullOutcome blobPull = _BlobPullOutcome();

  /// The blobs this session asked the initiator to push, keyed by
  /// `SyncBlobEntry.target`.
  ///
  /// Built by the push beat from the blobs it planned and could not land; it is
  /// the write authorization for [handlePutBlob] — a push for an entry this map
  /// does not hold is refused, so the route can never write content the peer
  /// never advertised (slice 24). An entry is removed once its blob lands.
  final Map<String, SyncBlobEntry> blobRequests = {};

  /// Blobs the initiator pushed and this device landed, for the report —
  /// counted separately from the fetch half so the log can tell the directions
  /// apart. [blobPull] carries the same landings for the card.
  int pushedBlobs = 0;
  int pushedBlobBytes = 0;

  /// Workspace content this responder moved in this session, and the file
  /// ledger that came out of it. Its snapshot is re-walked at the fetch beat:
  /// the response table has to describe the files this side holds *now*,
  /// including the ones that landed a moment ago, or the initiator would never
  /// learn its transfer arrived.
  WorkspaceContentOutcome? workspaceOutcome;

  /// The workspace files this session asked the initiator to push, keyed by
  /// `WorkspaceContentSync.serveKey`.
  ///
  /// Built by the push beat from the files it planned and could not land; it is
  /// the write authorization for [handlePutWorkspaceFile] — a push for a pair
  /// this map does not hold is refused, so the route can never write a file the
  /// peer never advertised (slice 23). An entry is removed once its file lands.
  final Map<String, SyncWorkspaceFileRequest> workspaceRequests = {};

  /// The serve keys among [workspaceRequests] whose plan action was `peerWins`:
  /// if one of those lands, a local edit was replaced by the peer's version.
  ///
  /// Kept beside the request set rather than inside it: the request's job is the
  /// write authorization, and the owner of the *action* is the plan
  /// ([WorkspaceContentOutcome.replacedUnlanded]).
  final Set<String> workspaceReplacements = {};

  /// Files the initiator pushed and this device landed, by workspace then path,
  /// with both sides' stamps. Merged into the ledger at the fetch beat, which is
  /// the one place this side writes it.
  final Map<String, Map<String, SyncAgreedFile>> pushedWorkspace = {};

  /// What those pushes moved, for the report — counted separately from the
  /// fetch half so the log can tell the two directions apart.
  int pushedFiles = 0;
  int pushedBytes = 0;

  /// How many of [pushedFiles] landed in place of a local edit, for the report's
  /// "edits replaced" row.
  int pushedReplacements = 0;

  /// Skill records the push carried whose body could not be verified here.
  Set<String> deferredSkills = {};

  /// Local skill edits the deterministic content rule discarded.
  Set<String> skillConflicts = {};
}

/// Logs the endpoints a pairing had to drop because the peer's record is at the
/// cap ([kMaxPeerEndpoints]).
///
/// An advertised address is the peer's own answer to "where am I reachable", and
/// the memory of addresses is what lets a pair survive moving between networks —
/// so dropping one is a fact worth a line, not a silent trim. A debug line rather
/// than a report field: this happens only when a QR carries more candidates than
/// a record can hold, which no shipped path produces.
void _reportDroppedEndpoints(String deviceId, List<Object> dropped) {
  if (dropped.isEmpty) return;
  debugPrint(
    'sync: $deviceId advertised ${dropped.length} address(es) beyond the '
    '$kMaxPeerEndpoints remembered (${dropped.join(', ')})',
  );
}

/// Outcome of pulling one session's blobs: what landed, what must be retried,
/// and how many bytes crossed.
class _BlobPullOutcome {
  final Map<String, SyncBlobEntry> landedByUri = {};
  final Set<String> landedSkillIds = {};
  final Map<String, SyncBlobEntry> failed = {};
  int bytes = 0;

  int get landedCount => landedByUri.length + landedSkillIds.length;
}

/// What the skill-content plan asks of this device.
class _SkillAdoptionPlan {
  final List<SyncBlobEntry> wanted = [];
  final Set<String> wantedSkillIds = {};
  final Set<String> deferred = {};
  final Set<String> conflicts = {};
}

/// One initiator round, and the two facts that decide whether an arriving hello
/// may supersede it.
///
/// [answered] turns true the moment the peer's hello response lands: from then
/// on this round is a live session and the pair must not get a second one, so a
/// hello from the peer is refused as busy. Before that the round has proved
/// nothing — it may be stuck on an address that never answers, which is exactly
/// the one-way LAN case — so the peer's hello, which *has* proved the peer
/// reaches this device, takes over.
class _InitiatorRound {
  bool answered = false;
  bool cancelled = false;

  /// The session's client, published so [cancel] can break an await that is
  /// waiting on a peer that may never answer. Null between candidates.
  SyncClientSession? session;

  /// The probe measurements the dial order was built from, kept so each
  /// candidate's connect budget can come from the round trip it just measured.
  Map<(String, int), EndpointProbeResult> probed = const {};

  /// The same measurements *without* the freshness filter, so the one guess a
  /// round that proved nothing still spends can prefer an address that answered
  /// at some point over one that never has (see [_oneGuess]).
  Map<(String, int), EndpointProbeResult> lastKnown = const {};

  void cancel() {
    cancelled = true;
    final open = session;
    session = null;
    open?.close();
  }
}

/// A pushed body larger than the length its own request declared.
///
/// Its own type so the refusal is one `catch` away from every other failure of
/// the route, and so the two push handlers can stop reading the body rather
/// than buffering what a buggy or hostile peer decided to send.
class _PushTooLarge implements Exception {
  const _PushTooLarge();
}
