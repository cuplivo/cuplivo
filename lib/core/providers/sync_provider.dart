import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../utils/app_directories.dart';
import '../database/business_preferences.dart';
import '../database/business_repository.dart';
import '../database/chat_database_repository.dart';
import '../services/app_exit_flush.dart';
import '../services/chat/chat_service.dart';
import '../services/skills/skill_directory_sync.dart';
import '../services/sync/business_state_reloader.dart';
import '../services/sync/sync_candidate_prober.dart';
import '../services/sync/sync_client.dart';
import '../services/sync/sync_data_plane.dart';
import '../services/sync/sync_engine.dart';
import '../services/sync/sync_identity.dart';
import '../services/sync/sync_local_addresses.dart';
import '../services/sync/sync_models.dart';
import '../services/sync/sync_pair_qr.dart';
import '../services/sync/sync_store.dart';
import '../services/sync/windows_firewall.dart';

/// Outcome of a pairing attempt, with a stable error code the UI maps to a
/// localized message (`invalid_pin`, `unreachable`, `no_certificate`,
/// `id_mismatch`, `fingerprint_mismatch`, `no_endpoint_in_qr`,
/// `invalid_qr`, `no_listener`, `unknown`).
class SyncPairOutcome {
  final bool success;
  final String? errorCode;
  final String? errorDetail;

  /// The device that was paired, on success: the record's own name and id, so a
  /// caller can announce *which* device it just paired with. The engine returns
  /// the record it wrote, so this is the same name that device's card shows —
  /// not a second spelling assembled from the request.
  final String? peerName;
  final String? peerDeviceId;

  const SyncPairOutcome.success({this.peerName, this.peerDeviceId})
    : success = true,
      errorCode = null,
      errorDetail = null;

  const SyncPairOutcome.failure(this.errorCode, [this.errorDetail])
    : success = false,
      peerName = null,
      peerDeviceId = null;
}

/// Result of pairing from a scanned QR: the pair outcome plus whether the
/// scanned device was already paired (re-scanning updates its endpoint and
/// rotates the secret — the drift-repair journey).
class SyncPairQrOutcome {
  final SyncPairOutcome outcome;
  final bool wasKnownPeer;
  const SyncPairQrOutcome(this.outcome, this.wasKnownPeer);
}

/// Minimum spacing between two automatic sync rounds; a manual "sync now"
/// is never throttled.
const autoSyncInterval = Duration(seconds: 60);

/// How often the online dots re-probe while the app is visible. A bare TCP
/// connect per endpoint — the same probe a dial already pays — so half the
/// sync cadence costs almost nothing and keeps the dots honest.
const presenceRefreshInterval = Duration(seconds: 30);

/// How long a session's verdict about reaching a peer outranks the probe.
///
/// Long enough to survive the probe cycle that immediately follows a failed
/// session (the probe would otherwise re-green an address that accepts a
/// connection but cannot complete a session), short enough that a peer which
/// really came back is not held gray by a verdict from minutes ago.
const sessionVerdictTtl = Duration(minutes: 1);

/// Where a peer's current online/offline answer came from.
enum PresenceSource {
  /// Nothing has an opinion yet: no probe has landed and no session has run.
  /// The card draws the gray dot, which is the honest default.
  unknown,

  /// A recent session exchanged bytes with the peer (or was refused by it —
  /// a refusal *is* an answer).
  sessionAnswered,

  /// A recent session found no address that would talk.
  sessionSilent,

  /// No fresh session verdict; the last probe reached one of the remembered
  /// addresses.
  probe,
}

/// The auto-round cadence decision, pure so tests can cover it: run when
/// there is no previous round, or when the interval has fully elapsed.
bool shouldAutoSyncNow(DateTime now, DateTime? lastRoundAt) {
  if (lastRoundAt == null) return true;
  return now.difference(lastRoundAt) >= autoSyncInterval;
}

/// UI-facing state of the LAN sync engine (ADR-0003, slice 1b).
///
/// The engine is transport + session logic; this provider owns its lifecycle:
/// start the listener with the app, keep the peer list the panels show in
/// sync with the store, mediate the pairing window, and run one quiet sync
/// round whenever the app comes back to the foreground. Pairing is the
/// opt-in — there is no master switch and the listener simply runs while the
/// app does (the pairing window is closed by default; `/pair` refuses then).
class SyncProvider extends ChangeNotifier with WidgetsBindingObserver {
  SyncProvider({
    required ChatService chatService,
    required ChatDatabaseRepository repository,
    required BusinessRepository businessRepository,
    required BusinessPreferences businessPreferences,
    required BusinessStateReloader reloader,
    required Future<Directory> Function() syncDirectory,
    Future<List<LanAddress>> Function()? addressSource,
    Future<bool> Function(List<(String, int)> endpoints)? presenceProbe,
  }) : // Public injection names intentionally omit the private-field prefix
       // (same convention as ChatService's own dependencies).
       // ignore: prefer_initializing_formals
       _chatService = chatService,
       // ignore: prefer_initializing_formals
       _repository = repository,
       // ignore: prefer_initializing_formals
       _businessRepository = businessRepository,
       // ignore: prefer_initializing_formals
       _businessPreferences = businessPreferences,
       // ignore: prefer_initializing_formals
       _reloader = reloader,
       // ignore: prefer_initializing_formals
       _syncDirectory = syncDirectory,
       // ignore: prefer_initializing_formals
       _addressSource = addressSource,
       // ignore: prefer_initializing_formals
       _presenceProbe = presenceProbe;

  final ChatService _chatService;
  final ChatDatabaseRepository _repository;
  final BusinessRepository _businessRepository;
  final BusinessPreferences _businessPreferences;
  final BusinessStateReloader _reloader;
  final Future<Directory> Function() _syncDirectory;

  /// Where [refreshLocalAddresses] enumerates interfaces from. Null means the
  /// real [listLanAddresses]; a test injects a fixed device instead, so it can
  /// move between networks without a NIC.
  final Future<List<LanAddress>> Function()? _addressSource;

  /// Where [refreshPresence] probes endpoints from. Null means the real
  /// [anyEndpointReachable]; a test injects a verdict so a peer can go on- and
  /// offline without a socket.
  final Future<bool> Function(List<(String, int)> endpoints)? _presenceProbe;

  SyncEngine? _engine;
  SyncStore? _store;
  Future<void>? _startFuture;
  bool _stopRequested = false;
  bool _disposed = false;

  /// Notifies the listeners, unless this provider is already disposed.
  ///
  /// Several paths start work that finishes after the widget tree is gone: the
  /// firewall's `netsh` child process, the interface enumeration, a session
  /// that outlives the screen it was started from. Each of them ends in a
  /// notification, and `ChangeNotifier` asserts on a notification after
  /// `dispose` — an assertion that surfaces as an *unhandled* async error, so
  /// it is reported against whatever test (or frame) happens to be running
  /// when it lands rather than against the code that disposed the provider.
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  bool started = false;
  bool starting = false;
  String? startError;
  int? port;

  /// This device's candidate addresses, in interface order. The pairing QR, the
  /// pairing dialog and the "this device" card all read exactly this list.
  List<LanAddress> localAddresses = const [];
  List<SyncPeerRecord> peers = const [];
  final Set<String> busyDeviceIds = {};
  SyncSessionReport? lastReport;

  /// Peers whose remembered endpoints answered the last presence probe. Absent
  /// means offline-or-not-yet-checked; the card renders both as a gray dot
  /// until a probe lands. Refreshed on start, on resume, on a timer while the
  /// app is visible, and after every session.
  final Set<String> onlineDeviceIds = {};

  /// Peers whose probe failed most recently. A single miss does not clear the
  /// dot: a plain connect can lose a race against a Wi-Fi that is waking up, a
  /// peer that is busy answering, or a probe that fired while the network was
  /// moving — and a green dot that flickers gray every half minute is worse
  /// than one that is half a minute stale. Two misses in a row mean it.
  final Set<String> _probeMisses = {};

  /// What the last *session* with a peer proved about reaching it, and when.
  ///
  /// A session is the strongest evidence available: it either exchanged bytes
  /// with the peer (it answered) or found no address that would talk. That is a
  /// stronger claim than the probe's bare TCP connect — an address behind a NAT
  /// port-forward can accept a connection and never complete TLS — so it wins
  /// over the probe for [sessionVerdictTtl], which keeps the moment of the
  /// verdict from outliving the peer's actual state.
  final Map<String, ({bool answered, DateTime at})> _sessionVerdicts = {};

  Timer? _presenceTimer;
  bool _presenceRunning = false;

  /// Live progress of this device's initiator session with [deviceId], or null
  /// when none is running. Read straight from the engine's map, which lives
  /// exactly as long as the session.
  SyncSessionProgress? progressFor(String deviceId) =>
      _engine?.initiatorProgress[deviceId];

  /// Whether the card should draw the green dot.
  ///
  /// A fresh session verdict outranks the probe — see [_sessionVerdicts].
  bool isPeerOnline(String deviceId) => switch (peerPresenceSource(deviceId)) {
    PresenceSource.sessionAnswered || PresenceSource.probe => true,
    PresenceSource.sessionSilent || PresenceSource.unknown => false,
  };

  /// What the dot's answer is based on, so the card can say *why* — a gray dot
  /// from a session that could not talk is a different statement from a gray
  /// dot the probe could not confirm.
  PresenceSource peerPresenceSource(String deviceId) {
    final verdict = _sessionVerdicts[deviceId];
    if (verdict != null &&
        DateTime.now().difference(verdict.at) < sessionVerdictTtl) {
      return verdict.answered
          ? PresenceSource.sessionAnswered
          : PresenceSource.sessionSilent;
    }
    return onlineDeviceIds.contains(deviceId)
        ? PresenceSource.probe
        : PresenceSource.unknown;
  }

  /// Windows only: the inbound rule could not be added without elevation, so
  /// the panel offers the one-click UAC button.
  bool firewallNeedsElevation = false;

  /// The bound port, or the preferred one while starting.
  int? get effectivePort =>
      port ?? (starting ? SyncEngine.kPreferredPort : null);

  /// The engine this provider drives, for tests that have to observe what was
  /// pushed *into* it (the address list the dial orders candidates by) — the
  /// panels and the pairing flow read the provider instead.
  @visibleForTesting
  SyncEngine? get engine => _engine;

  bool get isPairingOpen => _engine?.isPairingOpen ?? false;
  String? get pairingPin => _engine?.pairingPin;
  DateTime? get pairingExpiresAt => _engine?.pairingExpiresAt;

  /// This device's certificate fingerprint (= deviceId) and peer-visible
  /// name; the pairing QR pins the former and carries the latter.
  String? get deviceId => _engine?.identity.deviceId;
  String? get deviceName => _engine?.identity.name;

  /// Starts the listener. Idempotent; safe to call repeatedly (the app calls
  /// it once per launch from a post-frame callback).
  Future<void> start() async {
    if (kIsWeb || started) return;
    final inFlight = _startFuture;
    if (inFlight != null) return inFlight;
    final initialization = _start();
    _startFuture = initialization;
    try {
      await initialization;
    } finally {
      _startFuture = null;
    }
  }

  Future<void> _start() async {
    starting = true;
    startError = null;
    _notify();
    try {
      final directory = await _syncDirectory();
      final directoryPath = directory.path;
      final fallbackName = Platform.localHostname;
      // First-launch RSA keygen takes long enough to jank the UI thread; the
      // identity is plain strings, so it crosses isolate boundaries freely.
      final identity = await Isolate.run(
        () => SyncDeviceIdentity.loadOrCreate(
          Directory(directoryPath),
          fallbackName: fallbackName,
        ),
      );
      if (_stopRequested) return;
      final store = SyncStore(directory);
      final engine = SyncEngine(
        identity: identity,
        store: store,
        dataPlane: SyncDataPlane(
          repository: _repository,
          chatService: _chatService,
          businessRepository: _businessRepository,
          businessPreferences: _businessPreferences,
          reloader: _reloader,
          // Skill bodies ride sync as directory blobs (slice 3); the root is
          // the same one the skills service installs into.
          skillDirectories: SkillDirectorySync(
            await AppDirectories.getSkillsDirectory(),
          ),
        ),
        onStateChanged: _onEngineStateChanged,
        // A beat only repaints the card: it cannot have changed a peer record,
        // and the blob pull fires one per file.
        onProgressChanged: _notify,
      );
      _store = store;
      _engine = engine;
      final boundPort = await engine.start();
      port = boundPort;
      started = true;
      peers = await store.listPeers();
      unawaited(_ensureFirewallRule());
      // Foreground rounds: one right after start ("opened the app" is the
      // pickup journey), then one per resume, throttled by [autoSyncInterval].
      WidgetsBinding.instance.addObserver(this);
      // The app is visible while it starts, so the dots start refreshing now;
      // a lifecycle `resumed` would otherwise not fire until a refocus.
      _startPresenceTimer();
      unawaited(_refreshAddressesThenRound());
      // Desktop graceful exit: stop the listener and drop the ephemeral-port
      // firewall rule (the preferred-port rule stays for next launch).
      AppExitFlush.register(stop);
    } catch (error) {
      startError = '$error';
    } finally {
      starting = false;
      _notify();
    }
  }

  /// Stops the listener. Idempotent; also registered as an exit-flush task.
  Future<void> stop() async {
    _stopRequested = true;
    _stopPresenceTimer();
    final engine = _engine;
    if (engine == null) return;
    final boundPort = port;
    port = null;
    started = false;
    await engine.stop();
    if (Platform.isWindows &&
        boundPort != null &&
        boundPort != SyncEngine.kPreferredPort) {
      unawaited(WindowsFirewall.tryDeleteRule(boundPort));
    }
    _notify();
  }

  Future<void> refreshPeers() async {
    final store = _store;
    if (store == null) return;
    peers = await store.listPeers();
    _notify();
  }

  // ---- pairing ----

  String? openPairing() {
    final engine = _engine;
    if (engine == null) return null;
    return engine.openPairing();
  }

  void cancelPairing() {
    _engine?.cancelPairing();
  }

  Future<SyncPairOutcome> pairWith({
    required String host,
    required int port,
    required String pin,
    String? expectedDeviceId,
  }) async {
    final engine = _engine;
    if (engine == null) {
      return const SyncPairOutcome.failure('no_listener');
    }
    try {
      final record = await engine.pairWith(
        host: host,
        port: port,
        pin: pin,
        expectedDeviceId: expectedDeviceId,
        advertisedAddresses: _advertisedAddresses,
      );
      await refreshPeers();
      // The first sync starts here, not at the next resume: the joiner is the
      // device in hand right now, its app is in the foreground, and the peer
      // that just showed its QR is still running. See [_kickInitialSync].
      _kickInitialSync(record);
      return SyncPairOutcome.success(
        peerName: record.displayName,
        peerDeviceId: record.deviceId,
      );
    } on SyncClientException catch (error) {
      return _mapPairError(error);
    } on SocketException catch (error) {
      return SyncPairOutcome.failure('unreachable', error.message);
    } on TimeoutException catch (error) {
      return SyncPairOutcome.failure('unreachable', error.message);
    } catch (error) {
      return SyncPairOutcome.failure('unknown', '$error');
    }
  }

  /// Pairs from a scanned QR payload: the engine probes the payload's
  /// endpoints, dials them hard-pinned to the scanned fingerprint, and walks
  /// past an address that answers as another device — the pin refused it before
  /// the PIN was sent, so only that address is disqualified. A verdict from the
  /// scanned device itself (a refused PIN, an identity mismatch) ends the
  /// attempt; see [SyncEngine.pairWithCandidates] for the whole taxonomy.
  Future<SyncPairQrOutcome> pairWithQr(SyncPairQrPayload payload) async {
    final engine = _engine;
    if (engine == null) {
      return const SyncPairQrOutcome(
        SyncPairOutcome.failure('no_listener'),
        false,
      );
    }
    final wasKnownPeer = peers.any((p) => p.deviceId == payload.deviceId);
    if (payload.endpoints.isEmpty) {
      // Fingerprint + PIN without an address: the joiner enters the host by
      // hand but keeps the pinning.
      return SyncPairQrOutcome(
        const SyncPairOutcome.failure('no_endpoint_in_qr'),
        wasKnownPeer,
      );
    }
    try {
      final record = await engine.pairWithCandidates(
        endpoints: payload.endpoints,
        pin: payload.pin,
        expectedDeviceId: payload.deviceId,
        advertisedAddresses: _advertisedAddresses,
      );
      await refreshPeers();
      // Same as the typed pairing: the scan just proved the peer reachable.
      _kickInitialSync(record);
      return SyncPairQrOutcome(
        SyncPairOutcome.success(
          peerName: record.displayName,
          peerDeviceId: record.deviceId,
        ),
        wasKnownPeer,
      );
    } on SyncClientException catch (error) {
      return SyncPairQrOutcome(_mapPairError(error), wasKnownPeer);
    } on SocketException catch (error) {
      return SyncPairQrOutcome(
        SyncPairOutcome.failure('unreachable', error.message),
        wasKnownPeer,
      );
    } on TimeoutException catch (error) {
      return SyncPairQrOutcome(
        SyncPairOutcome.failure('unreachable', error.message),
        wasKnownPeer,
      );
    } catch (error) {
      return SyncPairQrOutcome(
        SyncPairOutcome.failure('unknown', '$error'),
        wasKnownPeer,
      );
    }
  }

  /// Starts the first session with a freshly paired peer, fire-and-forget.
  ///
  /// Pairing proves the peer is reachable *right now* — both apps are open, the
  /// joiner's is in the foreground — which is exactly the window the first
  /// (full-history) transfer needs; a mobile OS suspends the app the moment it
  /// leaves it. The card shows the progress and the keep-both-devices-awake
  /// hint while it runs. A busy peer (its own auto-round answered first) is
  /// retried by the next trigger, so fire-and-forget loses nothing.
  void _kickInitialSync(SyncPeerRecord peer) {
    if (peer.endpoints.isEmpty) return;
    unawaited(syncNow(peer.deviceId));
  }

  static SyncPairOutcome _mapPairError(SyncClientException error) {
    switch (error.message) {
      case 'invalid_pin':
        return SyncPairOutcome.failure(
          'invalid_pin',
          error.statusCode?.toString(),
        );
      case 'pair_no_certificate':
        return const SyncPairOutcome.failure('no_certificate');
      case 'pair_identity_mismatch':
        return const SyncPairOutcome.failure('id_mismatch');
      case 'pair_fingerprint_mismatch':
        return const SyncPairOutcome.failure('fingerprint_mismatch');
      default:
        return SyncPairOutcome.failure(
          'unreachable',
          '${error.message}${error.statusCode == null ? '' : ' (${error.statusCode})'}',
        );
    }
  }

  // ---- peers ----

  /// Renames a peer *on this device*. The override rides the record as
  /// `customName` and survives re-pairing; an empty answer keeps the current
  /// name rather than blanking the card.
  Future<void> renamePeer(String deviceId, String name) async {
    final store = _store;
    final peer = peers.where((p) => p.deviceId == deviceId).firstOrNull;
    if (store == null || peer == null) return;
    final trimmed = name.trim();
    if (trimmed.isNotEmpty) peer.customName = trimmed;
    await store.savePeer(peer);
    await refreshPeers();
  }

  Future<void> updatePeerEndpoint(
    String deviceId,
    String host,
    int port,
  ) async {
    final store = _store;
    final peer = peers.where((p) => p.deviceId == deviceId).firstOrNull;
    if (store == null || peer == null) return;
    // Manual repair replaces the whole set: the automatic memory is what failed
    // (or the user would not be typing), so keeping the rest keeps the problem.
    peer.replaceEndpoints(host.trim(), port);
    await store.savePeer(peer);
    await refreshPeers();
  }

  Future<void> unpair(String deviceId) async {
    final engine = _engine;
    if (engine == null) return;
    await engine.unpair(deviceId);
    await refreshPeers();
  }

  Future<SyncSessionReport?> syncNow(String deviceId) async {
    final engine = _engine;
    if (engine == null || busyDeviceIds.contains(deviceId)) return null;
    final peer = peers.where((p) => p.deviceId == deviceId).firstOrNull;
    if (peer == null) return null;
    busyDeviceIds.add(deviceId);
    onlineDeviceIds.add(deviceId);
    _notify();
    try {
      final report = await engine.syncWithPeer(peer);
      lastReport = report;
      _recordSessionVerdict(deviceId, report);
      return report;
    } finally {
      busyDeviceIds.remove(deviceId);
      await refreshPeers();
      unawaited(refreshPresence());
    }
  }

  /// Files what a finished session proved about reaching [deviceId].
  ///
  /// The session outranks the probe, because it demanded what a sync actually
  /// needs — a TLS handshake pinned to the peer's certificate and a session —
  /// where the probe only asked whether something accepts a connection. An
  /// address that answers TCP but never completes the handshake is exactly the
  /// case this exists for: the probe kept calling it online while every session
  /// failed.
  ///
  /// `noEndpoint` records nothing: nothing was dialed, so the probe is still the
  /// only evidence there is.
  void _recordSessionVerdict(String deviceId, SyncSessionReport report) {
    final bool answered;
    switch (report.failure) {
      case SyncFailureReason.unreachable:
      case SyncFailureReason.timeout:
        answered = false;
      case SyncFailureReason.noEndpoint:
        // Nothing was dialed. The session optimistically turned the dot green
        // on its way in, and a peer with no endpoint gives the presence round no
        // probe to correct it — so the leak is closed here and not left to the
        // next refresh, which a round already in flight would not run.
        onlineDeviceIds.remove(deviceId);
        _notify();
        return;
      case SyncFailureReason.peerError:
      case SyncFailureReason.internal:
      case null:
        // Success, a refusal, or a failure that needed an answer to happen: the
        // peer is there. `internal` is the catch-all and covers a failure that
        // never left this device — a manifest build against a broken database, a
        // certificate context that will not open — so a local fault can file
        // "answered" for up to `sessionVerdictTtl`. It is not worth a distinct
        // signal: a 401 refusal is `internal` too, and only one of the two is an
        // answer, so the reason alone cannot grade this.
        answered = true;
    }
    _sessionVerdicts[deviceId] = (answered: answered, at: DateTime.now());
    if (answered) {
      onlineDeviceIds.add(deviceId);
      _probeMisses.remove(deviceId);
    } else {
      onlineDeviceIds.remove(deviceId);
    }
    _notify();
  }

  // ---- presence (the online dots) ----

  /// Probes every paired peer's remembered endpoints in parallel and republishes
  /// the online set. A peer mid-session is online by definition — the session
  /// itself is the proof — so busy peers keep their dot whatever the probe says,
  /// and a single failed probe is remembered rather than acted on (see
  /// [_probeMisses]).
  Future<void> refreshPresence() async {
    if (!started || _presenceRunning) return;
    _presenceRunning = true;
    try {
      final probe = _presenceProbe ?? anyEndpointReachable;
      final targets = [
        for (final peer in peers)
          if (peer.endpoints.isNotEmpty) peer,
      ];
      final answers = await Future.wait([
        for (final peer in targets)
          busyDeviceIds.contains(peer.deviceId)
              ? Future.value(true)
              : probe([
                  for (final endpoint in peer.endpoints)
                    (endpoint.host, endpoint.port),
                ]),
      ]);
      for (var i = 0; i < targets.length; i++) {
        final deviceId = targets[i].deviceId;
        if (answers[i]) {
          onlineDeviceIds.add(deviceId);
          _probeMisses.remove(deviceId);
        } else if (!_probeMisses.add(deviceId)) {
          // The second miss in a row: the peer is not answering.
          onlineDeviceIds.remove(deviceId);
        }
      }
      // A peer whose record changed since the last round (unpaired, or its
      // endpoints replaced) must not keep a dot from the previous set.
      final known = {for (final peer in targets) peer.deviceId};
      onlineDeviceIds.removeWhere((id) => !known.contains(id));
      _probeMisses.removeWhere((id) => !known.contains(id));
      _sessionVerdicts.removeWhere((id, _) => !known.contains(id));
      _notify();
    } finally {
      _presenceRunning = false;
    }
  }

  void _startPresenceTimer() {
    _presenceTimer?.cancel();
    _presenceTimer = Timer.periodic(presenceRefreshInterval, (_) {
      unawaited(refreshPresence());
    });
  }

  void _stopPresenceTimer() {
    _presenceTimer?.cancel();
    _presenceTimer = null;
  }

  // ---- automatic rounds (foreground) ----

  DateTime? _lastAutoSyncAt;
  bool _autoRoundRunning = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Desktop fires `resumed` on every window focus gain too; the global
    // throttle in [shouldAutoSyncNow] is what keeps that cheap.
    if (state == AppLifecycleState.resumed) {
      _startPresenceTimer();
      unawaited(_refreshAddressesThenRound());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      // No point probing for peers nobody is looking at; the next resume
      // re-probes immediately.
      _stopPresenceTimer();
    }
  }

  /// A foreground round, on an address list that is already fresh.
  ///
  /// The enumeration and the round used to be fired side by side, which leaves
  /// the round racing a platform call: the list has to land first, or the round
  /// computes its dial order from an empty one and the same-subnet preference
  /// the probing exists for is simply absent — on the round right after a
  /// launch, which is the pickup journey. Awaiting it costs the enumeration's
  /// own latency and buys a round that dials the network this device stands on.
  Future<void> _refreshAddressesThenRound() async {
    await refreshLocalAddresses();
    await Future.wait([autoSyncRound(), refreshPresence()]);
  }

  /// One quiet round over every paired peer that has an endpoint: no
  /// snackbar, results land on the peer cards as their last report. Skipped
  /// entirely while a round is still running or the throttle window has not
  /// elapsed; the manual button is never throttled.
  Future<void> autoSyncRound() async {
    if (!started || peers.isEmpty || _autoRoundRunning) return;
    final now = DateTime.now();
    if (!shouldAutoSyncNow(now, _lastAutoSyncAt)) return;
    _lastAutoSyncAt = now;
    _autoRoundRunning = true;
    try {
      for (final peer in List.of(peers)) {
        if (peer.primaryEndpoint == null) continue;
        if (busyDeviceIds.contains(peer.deviceId)) continue;
        try {
          await syncNow(peer.deviceId);
        } catch (_) {
          // A failed round already shows on the peer card; the round moves on.
        }
      }
    } finally {
      _autoRoundRunning = false;
    }
  }

  // ---- firewall (Windows) ----

  /// One-click elevated rule add; returns whether the rule exists afterwards.
  Future<bool> elevateFirewall() async {
    final boundPort = port;
    if (boundPort == null) return false;
    final ok = await WindowsFirewall.addRuleElevated(boundPort);
    firewallNeedsElevation = !ok;
    _notify();
    return ok;
  }

  Future<void> _ensureFirewallRule() async {
    if (!Platform.isWindows) return;
    final boundPort = port;
    if (boundPort == null) return;
    if (await WindowsFirewall.ruleExists(boundPort)) return;
    final added = await WindowsFirewall.tryAddRule(boundPort);
    firewallNeedsElevation = !added;
    _notify();
  }

  /// This device's own addresses as sent to a peer while pairing, so the
  /// responder remembers more than the single address the pairing arrived from.
  List<String> get _advertisedAddresses => [
    for (final address in localAddresses) address.address,
  ];

  /// Re-enumerates this device's addresses. Called on start, on every resume and
  /// whenever the pairing dialog opens: a laptop changes networks without
  /// relaunching the app — and on a desktop, pulling a cable or joining Wi-Fi
  /// fires no lifecycle event at all — while the pairing QR and the typed
  /// endpoint list are only ever as good as the list this refreshes.
  Future<void> refreshLocalAddresses() async {
    final source = _addressSource ?? listLanAddresses;
    localAddresses = selectLanCandidates(await source());
    // The engine orders dial candidates by which network they sit on, so it
    // reads the same list the pairing screen shows.
    _engine?.localAddresses = localAddresses;
    _notify();
  }

  void _onEngineStateChanged() {
    // Peer records mutate as sessions finish on either side; refresh them so
    // the panels' cards reflect last-sync outcomes without manual reload.
    // The notify is immediate: engine state also covers the session *progress*
    // beats, which change far more often than the peer files.
    _notify();
    unawaited(refreshPeers());
  }

  @override
  void dispose() {
    _disposed = true;
    _stopPresenceTimer();
    WidgetsBinding.instance.removeObserver(this);
    AppExitFlush.unregister(stop);
    super.dispose();
  }
}
