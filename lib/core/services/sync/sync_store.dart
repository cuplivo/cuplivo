import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'sync_models.dart';

/// File-backed persistence for sync state, all under the app's `sync/`
/// directory (outside the backup face — peer state and checkpoints are
/// device-local by definition):
///
/// - `identity.json`          — owned by [SyncDeviceIdentity]
/// - `peers/<deviceId>.json`  — pinned certificate + display info + endpoint
/// - `checkpoints/<deviceId>.json.gz` — per-peer checkpoint
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
    records.sort((a, b) => a.name.compareTo(b.name));
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

  Future<void> savePeer(SyncPeerRecord peer) async {
    await _peersDir.create(recursive: true);
    final file = File(
      '${_peersDir.path}${Platform.pathSeparator}${peer.deviceId}.json',
    );
    await _writeAtomic(file, utf8.encode(jsonEncode(peer.toJson())));
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
}

/// How many endpoints a peer record remembers. Bounded because the set is
/// learned (the pairing QR's candidates plus the address every session is seen
/// at) and a stale address only costs one failed connect before the next
/// candidate is tried, so a long memory buys little and the tail grows forever.
const kMaxPeerEndpoints = 6;

/// One remembered address of a paired device.
///
/// The address is an attribute of the **(device, network)** pair, not of the
/// device: the same laptop is reachable at a different address at home, at work
/// and on a phone hotspot. Only the certificate fingerprint identifies a peer —
/// an address is a hint that every connection re-verifies against the pin, so
/// remembering several of them can never pair or sync with the wrong device.
class SyncPeerEndpoint {
  final String host;
  final int port;

  /// When a session last succeeded over this endpoint. Orders the set and is
  /// what the peer card's address line shows.
  DateTime? lastSuccessAt;

  SyncPeerEndpoint({
    required this.host,
    required this.port,
    this.lastSuccessAt,
  });

  /// How a human types it: `192.168.1.7:9527`.
  String get label => '$host:$port';

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'lastSuccessAtMs': lastSuccessAt?.millisecondsSinceEpoch,
  };

  static SyncPeerEndpoint fromJson(Map<String, dynamic> json) {
    final atMs = json['lastSuccessAtMs'] as num?;
    return SyncPeerEndpoint(
      host: json['host'] as String,
      port: (json['port'] as num).toInt(),
      lastSuccessAt: atMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(atMs.toInt()),
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

  String name;
  String platform;

  /// Remembered endpoints, best first: the one a session last succeeded over,
  /// then the candidates pairing advertised. Empty when the peer was paired
  /// without an address at all.
  List<SyncPeerEndpoint> endpoints;

  DateTime? lastSyncedAt;

  /// Outcome of the most recent session with this peer, as counters so the
  /// panel can localize it.
  SyncPeerReport? lastReport;

  SyncPeerRecord({
    required this.deviceId,
    required this.certPem,
    required this.secret,
    required this.name,
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
  /// promoted to the front and its timestamp refreshed. A session that ran at
  /// all — including one the peer refused — proves this address reaches the
  /// peer on this network, which is exactly what the order should track.
  void noteEndpointSuccess(String host, int port, {DateTime? at}) {
    endpoints.removeWhere(
      (endpoint) => endpoint.host == host && endpoint.port == port,
    );
    endpoints.insert(
      0,
      SyncPeerEndpoint(
        host: host,
        port: port,
        lastSuccessAt: at ?? DateTime.now(),
      ),
    );
    _trimEndpoints();
  }

  /// Keeps candidates hinted by pairing (the QR's other endpoints, or the
  /// addresses an initiator advertised) without claiming any of them works:
  /// they land after the proven endpoint, unstamped, and are tried only once
  /// the ones ahead of them fail.
  void rememberEndpointCandidates(Iterable<(String, int)> candidates) {
    for (final (host, port) in candidates) {
      if (host.isEmpty || port <= 0) continue;
      if (endpoints.any((e) => e.host == host && e.port == port)) continue;
      endpoints.add(SyncPeerEndpoint(host: host, port: port));
    }
    _trimEndpoints();
  }

  /// Manual repair: the entered address replaces the whole set. The automatic
  /// memory is what failed (or the user would not be typing), so keeping the
  /// rest would keep the failure.
  void replaceEndpoints(String host, int port) {
    endpoints = [SyncPeerEndpoint(host: host, port: port)];
  }

  void _trimEndpoints() {
    if (endpoints.length > kMaxPeerEndpoints) {
      endpoints.removeRange(kMaxPeerEndpoints, endpoints.length);
    }
  }

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'certPem': certPem,
    'secret': secret,
    'name': name,
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
