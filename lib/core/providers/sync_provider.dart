import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../database/chat_database_repository.dart';
import '../services/app_exit_flush.dart';
import '../services/chat/chat_service.dart';
import '../services/sync/sync_client.dart';
import '../services/sync/sync_data_plane.dart';
import '../services/sync/sync_engine.dart';
import '../services/sync/sync_identity.dart';
import '../services/sync/sync_local_addresses.dart';
import '../services/sync/sync_store.dart';
import '../services/sync/windows_firewall.dart';

/// Outcome of a pairing attempt, with a stable error code the UI maps to a
/// localized message (`invalid_pin`, `unreachable`, `no_certificate`,
/// `id_mismatch`, `no_listener`, `unknown`).
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

/// UI-facing state of the LAN sync engine (ADR-0002, slice 1b).
///
/// The engine is transport + session logic; this provider owns its lifecycle:
/// start the listener with the app, keep the peer list the panels show in
/// sync with the store, and mediate the pairing window. Pairing is the
/// opt-in — there is no master switch and the listener simply runs while the
/// app does (the pairing window is closed by default; `/pair` refuses then).
class SyncProvider extends ChangeNotifier {
  SyncProvider({
    required ChatService chatService,
    required ChatDatabaseRepository repository,
    required Future<Directory> Function() syncDirectory,
  }) : // Public injection names intentionally omit the private-field prefix
       // (same convention as ChatService's own dependencies).
       // ignore: prefer_initializing_formals
       _chatService = chatService,
       // ignore: prefer_initializing_formals
       _repository = repository,
       // ignore: prefer_initializing_formals
       _syncDirectory = syncDirectory;

  final ChatService _chatService;
  final ChatDatabaseRepository _repository;
  final Future<Directory> Function() _syncDirectory;

  SyncEngine? _engine;
  SyncStore? _store;
  Future<void>? _startFuture;
  bool _stopRequested = false;

  bool started = false;
  bool starting = false;
  String? startError;
  int? port;
  List<String> localIps = const [];
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
        ),
        onStateChanged: _onEngineStateChanged,
      );
      _store = store;
      _engine = engine;
      final boundPort = await engine.start();
      port = boundPort;
      started = true;
      peers = await store.listPeers();
      unawaited(_refreshLocalIps());
      unawaited(_ensureFirewallRule());
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
  }) async {
    final engine = _engine;
    if (engine == null) {
      return const SyncPairOutcome.failure('no_listener');
    }
    try {
      await engine.pairWith(host: host, port: port, pin: pin);
      await refreshPeers();
      return const SyncPairOutcome.success();
    } on SyncClientException catch (error) {
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
        default:
          return SyncPairOutcome.failure(
            'unreachable',
            '${error.message}${error.statusCode == null ? '' : ' (${error.statusCode})'}',
          );
      }
    } on SocketException catch (error) {
      return SyncPairOutcome.failure('unreachable', error.message);
    } on TimeoutException catch (error) {
      return SyncPairOutcome.failure('unreachable', error.message);
    } catch (error) {
      return SyncPairOutcome.failure('unknown', '$error');
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

  Future<void> _refreshLocalIps() async {
    localIps = await listLocalIpv4s();
    notifyListeners();
  }

  void _onEngineStateChanged() {
    // Peer records mutate as sessions finish on either side; refresh them so
    // the panels' cards reflect last-sync outcomes without manual reload.
    unawaited(refreshPeers());
  }

  @override
  void dispose() {
    AppExitFlush.unregister(stop);
    super.dispose();
  }
}
