import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'sync_limits.dart';
import 'sync_local_addresses.dart';
import 'sync_models.dart';

/// File-backed persistence for sync state, all under the app's `sync/`
/// directory (outside the backup face — peer state and checkpoints are
/// device-local by definition):
///
/// - `identity.json`          — owned by [SyncDeviceIdentity]
/// - `peers/<deviceId>.json`  — pinned certificate + display info + endpoint
/// - `checkpoints/<deviceId>.json.gz` — per-peer checkpoint, including the
///   workspace file ledger the content plan reads (slice 18)
/// - `workspaces.json`        — which workspaces this device syncs files for
/// - `epoch.json`             — this device's data epoch (see [readDataEpoch])
class SyncStore {
  SyncStore(this.root);

  final Directory root;

  Directory get _peersDir =>
      Directory('${root.path}${Platform.pathSeparator}peers');
  Directory get _checkpointsDir =>
      Directory('${root.path}${Platform.pathSeparator}checkpoints');

  Future<void> ensureDirectories() async {
    await _peersDir.create(recursive: true);
    await _checkpointsDir.create(recursive: true);
    await _blobCacheDir.create(recursive: true);
  }

  // ---- blob transfer scratch space ----

  Directory get _blobCacheDir =>
      Directory('${root.path}${Platform.pathSeparator}blob-cache');

  /// A fresh empty file for one incoming blob. The caller deletes it after
  /// applying (or failing); nothing here is durable state.
  Future<File> newBlobTempFile() async {
    await _blobCacheDir.create(recursive: true);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final file = File(
      '${_blobCacheDir.path}${Platform.pathSeparator}in-$stamp-$_tempCounter.bin',
    );
    _tempCounter++;
    return file;
  }

  static int _tempCounter = 0;

  /// Drops transfer scratch space left behind by a previous run.
  Future<void> clearBlobCache() async {
    if (!await _blobCacheDir.exists()) return;
    try {
      await _blobCacheDir.delete(recursive: true);
    } catch (error) {
      debugPrint('sync store: could not clear blob cache: $error');
    }
  }

  // ---- peers ----

  Future<List<SyncPeerRecord>> listPeers() async {
    if (!await _peersDir.exists()) return const [];
    final records = <SyncPeerRecord>[];
    await for (final entity in _peersDir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        records.add(
          SyncPeerRecord.fromJson(
            jsonDecode(await entity.readAsString()) as Map<String, dynamic>,
          ),
        );
      } catch (error) {
        debugPrint('sync store: skipping unreadable peer file: $error');
      }
    }
    records.sort((a, b) => a.displayName.compareTo(b.displayName));
    return records;
  }

  Future<SyncPeerRecord?> findPeer(String deviceId) => readPeer(deviceId);

  /// Reads one peer record. The file name *is* the deviceId, so this is a
  /// single-file read. It retries once: [savePeer] publishes through a rename,
  /// which on Windows needs the target removed first, so a reader can still
  /// catch the file mid-swap.
  Future<SyncPeerRecord?> readPeer(String deviceId) async {
    final file = File(
      '${_peersDir.path}${Platform.pathSeparator}$deviceId.json',
    );
    for (var attempt = 0; attempt < 2; attempt++) {
      if (!await file.exists()) return null;
      try {
        final text = await file.readAsString();
        if (text.trim().isEmpty) {
          throw const FormatException('peer file is momentarily empty');
        }
        return SyncPeerRecord.fromJson(
          jsonDecode(text) as Map<String, dynamic>,
        );
      } catch (error) {
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          continue;
        }
        debugPrint('sync store: skipping unreadable peer file: $error');
        return null;
      }
    }
    return null;
  }

  /// Writes one peer record whole — the record's *origin*: a pairing answer is
  /// where a record begins, and it replaces whatever was there.
  ///
  /// Every other writer merges through [mutatePeer] instead, so the fields it
  /// did not mean to touch are not overwritten from a copy it read earlier.
  Future<void> savePeer(SyncPeerRecord peer) async {
    await _peersDir.create(recursive: true);
    final file = File(
      '${_peersDir.path}${Platform.pathSeparator}${peer.deviceId}.json',
    );
    await _writeAtomic(file, utf8.encode(jsonEncode(peer.toJson())));
  }

  /// One pending mutation per peer, so two writers cannot read the same record
  /// and then both write it.
  final Map<String, Future<void>> _peerWrites = {};

  /// Serialized read-modify-write of one peer record, and the **only** merge
  /// path: a whole-record write from a copy read earlier is how a session's own
  /// outcome was lost.
  ///
  /// The record is read *inside* the section, so a mutation applies to what is on
  /// disk now. A session holds its peer object for its whole length, while every
  /// mid-session state change makes the provider re-read the list from disk — so
  /// the post-session probe write used to save a *pre-session* snapshot of the
  /// record over the `lastSyncedAt`/`lastReport`/promoted endpoint the session
  /// had just written, and the card came back saying "Never synced".
  ///
  /// [mutate] returns whether anything changed; nothing is written when it
  /// returns false, so a no-op does not rewrite the file nor the "last measured"
  /// stamps it did not touch. It runs synchronously, so the section never spans
  /// an await and two mutations cannot interleave inside it.
  ///
  /// Returns the record as written, or null when this device holds none for
  /// [deviceId] — an absent record is not created here (see [savePeer]).
  Future<SyncPeerRecord?> mutatePeer(
    String deviceId,
    bool Function(SyncPeerRecord peer) mutate,
  ) {
    final previous = _peerWrites[deviceId] ?? Future<void>.value();
    final write = previous.then((_) async {
      final peer = await readPeer(deviceId);
      if (peer == null) return null;
      if (!mutate(peer)) return peer;
      await savePeer(peer);
      return peer;
    });
    // The chain has to survive a failed write: one throw must not cancel every
    // later mutation of that peer.
    _peerWrites[deviceId] = write.then((_) {}, onError: (_) {});
    return write;
  }

  /// Writes through a temporary file in the same directory, so a concurrent
  /// reader sees either the previous contents or the complete new ones — never
  /// the empty file a truncating write exposes.
  Future<void> _writeAtomic(File file, List<int> bytes) async {
    final temp = File('${file.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    try {
      await temp.rename(file.path);
    } on FileSystemException {
      // Windows refuses to rename onto an existing file, hence the removal.
      if (await file.exists()) await file.delete();
      await temp.rename(file.path);
    }
  }

  Future<void> deletePeer(String deviceId) async {
    final file = File(
      '${_peersDir.path}${Platform.pathSeparator}$deviceId.json',
    );
    if (await file.exists()) await file.delete();
    final checkpoint = File(
      '${_checkpointsDir.path}${Platform.pathSeparator}$deviceId.json.gz',
    );
    if (await checkpoint.exists()) await checkpoint.delete();
  }

  // ---- checkpoints ----

  Future<SyncCheckpoint> loadCheckpoint(String deviceId) async {
    final file = _checkpointFile(deviceId);
    if (!await file.exists()) return SyncCheckpoint.empty;
    try {
      final decoded = gzip.decode(await file.readAsBytes());
      return SyncCheckpoint.fromJson(
        jsonDecode(utf8.decode(decoded)) as Map<String, dynamic>,
      );
    } catch (error) {
      debugPrint('sync store: unreadable checkpoint for $deviceId: $error');
      return SyncCheckpoint.empty;
    }
  }

  Future<void> saveCheckpoint(
    String deviceId,
    SyncCheckpoint checkpoint,
  ) async {
    await _checkpointsDir.create(recursive: true);
    final bytes = gzip.encode(utf8.encode(jsonEncode(checkpoint.toJson())));
    await _writeAtomic(_checkpointFile(deviceId), bytes);
  }

  File _checkpointFile(String deviceId) =>
      File('${_checkpointsDir.path}${Platform.pathSeparator}$deviceId.json.gz');

  // ---- data epoch ----

  /// This device's data epoch: a counter bumped whenever the local database is
  /// bulk-replaced outside the sync write path — a backup restore, an overwrite
  /// import. The checkpoint's whole premise is that "the peer lacks a row"
  /// means "the peer deleted it"; a bulk replacement breaks exactly that
  /// premise, because every row it dropped is an absence that was never a
  /// deletion, and the peer would delete its own copies to match. Advertising
  /// the epoch in the hello lets the peer see the replacement and re-converge
  /// from "nothing shared" instead, while a device that merely lost an
  /// unconfirmed transfer (no checkpoint entry, no epoch change) still reads as
  /// "never delivered".
  Future<int> readDataEpoch() async {
    final file = _epochFile;
    if (!await file.exists()) return 0;
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return (json['epoch'] as num?)?.toInt() ?? 0;
    } catch (error) {
      debugPrint('sync store: unreadable data epoch: $error');
      return 0;
    }
  }

  Future<void> writeDataEpoch(int epoch) async {
    await root.create(recursive: true);
    await _writeAtomic(_epochFile, utf8.encode(jsonEncode({'epoch': epoch})));
  }

  /// Drops every per-peer checkpoint — what a bulk replacement owes this
  /// device's own bookkeeping. Entries describe state the peer demonstrably
  /// held; after a replacement they describe a history this device no longer
  /// has.
  Future<void> resetCheckpoints() async {
    if (!await _checkpointsDir.exists()) return;
    try {
      await _checkpointsDir.delete(recursive: true);
    } catch (error) {
      debugPrint('sync store: could not reset checkpoints: $error');
    }
  }

  /// The bulk-replacement hook, callable where no engine exists yet: the
  /// restore cutover runs at startup, before any provider is built. Resets the
  /// checkpoints and bumps the epoch so paired devices re-converge from
  /// "nothing shared" rather than reading the lost rows as deletions. Idempotent
  /// enough to repeat after an interrupted cutover: a second bump only makes
  /// the next session re-converge once more.
  static Future<void> resetForBulkReplacement(Directory root) async {
    final store = SyncStore(root);
    await store.resetCheckpoints();
    await store.writeDataEpoch(await store.readDataEpoch() + 1);
  }

  File get _epochFile =>
      File('${root.path}${Platform.pathSeparator}epoch.json');

  // ---- workspace content toggles ----

  /// The workspaces this device does **not** sync files for (ADR-0003 slice
  /// 18), by id.
  ///
  /// Stored as the disabled set rather than as a full map of choices so that
  /// "on" is the absence of an entry: a workspace the user just created syncs
  /// without anything having to write a preference for it, which is the
  /// default the feature promises. Device-local by definition — it says what
  /// *this* machine is willing to upload, so it rides neither the sync wire nor
  /// a backup.
  ///
  /// A file this device cannot read is read as "nothing disabled": the switch
  /// is a convenience, and refusing to sync anything because a preferences file
  /// was truncated would be the worse failure.
  Future<Set<String>> readWorkspaceContentDisabled() async {
    final file = _workspaceSettingsFile;
    if (!await file.exists()) return const {};
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return const {};
      final raw = json['disabled'];
      if (raw is! List) return const {};
      return {
        for (final id in raw)
          if (id is String && id.isNotEmpty) id,
      };
    } catch (error) {
      debugPrint('sync store: unreadable workspace settings: $error');
      return const {};
    }
  }

  /// Reads, edits and writes the disabled set as one indivisible step, and
  /// reports whether [mutate] changed anything.
  ///
  /// The *only* way a caller may change one workspace's choice. The set lives in
  /// a single file whose value is the whole answer, so a read-modify-write that
  /// two callers perform concurrently loses one of them: in a single isolate
  /// both reads complete before either write, and the last writer's set is
  /// simply missing the other's id — a switch that flips back on its own the
  /// next time the file is read, with nothing in the logs to say why.
  ///
  /// [mutate] returns whether it changed the set; false means nothing is
  /// written and the file is left exactly as it was.
  Future<bool> mutateWorkspaceContentDisabled(
    bool Function(Set<String> current) mutate,
  ) => _serializeWorkspaceSettings(() async {
    final current = {...await readWorkspaceContentDisabled()};
    if (!mutate(current)) return false;
    await _writeWorkspaceDisabledNow(current);
    return true;
  });

  /// The write itself, without the queue: only the serialized callers above may
  /// use it, or the serialization they exist for is re-entered.
  Future<void> _writeWorkspaceDisabledNow(Set<String> workspaceIds) async {
    await root.create(recursive: true);
    final ids = workspaceIds.where((id) => id.isNotEmpty).toList()..sort();
    await _writeAtomic(
      _workspaceSettingsFile,
      utf8.encode(jsonEncode({'disabled': ids})),
    );
  }

  /// Chains [action] behind every earlier workspace-settings write.
  ///
  /// The tail of the chain swallows errors so one failed write cannot wedge
  /// every later toggle; the caller still sees its own failure through the
  /// future this returns.
  Future<T> _serializeWorkspaceSettings<T>(Future<T> Function() action) {
    final result = _workspaceSettingsQueue.then((_) => action());
    _workspaceSettingsQueue = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _workspaceSettingsQueue = Future<void>.value();

  File get _workspaceSettingsFile =>
      File('${root.path}${Platform.pathSeparator}workspaces.json');
}

/// What [SyncPeerRecord.addEndpoint] did, instead of a bool that reads the same
/// whether the address was remembered, already there, or refused.
///
/// The distinction is the whole point: this cap is the one bound a *user* can
/// walk into (typing addresses one at a time), and a bare `false` made "the set
/// is full and nothing happened" indistinguishable from "that address is
/// already remembered" — a silent success for a write that dropped the user's
/// address on the floor.
enum SyncEndpointAdd {
  /// The address is now in the set.
  added,

  /// The set already held it (a no-op, and not a failure).
  duplicate,

  /// The host was blank or the port was not a port.
  invalid,

  /// The set is at [kMaxPeerEndpoints] and the address is not in it. Nothing was
  /// evicted: a user-typed address never displaces one this pair has actually
  /// synced over, and the caller has to say so rather than report success.
  full,
}

/// One remembered address of a paired device.
///
/// The address is an attribute of the **(device, network)** pair, not of the
/// device: the same laptop is reachable at a different address at home, at work
/// and on a phone hotspot. Only the certificate fingerprint identifies a peer —
/// an address is a hint that every connection re-verifies against the pin, so
/// remembering several of them can never pair or sync with the wrong device.
///
/// The record carries what a user needs to decide whether an address is still
/// worth keeping: how many sessions it has carried, when it last did, and what
/// its last probe measured. Those are management-view facts — the card itself
/// shows only the latency, because that is the one number that answers "which
/// of these is the fast one right now".
class SyncPeerEndpoint {
  /// Mutable because an address is a hint, not an identity: the management view
  /// repairs a tile in place ("the peer moved, this is where it is now"), and
  /// the repaired tile keeps the session count and probe history that belong to
  /// the (device, network) pair rather than to the string.
  String host;
  int port;

  /// The name this device's user typed over the address, or null when the
  /// address itself is its name. Per endpoint, not per peer: the same laptop is
  /// "家中网络" at home and "公司网络" at the office, and those are two tiles.
  String? customName;

  /// When a session last ran over this endpoint. Orders the set and is what
  /// the peer card's "last connected" line shows. A refusal from the peer
  /// counts: it proves this address reaches it on this network.
  DateTime? lastSuccessAt;

  /// When this address was first learned (a pairing candidate or a proven
  /// session).
  DateTime? addedAt;

  /// How many sessions have run over this endpoint, refusals included. Probes
  /// never count: a probe is this device asking a cheap question, and a number
  /// that grows by the tick would say nothing about whether the address works
  /// for syncing.
  int successCount;

  /// What the last authenticated probe of this address measured, and when. Null
  /// latency means nothing answered (or nothing has probed it yet).
  int? lastLatencyMs;
  DateTime? lastProbedAt;

  SyncPeerEndpoint({
    required this.host,
    required this.port,
    this.customName,
    this.lastSuccessAt,
    this.addedAt,
    this.successCount = 0,
    this.lastLatencyMs,
    this.lastProbedAt,
  });

  /// How a human types it: `192.168.1.7:9527`, or `[fd00::1]:9527` for an IPv6
  /// literal — whose port would otherwise be one more colon in a row.
  String get label => formatHostPort(host, port);

  /// What this endpoint's tile and detail header show: the name the user typed,
  /// or the bare host. The `host:port` form is [label] — the address, which the
  /// detail sheet shows underneath the name and is what a person copies.
  String get displayName => customName ?? host;

  /// A session ran over this endpoint: it is promoted, stamped, counted.
  void recordSession({DateTime? at}) {
    successCount++;
    lastSuccessAt = at ?? DateTime.now();
    addedAt ??= lastSuccessAt;
  }

  /// A probe answered (or went silent) at [at]. Latency is kept only for an
  /// answer: a silent address has no round trip to remember.
  void recordProbe({required bool answered, Duration? latency, DateTime? at}) {
    lastProbedAt = at ?? DateTime.now();
    lastLatencyMs = answered ? latency?.inMilliseconds : null;
    addedAt ??= lastProbedAt;
  }

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    if (customName != null) 'customName': customName,
    'lastSuccessAtMs': lastSuccessAt?.millisecondsSinceEpoch,
    'addedAtMs': addedAt?.millisecondsSinceEpoch,
    'successCount': successCount,
    'lastLatencyMs': lastLatencyMs,
    'lastProbedAtMs': lastProbedAt?.millisecondsSinceEpoch,
  };

  static SyncPeerEndpoint fromJson(Map<String, dynamic> json) {
    final atMs = json['lastSuccessAtMs'] as num?;
    final addedMs = json['addedAtMs'] as num?;
    final probedMs = json['lastProbedAtMs'] as num?;
    final name = (json['customName'] as String?)?.trim();
    return SyncPeerEndpoint(
      host: json['host'] as String,
      port: (json['port'] as num).toInt(),
      // A blank name is no name: clearing a tile's name must leave the address
      // showing, not a tile with an empty top line.
      customName: name == null || name.isEmpty ? null : name,
      lastSuccessAt: atMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(atMs.toInt()),
      addedAt: addedMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(addedMs.toInt()),
      successCount: (json['successCount'] as num?)?.toInt() ?? 0,
      lastLatencyMs: (json['lastLatencyMs'] as num?)?.toInt(),
      lastProbedAt: probedMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(probedMs.toInt()),
    );
  }
}

/// One paired device as this device knows it.
class SyncPeerRecord {
  final String deviceId;

  /// Pinned certificate (PEM). Trust = this exact certificate; the client
  /// refuses any other one when connecting.
  final String certPem;

  /// Per-peer secret established at pairing, presented on every `/sync/*`
  /// request (the listener does not use TLS client certificates — see
  /// [SyncServer]).
  String secret;

  /// The name the peer last reported for itself. Re-pairing refreshes it —
  /// the QR re-scan is the drift-repair journey, so that happens often.
  String name;

  /// The name this device's user typed over it, or null when the reported name
  /// was never overridden. A re-pair carries it over: a rename made on this
  /// card outlives whatever the peer calls itself this week.
  String? customName;

  /// What every card, dialog and announcement shows.
  String get displayName => customName ?? name;

  String platform;

  /// Remembered endpoints, best first: the one a session last succeeded over,
  /// then the candidates pairing advertised. Empty when the peer was paired
  /// without an address at all.
  List<SyncPeerEndpoint> endpoints;

  /// When a session last *succeeded* with this peer. Failures keep the stamp:
  /// the line answers "how fresh is what I see?", which an unreachable peer
  /// does not change.
  DateTime? lastSyncedAt;

  /// Outcome of the most recent session with this peer, as counters so the
  /// panel can localize it.
  SyncPeerReport? lastReport;

  SyncPeerRecord({
    required this.deviceId,
    required this.certPem,
    required this.secret,
    required this.name,
    this.customName,
    required this.platform,
    List<SyncPeerEndpoint>? endpoints,
    this.lastSyncedAt,
    this.lastReport,
  }) : endpoints = endpoints ?? <SyncPeerEndpoint>[];

  /// The address the card shows and a session tries first, or null when nothing
  /// is remembered.
  SyncPeerEndpoint? get primaryEndpoint =>
      endpoints.isEmpty ? null : endpoints.first;

  /// Records a connection that succeeded over `host:port`: the endpoint is
  /// promoted to the front and its stats refreshed. A session that ran at
  /// all — including one the peer refused — proves this address reaches the
  /// peer on this network, which is exactly what the order should track.
  ///
  /// The existing endpoint object is *moved*, not rebuilt: its session count
  /// and its probe history belong to the address, not to this visit. Returns
  /// the endpoints this promotion pushed out of the set, so a caller can say
  /// which memory was spent rather than discovering it afterwards.
  List<SyncPeerEndpoint> noteEndpointSuccess(
    String host,
    int port, {
    DateTime? at,
  }) {
    final existing = endpointFor(host, port);
    endpoints.removeWhere(
      (endpoint) => endpoint.host == host && endpoint.port == port,
    );
    final endpoint =
        existing ??
        SyncPeerEndpoint(host: host, port: port, addedAt: at ?? DateTime.now());
    endpoint.recordSession(at: at);
    endpoints.insert(0, endpoint);
    return _trimEndpoints();
  }

  /// The remembered endpoint for `host:port`, or null.
  SyncPeerEndpoint? endpointFor(String host, int port) {
    for (final endpoint in endpoints) {
      if (endpoint.host == host && endpoint.port == port) return endpoint;
    }
    return null;
  }

  /// Forgets one endpoint — the management view's "delete this address". The
  /// last one may go too: a peer with no address is a state the panel already
  /// speaks (`no_endpoint` asks for one), and refusing the delete would trap
  /// an address the user knows is wrong.
  bool removeEndpoint(String host, int port) {
    final before = endpoints.length;
    endpoints.removeWhere(
      (endpoint) => endpoint.host == host && endpoint.port == port,
    );
    return endpoints.length != before;
  }

  /// Remembers one address the user typed, at the end of the set: the order is
  /// the dial order, and a typed address has proved nothing yet — it is tried
  /// once the addresses that have carried sessions are done. An address already
  /// remembered is not added twice, and an address that arrives at a full set is
  /// refused rather than admitted by evicting a proven one (see
  /// [SyncEndpointAdd]).
  SyncEndpointAdd addEndpoint(String host, int port, {DateTime? at}) {
    final trimmed = host.trim();
    if (trimmed.isEmpty || port <= 0) return SyncEndpointAdd.invalid;
    if (endpointFor(trimmed, port) != null) return SyncEndpointAdd.duplicate;
    if (endpoints.length >= kMaxPeerEndpoints) return SyncEndpointAdd.full;
    endpoints.add(
      SyncPeerEndpoint(
        host: trimmed,
        port: port,
        addedAt: at ?? DateTime.now(),
      ),
    );
    return SyncEndpointAdd.added;
  }

  /// Names one address ("家中网络"), or clears the name when [name] is blank and
  /// the address itself becomes its name again.
  bool renameEndpoint(String host, int port, String? name) {
    final endpoint = endpointFor(host, port);
    if (endpoint == null) return false;
    final trimmed = name?.trim() ?? '';
    endpoint.customName = trimmed.isEmpty ? null : trimmed;
    return true;
  }

  /// Repairs one address in place, keeping its name, session count and probe
  /// history: the peer moved, the tile did not stop being the same
  /// (device, network) pair. This is what the manual repair does now — the
  /// whole-set replacement it used to be threw away the history of every other
  /// network the pair had met, which is exactly the memory a peer that moves
  /// back and forth needs.
  ///
  /// An edit that lands on an address another tile already holds absorbs that
  /// tile: one address is one tile, or the same host would be dialed twice per
  /// session.
  bool editEndpoint(String host, int port, String newHost, int newPort) {
    final trimmed = newHost.trim();
    if (trimmed.isEmpty || newPort <= 0) return false;
    final endpoint = endpointFor(host, port);
    if (endpoint == null) return false;
    if (endpoint.host == trimmed && endpoint.port == newPort) return false;
    final duplicate = endpointFor(trimmed, newPort);
    if (duplicate != null && !identical(duplicate, endpoint)) {
      endpoints.remove(duplicate);
    }
    endpoint.host = trimmed;
    endpoint.port = newPort;
    return true;
  }

  /// Keeps candidates hinted by pairing (the QR's other endpoints, or the
  /// addresses an initiator advertised) without claiming any of them works:
  /// they land after the proven endpoint, unstamped, and are tried only once
  /// the ones ahead of them fail.
  ///
  /// Returns the candidates the set could not take because it was full. They are
  /// *not* remembered (an address that was never tried does not displace one
  /// that was), and pairing has to report that rather than let an advertised
  /// address vanish: the peer's own idea of where it is reachable is the thing
  /// this device acts on when the proven address goes stale.
  List<(String, int)> rememberEndpointCandidates(
    Iterable<(String, int)> candidates,
  ) {
    final dropped = <(String, int)>[];
    for (final (host, port) in candidates) {
      if (addEndpoint(host, port) == SyncEndpointAdd.full) {
        dropped.add((host, port));
      }
    }
    return dropped;
  }

  /// Keeps the endpoints a *previous* record held, behind everything this
  /// pairing just proved or advertised, with their own stamps intact: an
  /// address is a (device, network) fact, so the re-pair that repairs a drifted
  /// endpoint — the journey this feature expects whenever a peer moves — must
  /// not forget the networks the pair has already met. The pairing address is
  /// the new head, the QR's current candidates come next, and this is the memory
  /// behind both: tried only once the fresher ones fail.
  ///
  /// An address this pairing already landed is the *common* case, not the edge
  /// one: the pairing address is wherever the pair is right now, which is
  /// usually a network it has synced over before — re-scanning the QR at home
  /// proves the home address again. Skipping it there is what dropped the name
  /// and the sessions of exactly the tile that had the most of both. So the
  /// fresh copy keeps its position (the dial order is this call's contract) and
  /// the old copy contributes its facts to it: the name, the earlier first-seen
  /// stamp, the probe measurement, and its sessions, which are *added* to this
  /// pairing's rather than replacing them. One address stays one tile.
  ///
  /// Returns the endpoints the cap pushed out, so a re-pair says which network
  /// it had to forget instead of dropping it silently.
  List<SyncPeerEndpoint> rememberEndpointHistory(
    Iterable<SyncPeerEndpoint> previous,
  ) {
    for (final endpoint in previous) {
      if (endpoint.host.isEmpty || endpoint.port <= 0) continue;
      final fresh = endpointFor(endpoint.host, endpoint.port);
      if (fresh == null) {
        endpoints.add(endpoint);
        continue;
      }
      _mergeEndpointHistory(fresh, endpoint);
    }
    return _trimEndpoints();
  }

  /// Folds the facts [previous] holds onto the [fresh] copy this pairing
  /// created for the same address.
  ///
  /// Counters are events, so they add up (the old count precedes the re-pair;
  /// the fresh one is what the pairing itself did). Everything else is a
  /// *stamp*, and the one that answers its question is kept: the name if the
  /// fresh copy has none, the earlier "first learned", the later session, the
  /// later probe with the measurement that belongs to it.
  static void _mergeEndpointHistory(
    SyncPeerEndpoint fresh,
    SyncPeerEndpoint previous,
  ) {
    fresh.customName ??= previous.customName;
    fresh.successCount += previous.successCount;
    final oldSuccess = previous.lastSuccessAt;
    final freshSuccess = fresh.lastSuccessAt;
    if (oldSuccess != null &&
        (freshSuccess == null || oldSuccess.isAfter(freshSuccess))) {
      fresh.lastSuccessAt = oldSuccess;
    }
    final oldProbe = previous.lastProbedAt;
    final freshProbe = fresh.lastProbedAt;
    if (oldProbe != null &&
        (freshProbe == null || oldProbe.isAfter(freshProbe))) {
      fresh.lastProbedAt = oldProbe;
      fresh.lastLatencyMs = previous.lastLatencyMs;
    }
    final oldAdded = previous.addedAt;
    final freshAdded = fresh.addedAt;
    if (oldAdded != null &&
        (freshAdded == null || oldAdded.isBefore(freshAdded))) {
      fresh.addedAt = oldAdded;
    }
  }

  /// Trims the set back to [kMaxPeerEndpoints] and returns what it removed, the
  /// tail first: the *order* is what decides which memory to spend, so the
  /// caller is told which address that was rather than having to recompute it.
  List<SyncPeerEndpoint> _trimEndpoints() {
    if (endpoints.length <= kMaxPeerEndpoints) return const [];
    final dropped = endpoints.sublist(kMaxPeerEndpoints);
    endpoints.removeRange(kMaxPeerEndpoints, endpoints.length);
    return dropped;
  }

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'certPem': certPem,
    'secret': secret,
    'name': name,
    if (customName != null) 'customName': customName,
    'platform': platform,
    'endpoints': [for (final endpoint in endpoints) endpoint.toJson()],
    'lastSyncedAtMs': lastSyncedAt?.millisecondsSinceEpoch,
    'lastReport': lastReport?.toJson(),
  };

  static SyncPeerRecord fromJson(Map<String, dynamic> json) => SyncPeerRecord(
    deviceId: json['deviceId'] as String,
    certPem: json['certPem'] as String,
    // Unreadable/absent secrets leave the peer unusable for auth; the empty
    // string can never match a presented token, so the peer is refused until
    // it is paired again.
    secret: (json['secret'] as String?) ?? '',
    name: (json['name'] as String?) ?? 'Unknown device',
    // A blank override is no override: an empty rename dialog must not blank
    // the card, and old files simply have no field to read.
    customName: ((json['customName'] as String?) ?? '').trim().isEmpty
        ? null
        : json['customName'] as String,
    platform: (json['platform'] as String?) ?? '',
    endpoints: _endpointsFromJson(json),
    lastSyncedAt: (json['lastSyncedAtMs'] as num?) == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            (json['lastSyncedAtMs'] as num).toInt(),
          ),
    lastReport: json['lastReport'] == null
        ? null
        : SyncPeerReport.fromJson(
            (json['lastReport'] as Map).cast<String, dynamic>(),
          ),
  );

  /// Reads the endpoint set, upgrading a record written before the set existed.
  ///
  /// 4.0 shipped with a single `lastHost`/`lastPort` pair, so those files are on
  /// real devices. The pair becomes a one-element set seeded with
  /// `lastSyncedAt`; the next save writes the new shape and the old fields are
  /// gone. A record with an address but no port had no usable endpoint then
  /// either, and reads as an empty set.
  static List<SyncPeerEndpoint> _endpointsFromJson(Map<String, dynamic> json) {
    final raw = json['endpoints'];
    if (raw is List) {
      return [
        for (final entry in raw)
          if (entry is Map)
            SyncPeerEndpoint.fromJson(entry.cast<String, dynamic>()),
      ].take(kMaxPeerEndpoints).toList();
    }
    final host = json['lastHost'];
    final port = (json['lastPort'] as num?)?.toInt();
    if (host is! String || host.isEmpty || port == null || port <= 0) {
      return <SyncPeerEndpoint>[];
    }
    final atMs = json['lastSyncedAtMs'] as num?;
    return [
      SyncPeerEndpoint(
        host: host,
        port: port,
        lastSuccessAt: atMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(atMs.toInt()),
      ),
    ];
  }
}
