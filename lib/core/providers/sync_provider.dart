import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

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
import '../services/sync/sync_endpoint_prober.dart';
import '../services/sync/sync_engine.dart';
import '../services/sync/sync_identity.dart';
import '../services/sync/sync_local_addresses.dart';
import '../services/sync/sync_models.dart';
import '../services/sync/sync_pair_qr.dart';
import '../services/sync/sync_store.dart';
import '../services/sync/windows_firewall.dart';
import '../services/sync/workspace_content_sync.dart';

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

/// How often the online dots re-probe while the app is visible.
///
/// An authenticated probe is one request the peer answers with a bare status
/// line, and the figures it produces — a per-endpoint latency — are worth being
/// fresh: ten seconds is a pace a person can watch. The steady-state cost stays
/// at the head endpoints; the silent tail is only walked on a full round (see
/// `selectProbeTargets`).
const presenceRefreshInterval = Duration(seconds: 10);

/// Where a peer's current online/offline answer came from.
enum PresenceSource {
  /// Nothing has an opinion yet: no probe has landed and no session has run.
  /// The card draws the gray dot, which is the honest default.
  unknown,

  /// A session — this device's or the peer's — was the last thing to speak to
  /// the peer (a refusal counts, it is an answer). Whether that answer was
  /// "here" or "silence" is [isPeerOnline], not this: a session that found
  /// nothing is `session` beside a grey dot.
  session,

  /// No session evidence since the last probe; the last authenticated probe
  /// reached one of the remembered endpoints.
  probe,
}

/// One successful automatic-round session that brought data to this device —
/// what the app-level announcer turns into a toast the user sees away from
/// the sync panel. The peer's name rides along because the record (and its
/// possible rename) is read at emit time.
class SyncArrival {
  const SyncArrival(this.peerName, this.report);

  final String peerName;
  final SyncSessionReport report;
}

/// One managed workspace as the panel's workspace section shows it.
///
/// Assembled here rather than in the widget because two very different costs
/// meet in this row: the workspace list is a database read, and the file count
/// is a stat walk of a folder that may hold thousands of files. The provider
/// does the walk once per refresh, off the UI isolate, and the panel renders
/// whatever landed.
class SyncWorkspaceSummary {
  const SyncWorkspaceSummary({
    required this.id,
    required this.name,
    required this.fileCount,
    required this.totalBytes,
    required this.truncated,
    required this.enabled,
    this.unreadable = false,
  });

  final String id;
  final String name;

  /// How many files ride, or — when [truncated] — how many the walk had seen
  /// when it passed the cap. A lower bound either way, which is why the panel
  /// writes it with a plus.
  final int fileCount;
  final int totalBytes;

  /// Over the file or byte cap: this workspace's content is not synced at all,
  /// and its figures are lower bounds.
  final bool truncated;

  /// Part of the folder could not be read, so this device is not sharing it
  /// this session: a table missing those files would tell the peer to delete
  /// them (see `WorkspaceContentIndex.incomplete`).
  final bool unreadable;

  /// The device-local switch. Off means this device neither uploads nor
  /// downloads this workspace's files; its record still syncs, because a row
  /// this device stopped publishing would be read by the peer as a deletion.
  final bool enabled;

  /// Whether the section counts this workspace as one that is syncing content.
  bool get syncing => enabled && !truncated && !unreadable;

  SyncWorkspaceSummary copyWith({bool? enabled}) => SyncWorkspaceSummary(
    id: id,
    name: name,
    fileCount: fileCount,
    totalBytes: totalBytes,
    truncated: truncated,
    unreadable: unreadable,
    enabled: enabled ?? this.enabled,
  );
}

/// Whether a session changed what this device shows: anything that arrived
/// here — conversations, message edits or deletions, business rows, files,
/// skills. A session that only sent (the peer got the news) or moved nothing
/// is not an arrival; announcing it would train the user to dismiss toasts.
///
/// Every counter read here is the *incoming* half of its pair. Business rows
/// are the trap: [SyncSessionReport.entityRows]/`preferenceRows` add both
/// directions, because the card's "moved" chip wants the total, so only the
/// received counters may be consulted here.
bool syncBroughtDataHere(SyncSessionReport report) {
  return report.conversationsReceived > 0 ||
      report.messagesUpserted > 0 ||
      report.messagesDeleted > 0 ||
      report.conversationsDeletedLocally > 0 ||
      report.entityRowsReceived > 0 ||
      report.preferenceRowsReceived > 0 ||
      report.blobsMoved > 0 ||
      report.skillsUpdated > 0 ||
      // Workspace files are data this device now shows in a file manager, and a
      // file the peer deleted is the same news in reverse.
      report.workspaceFiles > 0 ||
      report.workspaceFilesRemoved > 0;
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
    EndpointProbeFn? endpointProbe,
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
       _endpointProbe = endpointProbe;

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
  /// authenticated probe against the peer's listener; a test injects per-endpoint
  /// verdicts so a peer can go on- and offline without a socket.
  final EndpointProbeFn? _endpointProbe;

  SyncEngine? _engine;
  SyncStore? _store;

  /// The workspace content plane, once the engine owns one: the panel's rows
  /// come from here (the index walk and the device-local switch), and the
  /// engine reads the same plane during a session.
  WorkspaceContentSync? _workspaceContent;
  Future<void>? _startFuture;
  bool _stopRequested = false;
  bool _disposed = false;
  bool _observingLifecycle = false;
  bool _shutdownRegistered = false;

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

  /// Peers the current evidence says are online: an authenticated probe that
  /// reached a remembered endpoint, or a session in flight past its dial.
  /// Absent means offline-or-not-yet-checked; the card renders both as a gray
  /// dot until evidence lands. Never fed by an attempt alone — a dial in flight
  /// proves nothing.
  final Set<String> onlineDeviceIds = {};

  /// Peers whose probe failed most recently. A single miss does not clear the
  /// dot: a probe can lose a race against a Wi-Fi that is waking up, or fire
  /// while the network is moving — and a green dot that flickers gray every ten
  /// seconds is worse than one that is a tick stale. Two misses in a row mean
  /// it.
  final Set<String> _probeMisses = {};

  /// The last authenticated probe answer per endpoint, per peer. This is what
  /// the cards draw their latency from, and what the dial orders candidates by
  /// when it is fresh (the engine reads the same figures through
  /// [SyncEngine.endpointProbes]).
  final Map<String, Map<(String, int), EndpointProbeResult>> _probeResults = {};

  /// Peers a session has answered for. The dot prefers "a session talked to
  /// it" over "a probe answered", because that is the stronger statement — and
  /// the panel's tooltip says which one it is reporting.
  final Set<String> _sessionEvidence = {};

  /// The next tick walks every endpoint instead of the head ones. Set by every
  /// moment that changes what this device knows — start, resume, a panel
  /// opening, a finished session, a completed pairing — so a peer that moved to
  /// an address the warm set never proved is found at once, not after the tail
  /// is tried for some other reason.
  bool _fullProbePending = true;

  Timer? _presenceTimer;
  bool _presenceRunning = false;

  /// Successful automatic-round arrivals, for the app-level announcer. The
  /// provider emits; the announcer decides what a toast looks like. Broadcast,
  /// because several listeners may exist.
  final StreamController<SyncArrival> _arrivals =
      StreamController<SyncArrival>.broadcast();

  Stream<SyncArrival> get autoSyncArrivals => _arrivals.stream;

  /// How many sync panels are *visible* (the mobile page and the desktop pane
  /// render the same body). While one is, the user is looking at the cards,
  /// which say everything a toast would; arrivals are not announced.
  int _panelViewers = 0;

  /// The panel's workspace rows, or null before this device has read them.
  ///
  /// Null and empty mean different things: null is "nothing has been walked
  /// yet" (the section stays out of the panel rather than showing a row it
  /// cannot fill), while an empty list is "this device has no managed
  /// workspaces" — the same fact, once known.
  List<SyncWorkspaceSummary>? workspaceSummaries;

  bool _workspaceRefreshRunning = false;

  /// Called by the panel body when it becomes visible and hidden again — not on
  /// mount: the desktop pane stays mounted in the home page's `IndexedStack`
  /// after the user leaves the settings tab. The counter (not a bool) is what
  /// keeps an odd dispose order from silencing a live panel.
  void panelOpened() {
    _panelViewers++;
    // A panel the user opened is the last place "listener not running" should be
    // readable: if the listener is down, start it rather than waiting for the
    // next resume. Scheduled, not called: the panel opens this from
    // `didChangeDependencies`, which is the build phase, and `start()` notifies
    // before its first `await` — notifying an ancestor provider from inside a
    // build is the one shape `markNeedsBuild` refuses. A microtask drains only
    // after the frame, so the start lands outside it (and unlike a post-frame
    // callback it does not need a frame, which the provider's own tests have no
    // way to produce).
    scheduleMicrotask(ensureListening);
    // The user is looking at the cards: this is the moment to show every
    // endpoint's figure, including the tail's, rather than the head's only.
    _fullProbePending = true;
    unawaited(refreshPresence());
    // And the moment to count the workspaces: the walk is a stat scan whose
    // result is only ever read by this panel.
    unawaited(refreshWorkspaceContent());
  }

  void panelClosed() {
    if (_panelViewers > 0) _panelViewers--;
  }

  /// Live progress of this device's initiator session with [deviceId], or null
  /// when none is running. Read straight from the engine's map, which lives
  /// exactly as long as the session.
  SyncSessionProgress? progressFor(String deviceId) =>
      _engine?.initiatorProgress[deviceId];

  /// Whether the card should draw the green dot.
  bool isPeerOnline(String deviceId) => onlineDeviceIds.contains(deviceId);

  /// What the dot's answer is based on, so the card can say *why* — a gray dot
  /// beside nothing at all is a different statement from a gray dot the last
  /// session could not talk through.
  PresenceSource peerPresenceSource(String deviceId) {
    if (_sessionEvidence.contains(deviceId)) return PresenceSource.session;
    return onlineDeviceIds.contains(deviceId)
        ? PresenceSource.probe
        : PresenceSource.unknown;
  }

  /// The last probe answer for one endpoint, or null when nothing probed it in
  /// this launch. The card's latency chip reads this; the peer record's
  /// persisted figure is the fallback for a panel opened before the first
  /// round lands.
  EndpointProbeResult? probeResultFor(String deviceId, String host, int port) =>
      _probeResults[deviceId]?[(host, port)];

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

  /// Starts the listener. Idempotent; safe to call repeatedly (the app calls it
  /// once per launch from a post-frame callback, and [ensureListening] calls it
  /// again from the moments the app is usable but the listener is down).
  Future<void> start() async {
    if (kIsWeb || _disposed || started || starting) return;
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

  /// Starts the listener when it is down and nothing is already trying.
  ///
  /// The app is usable whether or not the listener is up, so this is a no-op in
  /// the normal case and the repair path otherwise: a tray restore and a panel
  /// opening are the two moments the user would otherwise see "listener not
  /// running" with no way back short of restarting the app (#1036).
  void ensureListening() {
    if (_disposed || started || starting) return;
    unawaited(start());
  }

  Future<void> _start() async {
    // A start is a new attempt, not a continuation of the stop that preceded
    // it: keeping the flag set is what made a stopped listener unstartable for
    // the rest of the launch.
    _stopRequested = false;
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
      final workspaceContent = WorkspaceContentSync(
        businessRepository: _businessRepository,
        store: store,
        resolveRoot: AppDirectories.workspaceFilesDir,
      );
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
          // Managed workspace folders ride as files (slice 18); the root
          // resolver is the same one the workspace provider hands the tools.
          workspaceContent: workspaceContent,
        ),
        onStateChanged: _onEngineStateChanged,
        // A beat can mark a peer online (see [_onEngineProgressChanged]); a
        // beat cannot have changed a peer record, and the blob pull fires one
        // per file.
        onProgressChanged: _onEngineProgressChanged,
        // The answered half of a session is a session this device never
        // started, so its arrival reaches the user only if the engine hands
        // it over (see [_onEngineResponderSession]).
        onResponderSession: _onEngineResponderSession,
        // A session whose probe snapshot had gone stale ran its own round; the
        // figures belong on the cards like any tick's, and become the snapshot
        // the next session reuses.
        onProbes: _onEngineProbes,
      );
      _store = store;
      _engine = engine;
      _workspaceContent = workspaceContent;
      final boundPort = await engine.start();
      port = boundPort;
      started = true;
      peers = await store.listPeers();
      unawaited(_ensureFirewallRule());
      // Foreground rounds: one right after start ("opened the app" is the
      // pickup journey), then one per resume, throttled by [autoSyncInterval].
      if (!_observingLifecycle) {
        _observingLifecycle = true;
        WidgetsBinding.instance.addObserver(this);
      }
      // The app is visible while it starts, so the dots start refreshing now;
      // a lifecycle `resumed` would otherwise not fire until a refocus.
      _startPresenceTimer();
      unawaited(_refreshAddressesThenRound());
      // Desktop graceful exit: stop the listener and drop the ephemeral-port
      // firewall rule (the preferred-port rule stays for next launch). This is
      // a shutdown task, not an exit *flush*: a close that only hides to the
      // tray runs the flush registry while the process keeps running.
      if (!_shutdownRegistered) {
        _shutdownRegistered = true;
        AppShutdown.register(stop);
      }
    } catch (error) {
      startError = '$error';
    } finally {
      starting = false;
      _notify();
    }
  }

  /// Stops the listener. Idempotent.
  ///
  /// Registered with [AppShutdown], not [AppExitFlush]: this is process
  /// teardown, and an exit *request* is not proof that the process is going
  /// away — a close that only hides to the tray asks the same question. The
  /// provider stays startable afterwards ([start] clears `_stopRequested`).
  Future<void> stop() async {
    _stopRequested = true;
    _stopPresenceTimer();
    _cancelBusyRetries();
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
    // A pairing is one of the moments the endpoint set changed: the QR's
    // candidates and the address just proved are new, so the next probe round
    // should cover all of them.
    _reprobe();
    // Fire-and-forget, and it reports its own failures on the card. An
    // exception escaping here would surface as an unhandled async error
    // attributed to whatever ran next.
    unawaited(syncNow(peer.deviceId).catchError((Object _) => null));
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
    final trimmed = name.trim();
    if (store == null) return;
    // Merged into the record on disk, not written onto the copy this list holds:
    // a session may have written its own outcome to that record since, and a
    // whole-record write from an older copy would erase it (see `mutatePeer`).
    await store.mutatePeer(deviceId, (peer) {
      if (trimmed.isEmpty) return false;
      peer.customName = trimmed;
      return true;
    });
    await refreshPeers();
  }

  /// Names one remembered address of [deviceId] ("家中网络"), or clears the name
  /// with a blank one. Per address and not per peer: the same laptop is a
  /// different place on every network the pair has met, and those are the tiles
  /// the user is naming.
  Future<void> renamePeerEndpoint(
    String deviceId,
    String host,
    int port,
    String? name,
  ) async {
    final store = _store;
    if (store == null) return;
    var renamed = false;
    await store.mutatePeer(deviceId, (peer) {
      renamed = peer.renameEndpoint(host, port, name);
      return renamed;
    });
    if (!renamed) return;
    await refreshPeers();
  }

  /// Repairs one remembered address in place. The address is what failed, so it
  /// is the only thing replaced: the tile keeps its name, its session count and
  /// its probe history, and the other addresses are left alone — they are the
  /// memory of the networks the pair has already met.
  Future<void> editPeerEndpoint(
    String deviceId,
    String host,
    int port,
    String newHost,
    int newPort,
  ) async {
    final store = _store;
    if (store == null) return;
    var edited = false;
    await store.mutatePeer(deviceId, (peer) {
      edited = peer.editEndpoint(host, port, newHost.trim(), newPort);
      return edited;
    });
    if (!edited) return;
    // The measurement belonged to the address that was just replaced, so it goes
    // with it: the tile shows no latency until the new address answers.
    _probeResults[deviceId]?.remove((host, port));
    await refreshPeers();
    _reprobe();
  }

  /// Remembers an address the user typed for a peer — the repair a peer with
  /// none asks for, and the second network a peer that has already synced once
  /// is about to be met on.
  ///
  /// Returns what happened instead of nothing: at the endpoint cap the address
  /// is *refused* rather than admitted by evicting one this pair has actually
  /// synced over, and the caller has to be able to tell the user that. A silent
  /// `void` here is what made "the set is full" indistinguishable from "saved".
  Future<SyncEndpointAdd> addPeerEndpoint(
    String deviceId,
    String host,
    int port,
  ) async {
    final store = _store;
    if (store == null) return SyncEndpointAdd.invalid;
    var outcome = SyncEndpointAdd.invalid;
    await store.mutatePeer(deviceId, (peer) {
      outcome = peer.addEndpoint(host, port);
      return outcome == SyncEndpointAdd.added;
    });
    if (outcome != SyncEndpointAdd.added) return outcome;
    await refreshPeers();
    _reprobe();
    return outcome;
  }

  /// The endpoint set changed: the next probe round walks all of it, including
  /// the address that just joined, and runs now rather than at the next tick.
  void _reprobe() {
    _fullProbePending = true;
    unawaited(refreshPresence());
  }

  /// Forgets one remembered address of [deviceId] — the management view's
  /// per-endpoint delete. The last one may go too: a peer with no address is a
  /// state the panel already names (`no_endpoint` asks for one), and refusing
  /// would trap an address the user knows is wrong.
  Future<void> removePeerEndpoint(
    String deviceId,
    String host,
    int port,
  ) async {
    final store = _store;
    if (store == null) return;
    var removed = false;
    await store.mutatePeer(deviceId, (peer) {
      removed = peer.removeEndpoint(host, port);
      return removed;
    });
    if (!removed) return;
    _probeResults[deviceId]?.remove((host, port));
    await refreshPeers();
    _publishProbesIfStarted();
    _notify();
  }

  Future<void> unpair(String deviceId) async {
    final engine = _engine;
    if (engine == null) return;
    await engine.unpair(deviceId);
    await refreshPeers();
  }

  /// Runs one session with [deviceId].
  ///
  /// [automatic] marks a session this device started on its own (a foreground
  /// round) rather than one the user pressed for: a manual press already gets
  /// its snackbar from the card, and its user is on the panel — so only an
  /// automatic session that *brought data here* is announced on
  /// [autoSyncArrivals], and only while no panel is visible to show the same
  /// news on its card.
  Future<SyncSessionReport?> syncNow(
    String deviceId, {
    bool automatic = false,
    bool retryAttempt = false,
  }) async {
    final engine = _engine;
    if (engine == null || busyDeviceIds.contains(deviceId)) return null;
    final peer = peers.where((p) => p.deviceId == deviceId).firstOrNull;
    if (peer == null) return null;
    busyDeviceIds.add(deviceId);
    // No online mark here: a round that has merely started has proved
    // nothing — trying to reach a peer is not reaching it, and an automatic
    // round against a sleeping peer used to paint the dot green for exactly
    // the seconds its dial spent failing. The dot follows evidence: the beat
    // past the dial ([_onEngineProgressChanged]) or the session's verdict
    // ([_recordSessionVerdict]).
    _notify();
    try {
      final report = await engine.syncWithPeer(peer);
      lastReport = report;
      _recordSessionVerdict(deviceId, report);
      // One retry for the two refusals that mean "this pair tried at the same
      // moment" — from *every* caller: the manual button and the post-pairing
      // kick used to get none, so the five-second retry the ADR promises was only
      // ever true of an automatic round. Neither arms another, which is what
      // keeps a pair that keeps colliding from becoming a tight loop.
      //
      // `superseded` is the crossing case: each side's hello landed while its own
      // dial was unanswered, so each yielded and answered, and neither client is
      // left to drive either session — the pair then refuses its own dials until
      // the yielded sessions expire. Nothing here retries *sooner* than that
      // (the base delay is longer than the yielded window); the retry exists so
      // the pair recovers by itself instead of waiting for the next automatic
      // trigger a minute later, and it is salted per attempt so two devices whose
      // rounds keep landing in the same instant drift apart instead of crossing
      // again by construction.
      switch (report.refusal) {
        case SyncRefusalReason.busy:
        case SyncRefusalReason.superseded:
          if (!retryAttempt) {
            _scheduleBusyRetry(
              deviceId,
              decorrelate: report.refusal == SyncRefusalReason.superseded,
            );
          }
        case _:
          break;
      }
      // A session is the one moment the persisted endpoint figures are worth
      // writing: it is where a "last connected" stamp belongs, and the probe
      // counters ride along instead of costing one file write per tick.
      await _persistProbeStats(deviceId);
      if (automatic &&
          report.success &&
          _panelViewers == 0 &&
          syncBroughtDataHere(report)) {
        _announce(SyncArrival(peer.displayName, report));
      }
      return report;
    } finally {
      busyDeviceIds.remove(deviceId);
      // The set may have moved under the session (a new address promoted), so
      // the next tick is a full one: the tail is where a peer that just moved
      // will be.
      _fullProbePending = true;
      await refreshPeers();
      unawaited(refreshPresence());
      // A session is the one thing that changes a workspace's file count
      // without the file manager being involved.
      unawaited(refreshWorkspaceContent());
    }
  }

  /// Files what a finished session proved about reaching [deviceId].
  ///
  /// A session is the strongest thing that can happen to a peer: it either
  /// exchanged bytes (an answer, refusals included) or found nothing that would
  /// talk. The probe now authenticates too, so the two agree much more often —
  /// but a session also proves the *data plane* works, and it is the evidence a
  /// device that started nothing has ([_onEngineResponderSession]).
  ///
  /// `noEndpoint` records nothing: nothing was dialed, so the probe is still the
  /// only evidence there is.
  void _recordSessionVerdict(String deviceId, SyncSessionReport report) {
    switch (report.refusal) {
      case SyncRefusalReason.superseded:
        // Not an attempt at all: the peer's own session superseded this round,
        // and that session files its own evidence when it ends.
        return;
      case _:
        break;
    }
    final bool answered;
    switch (report.failure) {
      case SyncFailureReason.unreachable:
      case SyncFailureReason.timeout:
        answered = false;
      case SyncFailureReason.noEndpoint:
        // Nothing was dialed, so nothing was proved either way. No verdict is
        // filed and no set is touched: the probe remains the only evidence,
        // and nothing here outranks it.
        return;
      case SyncFailureReason.peerError:
      case SyncFailureReason.internal:
      case null:
        answered = true;
    }
    _fileSessionVerdict(deviceId, answered: answered);
  }

  /// Files one session's verdict about reaching [deviceId] and republishes the
  /// dots. A session that got an answer marks the peer online; one that found
  /// silence clears the dot. Either way the *source* is recorded: the card says
  /// the last word came from a session, which is a different statement from a
  /// probe's answer even when both agree.
  void _fileSessionVerdict(String deviceId, {bool answered = true}) {
    _sessionEvidence.add(deviceId);
    if (answered) {
      onlineDeviceIds.add(deviceId);
      _probeMisses.remove(deviceId);
    } else {
      onlineDeviceIds.remove(deviceId);
    }
    _notify();
  }

  // ---- presence (the online dots and the per-endpoint latency) ----

  /// Probes the endpoints of every paired peer and republishes the online set
  /// and the latency figures.
  ///
  /// Each endpoint gets its own answer (see [probePeerEndpoints]) instead of one
  /// boolean per peer: the card shows which address is fast, which is silent and
  /// what each one costs, so collapsing them would throw away the only thing
  /// that lets a user decide which addresses to keep.
  ///
  /// Which endpoints a tick probes is tiered ([selectProbeTargets]): the
  /// addresses that answered last round, and the silent tail only when they all
  /// go quiet or a [full][_fullProbePending] round is due. A peer mid-session is
  /// neither probed nor assumed: its session files the verdict, and until one
  /// side answers, "a round is running" is not evidence the peer is there.
  Future<void> refreshPresence() async {
    if (!started || _presenceRunning) return;
    final engine = _engine;
    if (engine == null) return;
    _presenceRunning = true;
    final full = _fullProbePending;
    _fullProbePending = false;
    try {
      // Every peer with an endpoint is *known* (its dot must not survive
      // unpairing or a replaced endpoint set); only the non-busy ones are
      // probed — a busy peer keeps the evidence it already has until its
      // session settles it.
      final known = <String>{};
      final targets = <SyncPeerRecord>[];
      for (final peer in peers) {
        if (peer.endpoints.isEmpty) continue;
        known.add(peer.deviceId);
        if (!busyDeviceIds.contains(peer.deviceId)) targets.add(peer);
      }
      final rounds = await Future.wait([
        for (final peer in targets) _probePeer(peer, full),
      ]);
      for (var i = 0; i < targets.length; i++) {
        _fileProbeRound(targets[i].deviceId, rounds[i]);
      }
      // A peer whose record changed since the last round (unpaired, or its
      // endpoints replaced) must not keep a dot from the previous set.
      onlineDeviceIds.removeWhere((id) => !known.contains(id));
      _probeMisses.removeWhere((id) => !known.contains(id));
      _sessionEvidence.removeWhere((id) => !known.contains(id));
      _probeResults.removeWhere((id, _) => !known.contains(id));
      _publishProbes(engine);
      _notify();
    } finally {
      _presenceRunning = false;
    }
  }

  /// Probes one peer's chosen endpoints and folds the answers into its record of
  /// measurements.
  Future<List<EndpointProbeResult>> _probePeer(
    SyncPeerRecord peer,
    bool full,
  ) async {
    final previous = _probeResults[peer.deviceId] ?? const {};
    final targets = selectProbeTargets(peer.endpoints, previous, full: full);
    if (targets.isEmpty) return const [];
    final probe = _endpointProbe ?? syncEndpointProbe(_engine!.client, peer);
    final results = await probePeerEndpoints(endpoints: targets, probe: probe);
    _storeProbeResults(peer.deviceId, results);
    return results;
  }

  /// Folds one round's answers into this device's record of measurements.
  ///
  /// **The one place a probe result is stored**, whichever path ran the round:
  /// the periodic tick, a session's own fallback round, and whatever comes next.
  /// The rule it enforces is the probe module's own contract — a `noVerdict` (a
  /// 503 from a saturated listener) says nothing about the address, so it must
  /// never replace a working figure — and it used to live on one of the two
  /// paths only, which meant a session's round could erase the measurement the
  /// tick had just taken. A rule with two implementations has one implementation.
  ///
  /// Answers for the endpoints this round did not visit are kept: the tail's last
  /// figure is still the best thing known about it, and that is also what makes
  /// the tick's rotation fall out of the data instead of a counter.
  void _storeProbeResults(String deviceId, List<EndpointProbeResult> results) {
    if (results.isEmpty) return;
    final previous = _probeResults[deviceId] ?? const {};
    _probeResults[deviceId] = {
      ...previous,
      for (final result in results)
        if (!(result.noVerdict &&
            (previous[result.endpoint]?.answered ?? false)))
          result.endpoint: result,
    };
  }

  /// Files one probe round's answers for [deviceId] and republishes the dot.
  void _fileProbeRound(String deviceId, List<EndpointProbeResult> results) {
    if (results.isEmpty) return;
    final anyAnswered = results.any((result) => result.answered);
    if (anyAnswered) {
      onlineDeviceIds.add(deviceId);
      _probeMisses.remove(deviceId);
      // An answered probe is fresh evidence of the *address*, not of a session,
      // so it replaces the session as the dot's stated source rather than being
      // outranked by it: the tooltip answers "what did we last see?".
      _sessionEvidence.remove(deviceId);
      return;
    }
    if (results.any((result) => result.noVerdict)) {
      // A listener said "not now" — that is about its load, not about the peer,
      // so nothing here may darken the dot. `any`, not `every`: a `ping_busy`
      // arrived over the *pinned* handshake, so the device at that address
      // proved it is this peer and then declined to be judged — stronger
      // presence evidence than the silence of a remembered address beside it.
      // Requiring the whole round to be no-verdict meant one silent memory
      // turned a live peer's round into a miss, and two of those darkened the
      // dot for a peer that had just answered.
      return;
    }
    if (!_probeMisses.add(deviceId)) {
      // The second miss in a row: the peer is not answering.
      onlineDeviceIds.remove(deviceId);
    }
  }

  /// Hands the engine the figures the dial should reuse instead of probing
  /// again, so a session started right after a tick spends no probe of its own.
  void _publishProbes(SyncEngine engine) {
    engine.endpointProbes = {
      for (final entry in _probeResults.entries)
        if (entry.value.isNotEmpty)
          entry.key: entry.value.values.toList(growable: false),
    };
  }

  void _publishProbesIfStarted() {
    final engine = _engine;
    if (engine != null) _publishProbes(engine);
  }

  /// Writes the measured latency of each endpoint onto its peer record, so the
  /// management view can show "last measured" across launches.
  ///
  /// The figures merge into the record as it is on disk — not into the copy this
  /// provider listed before the session, which is how a session that had just
  /// succeeded came back with its own outcome erased.
  Future<void> _persistProbeStats(String deviceId) async {
    final store = _store;
    final results = _probeResults[deviceId];
    if (store == null || results == null) return;
    await store.mutatePeer(deviceId, (peer) {
      var changed = false;
      for (final result in results.values) {
        // A `ping_busy` is not a verdict: it is the listener saying "not now", so
        // it must not be written as "this address did not answer" — that would
        // clear a working latency with a null and move the "last measured" stamp.
        if (result.noVerdict) continue;
        final endpoint = peer.endpointFor(result.host, result.port);
        if (endpoint == null) continue;
        endpoint.recordProbe(
          answered: result.answered,
          latency: result.latency,
          at: result.measuredAt,
        );
        changed = true;
      }
      return changed;
    });
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

  // ---- workspace content (slice 18) ----

  /// Re-reads every managed workspace and re-counts its files, off the UI
  /// isolate.
  ///
  /// Called when the panel opens and after every session — the two moments the
  /// figures can have changed — rather than on a timer: a workspace folder
  /// holds as many files as the user's project does, and re-walking it on a
  /// tick would spend real IO to redraw a number nobody is looking at.
  Future<void> refreshWorkspaceContent() async {
    final content = _workspaceContent;
    if (content == null || _workspaceRefreshRunning) return;
    _workspaceRefreshRunning = true;
    try {
      final snapshots = await content.snapshots();
      workspaceSummaries = [
        for (final snapshot in snapshots)
          SyncWorkspaceSummary(
            id: snapshot.id,
            name: snapshot.name,
            fileCount: snapshot.index.files.length,
            totalBytes: snapshot.index.totalBytes,
            truncated: snapshot.index.truncated,
            unreadable: snapshot.index.incomplete,
            enabled: snapshot.enabled,
          ),
      ];
      _notify();
    } catch (error) {
      // A workspace whose folder cannot be read must not take the panel down
      // with it: the rows simply keep the figures they had.
      debugPrint('sync: reading workspace content failed: $error');
    } finally {
      _workspaceRefreshRunning = false;
    }
  }

  /// Turns content sync for one workspace on or off (device-local).
  ///
  /// The workspace's *record* is not affected in either direction: it always
  /// travels, because a row this device stopped publishing would be read by the
  /// peer as a deletion of its own workspace (`planRowSync`'s `peerDeletes`).
  /// The switch governs the folder only.
  Future<void> setWorkspaceContentEnabled(String id, bool enabled) async {
    final content = _workspaceContent;
    if (content == null) return;
    // The switch is reflected immediately and persisted in the background: the
    // row is what the user just acted on, and the walk below is what pays for
    // the fresh figures.
    final current = workspaceSummaries;
    if (current != null) {
      workspaceSummaries = [
        for (final summary in current)
          summary.id == id ? summary.copyWith(enabled: enabled) : summary,
      ];
      _notify();
    }
    await content.setEnabled(id, enabled);
    await refreshWorkspaceContent();
  }

  // ---- automatic rounds (foreground) ----

  DateTime? _lastAutoSyncAt;
  bool _autoRoundRunning = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Desktop fires `resumed` on every window focus gain too; the global
    // throttle in [shouldAutoSyncNow] is what keeps that cheap.
    if (state == AppLifecycleState.resumed) {
      // A window that comes back is a window whose listener must be up: a tray
      // restore is the journey #1036 was reported from.
      ensureListening();
      // Picking the device up is the pickup journey: this network may not be
      // the one the last round measured, so the first round after a resume
      // walks every endpoint rather than the head ones.
      _fullProbePending = true;
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
          await syncNow(peer.deviceId, automatic: true);
        } catch (_) {
          // A failed round already shows on the peer card; the round moves on.
        }
      }
    } finally {
      _autoRoundRunning = false;
    }
  }

  /// How long a `busy` (or `superseded`) refusal waits for its one retry.
  ///
  /// A busy refusal means the peer's own session with this device was already
  /// running — the common case on a LAN where both devices were picked up at
  /// the same moment. The next automatic trigger is a minute away, so waiting
  /// for it left the user looking at "another session is in progress" long
  /// after the session ended; one short retry covers it, and only one, so a
  /// pair that keeps colliding does not become a tight loop.
  ///
  /// Longer than [SyncEngine.kYieldedSessionTtl] on purpose: the crossing case
  /// the retry exists for refuses this device's dial only while the session it
  /// yielded to is still held, so retrying before that window closes would earn
  /// the same `busy` and spend the pair's one retry on nothing.
  static const busyRetryDelay = Duration(seconds: 5);

  /// The extra, per-attempt delay's ceiling for a `superseded` retry.
  ///
  /// The device-id offset below is fixed for a device, so two devices whose
  /// rounds keep landing in the same instant would keep retrying in the same
  /// instant too — the phase-locked collision, where neither symmetry-breaking
  /// rule that reads *stable* facts (ids, topology) can help, because both sides
  /// read the same facts. A fresh random salt per attempt is what actually
  /// decorrelates them. It is deliberately not larger: this is a retry that has
  /// to feel immediate, not a backoff schedule.
  static const kSyncRetrySaltMs = 1200;

  final Random _retryJitter = Random();

  /// The delay before that retry, offset by *this* device's id and by an optional
  /// per-attempt salt (see [kSyncRetrySaltMs]).
  ///
  /// Two devices that collided must not retry in lockstep, or they collide
  /// again and the pair never makes progress. The offset is derived from this
  /// device's own id: both sides know both ids, so a *shared* function of the
  /// pair would hand them the same answer and change nothing. Pure apart from
  /// [saltMs], which the caller draws, so a test can pin it.
  static Duration busyRetryDelayFor(String myDeviceId, {int saltMs = 0}) =>
      busyRetryDelay +
      Duration(milliseconds: _retryOffsetMs(myDeviceId) + saltMs);

  /// FNV-1a over the id, folded into `[0, 1200)` ms. Deliberately not
  /// `String.hashCode`, whose value is only promised to be consistent within a
  /// single run; this one is the same on both devices and across launches.
  static int _retryOffsetMs(String deviceId) {
    var hash = 0x811c9dc5;
    for (final unit in deviceId.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return hash % 1200;
  }

  final Map<String, Timer> _busyRetryTimers = {};

  /// Whether a one-shot retry is currently pending for [deviceId] — the only
  /// observable the "one retry, and only one" rule has.
  @visibleForTesting
  bool hasPendingRetry(String deviceId) =>
      _busyRetryTimers.containsKey(deviceId);

  /// Arms that one retry. [decorrelate] adds this attempt's random salt, which
  /// only the crossing case needs: a device-id offset already separates two
  /// devices, but it is the same offset every time, so a pair whose rounds keep
  /// landing together would keep landing together.
  void _scheduleBusyRetry(String deviceId, {bool decorrelate = false}) {
    if (_busyRetryTimers.containsKey(deviceId)) return;
    final engine = _engine;
    if (engine == null) return;
    final saltMs = decorrelate ? _retryJitter.nextInt(kSyncRetrySaltMs) : 0;
    _busyRetryTimers[deviceId] = Timer(
      busyRetryDelayFor(engine.identity.deviceId, saltMs: saltMs),
      () {
        _busyRetryTimers.remove(deviceId);
        if (!started || busyDeviceIds.contains(deviceId)) return;
        unawaited(syncNow(deviceId, automatic: true, retryAttempt: true));
      },
    );
  }

  void _cancelBusyRetries() {
    for (final timer in _busyRetryTimers.values) {
      timer.cancel();
    }
    _busyRetryTimers.clear();
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

  /// A probe round the engine ran itself, because the snapshot it held was too
  /// old to order a dial by. Folding it in keeps the card's figures current and
  /// gives the next session the measurement to reuse — through the same
  /// [_storeProbeResults] the tick uses, so a `ping_busy` on this path cannot
  /// erase a working figure either.
  void _onEngineProbes(String deviceId, List<EndpointProbeResult> results) {
    if (results.isEmpty) return;
    _storeProbeResults(deviceId, results);
    _fileProbeRound(deviceId, results);
    _publishProbesIfStarted();
  }

  /// A beat inside a running initiator session.
  ///
  /// Any beat past the dial means the peer answered — `exchanging` is published
  /// only once both hello manifests are in hand — so it is online evidence of
  /// the strongest kind: bytes are flowing right now. This is what keeps a
  /// minutes-long first sync green while it runs, without extending that green
  /// to the dial itself (the seconds an automatic round spends failing against
  /// a sleeping peer). The session's own verdict settles the dot when it ends.
  void _onEngineProgressChanged() {
    final progress = _engine?.initiatorProgress;
    if (progress != null) {
      for (final entry in progress.entries) {
        if (entry.value.phase == SyncSessionPhase.connecting) continue;
        onlineDeviceIds.add(entry.key);
        _sessionEvidence.add(entry.key);
        _probeMisses.remove(entry.key);
      }
    }
    _notify();
  }

  /// Publishes one arrival, unless this provider is already disposed — the same
  /// rule [_notify] follows, and for the same reason: a session can outlive the
  /// tree that started it, and the listener keeps answering after `dispose`
  /// closed this stream. `add` on a closed controller throws, and on the
  /// responder path that throw reaches the peer as a 500 *after* the data was
  /// applied — a failed round reported for a session that actually worked.
  void _announce(SyncArrival arrival) {
    if (_disposed) return;
    _arrivals.add(arrival);
  }

  /// A session some peer ran against this device's listener just finished —
  /// the arrival [syncNow] never sees, because this device started nothing:
  /// the phone's round that lands while the desktop sits here quietly. The
  /// gates are the arrival's own: the session must have brought data here
  /// ([syncBroughtDataHere]), and no sync panel may be showing the same news
  /// on its cards.
  ///
  /// The presence verdict is filed first and unconditionally: those gates say
  /// what the *user* is told, not whether the peer answered, and this session is
  /// the only evidence a device that started nothing can have. A session that
  /// moved nothing — the common case — would otherwise leave the dot to the
  /// probe, which can show gray right after an answer.
  void _onEngineResponderSession(
    SyncPeerRecord peer,
    SyncSessionReport report,
  ) {
    _fileSessionVerdict(peer.deviceId);
    _fullProbePending = true;
    // A session this device answered moved files too, and nobody else will
    // re-count them.
    unawaited(refreshWorkspaceContent());
    if (_panelViewers > 0 || !syncBroughtDataHere(report)) return;
    _announce(SyncArrival(peer.displayName, report));
  }

  @override
  void dispose() {
    _disposed = true;
    _stopPresenceTimer();
    _cancelBusyRetries();
    _arrivals.close();
    WidgetsBinding.instance.removeObserver(this);
    AppShutdown.unregister(stop);
    super.dispose();
  }
}
