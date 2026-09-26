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

  Future<SyncPeerRecord?> findPeer(String deviceId) async {
    for (final peer in await listPeers()) {
      if (peer.deviceId == deviceId) return peer;
    }
    return null;
  }

  Future<void> savePeer(SyncPeerRecord peer) async {
    await _peersDir.create(recursive: true);
    final file = File(
      '${_peersDir.path}${Platform.pathSeparator}${peer.deviceId}.json',
    );
    await file.writeAsString(jsonEncode(peer.toJson()));
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
    await _checkpointFile(deviceId).writeAsBytes(bytes, flush: true);
  }

  File _checkpointFile(String deviceId) =>
      File('${_checkpointsDir.path}${Platform.pathSeparator}$deviceId.json.gz');
}

/// One paired device as this device knows it.
class SyncPeerRecord {
  final String deviceId;

  /// Pinned certificate (PEM). Trust = this exact certificate; anything else
  /// fails the handshake.
  final String certPem;
  String name;
  String platform;
  String? lastHost;
  int? lastPort;
  DateTime? lastSyncedAt;
  String? lastResult;

  SyncPeerRecord({
    required this.deviceId,
    required this.certPem,
    required this.name,
    required this.platform,
    this.lastHost,
    this.lastPort,
    this.lastSyncedAt,
    this.lastResult,
  });

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'certPem': certPem,
    'name': name,
    'platform': platform,
    'lastHost': lastHost,
    'lastPort': lastPort,
    'lastSyncedAtMs': lastSyncedAt?.millisecondsSinceEpoch,
    'lastResult': lastResult,
  };

  static SyncPeerRecord fromJson(Map<String, dynamic> json) => SyncPeerRecord(
    deviceId: json['deviceId'] as String,
    certPem: json['certPem'] as String,
    name: (json['name'] as String?) ?? 'Unknown device',
    platform: (json['platform'] as String?) ?? '',
    lastHost: json['lastHost'] as String?,
    lastPort: (json['lastPort'] as num?)?.toInt(),
    lastSyncedAt: (json['lastSyncedAtMs'] as num?) == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            (json['lastSyncedAtMs'] as num).toInt(),
          ),
    lastResult: json['lastResult'] as String?,
  );
}
