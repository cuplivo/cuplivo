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
import '../services/sync/sync_client.dart';
import '../services/sync/sync_data_plane.dart';
import '../services/sync/sync_engine.dart';
import '../services/sync/sync_identity.dart';
import '../services/sync/sync_local_addresses.dart';
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

  const SyncPairOutcome.success()
    : success = true,
      errorCode = null,
      errorDetail = null;

  const SyncPairOutcome.failure(this.errorCode, [this.errorDetail])
    : success = false;
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
       _syncDirectory = syncDirectory;

  final ChatService _chatService;
  final ChatDatabaseRepository _repository;
  final BusinessRepository _businessRepository;
  final BusinessPreferences _businessPreferences;
  final BusinessStateReloader _reloader;
  final Future<Directory> Function() _syncDirectory;

  SyncEngine? _engine;
  SyncStore? _store;
  Future<void>? _startFuture;
  bool _stopRequested = false;

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

  /// Windows only: the inbound rule could not be added without elevation, so
  /// the panel offers the one-click UAC button.
  bool firewallNeedsElevation = false;

  /// The bound port, or the preferred one while starting.
  int? get effectivePort =>
      port ?? (starting ? SyncEngine.kPreferredPort : null);

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
    notifyListeners();
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
      );
      _store = store;
      _engine = engine;
      final boundPort = await engine.start();
      port = boundPort;
      started = true;
      peers = await store.listPeers();
      unawaited(_refreshLocalAddresses());
      unawaited(_ensureFirewallRule());
      // Foreground rounds: one right after start ("opened the app" is the
      // pickup journey), then one per resume, throttled by [autoSyncInterval].
      WidgetsBinding.instance.addObserver(this);
      unawaited(autoSyncRound());
      // Desktop graceful exit: stop the listener and drop the ephemeral-port
      // firewall rule (the preferred-port rule stays for next launch).
      AppExitFlush.register(stop);
    } catch (error) {
      startError = '$error';
    } finally {
      starting = false;
      notifyListeners();
    }
  }

  /// Stops the listener. Idempotent; also registered as an exit-flush task.
  Future<void> stop() async {
    _stopRequested = true;
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
    notifyListeners();
  }

  Future<void> refreshPeers() async {
    final store = _store;
    if (store == null) return;
    peers = await store.listPeers();
    notifyListeners();
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
      await engine.pairWith(
        host: host,
        port: port,
        pin: pin,
        expectedDeviceId: expectedDeviceId,
      );
      await refreshPeers();
      return const SyncPairOutcome.success();
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

  /// Pairs from a scanned QR payload: tries the payload's endpoints in
  /// order, hard-pinning the scanned fingerprint. A dead endpoint (refused
  /// connection, timeout) moves on to the next candidate; an *answering*
  /// endpoint that is wrong (bad PIN, wrong certificate, identity mismatch)
  /// stops immediately — the same answer awaits on every candidate.
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
    Object? lastConnectivityDetail;
    for (final (host, endpointPort) in payload.endpoints) {
      try {
        await engine.pairWith(
          host: host,
          port: endpointPort,
          pin: payload.pin,
          expectedDeviceId: payload.deviceId,
        );
        await refreshPeers();
        return SyncPairQrOutcome(const SyncPairOutcome.success(), wasKnownPeer);
      } on SyncClientException catch (error) {
        return SyncPairQrOutcome(_mapPairError(error), wasKnownPeer);
      } on SocketException catch (error) {
        lastConnectivityDetail = error.message;
      } on TimeoutException catch (error) {
        lastConnectivityDetail = error.message;
      } catch (error) {
        return SyncPairQrOutcome(
          SyncPairOutcome.failure('unknown', '$error'),
          wasKnownPeer,
        );
      }
    }
    return SyncPairQrOutcome(
      SyncPairOutcome.failure('unreachable', '$lastConnectivityDetail'),
      wasKnownPeer,
    );
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

  Future<void> renamePeer(String deviceId, String name) async {
    final store = _store;
    final peer = peers.where((p) => p.deviceId == deviceId).firstOrNull;
    if (store == null || peer == null) return;
    peer.name = name.trim().isEmpty ? peer.name : name.trim();
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
    peer.lastHost = host.trim();
    peer.lastPort = port;
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
    notifyListeners();
    try {
      final report = await engine.syncWithPeer(peer);
      lastReport = report;
      return report;
    } finally {
      busyDeviceIds.remove(deviceId);
      await refreshPeers();
    }
  }

  // ---- automatic rounds (foreground) ----

  DateTime? _lastAutoSyncAt;
  bool _autoRoundRunning = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Desktop fires `resumed` on every window focus gain too; the global
    // throttle in [shouldAutoSyncNow] is what keeps that cheap.
    if (state == AppLifecycleState.resumed) {
      unawaited(autoSyncRound());
    }
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
        if (peer.lastHost == null || peer.lastPort == null) continue;
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
    notifyListeners();
    return ok;
  }

  Future<void> _ensureFirewallRule() async {
    if (!Platform.isWindows) return;
    final boundPort = port;
    if (boundPort == null) return;
    if (await WindowsFirewall.ruleExists(boundPort)) return;
    final added = await WindowsFirewall.tryAddRule(boundPort);
    firewallNeedsElevation = !added;
    notifyListeners();
  }

  Future<void> _refreshLocalAddresses() async {
    localAddresses = selectLanCandidates(await listLanAddresses());
    notifyListeners();
  }

  void _onEngineStateChanged() {
    // Peer records mutate as sessions finish on either side; refresh them so
    // the panels' cards reflect last-sync outcomes without manual reload.
    unawaited(refreshPeers());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppExitFlush.unregister(stop);
    super.dispose();
  }
}
