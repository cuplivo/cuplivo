import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One remembered LAN sync server endpoint (the initiator's point of view).
typedef LanSyncEndpoint = ({String host, int port});

/// Persists the most recently used LAN sync server endpoints.
///
/// Device-local convenience state: stored directly in [SharedPreferences] and
/// listed in `BusinessKeyRegistry.localOnlyKeys`, so it never migrates into
/// the business KV table and never enters backups. The PIN is deliberately
/// never stored — the server generates a random one per session.
class LanSyncRecentEndpoints {
  LanSyncRecentEndpoints._();

  static const storageKey = 'lan_sync_recent_endpoints_v1';

  /// Upper bound of remembered endpoints; the oldest is dropped beyond this.
  static const maxEntries = 5;

  /// Loads remembered endpoints, newest first. Malformed entries are skipped.
  static Future<List<LanSyncEndpoint>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(storageKey) ?? const [];
    final result = <LanSyncEndpoint>[];
    for (final entry in raw) {
      final parsed = _decode(entry);
      if (parsed != null) result.add(parsed);
    }
    return result;
  }

  /// Moves/inserts `host:port` to the front (deduped, capped at
  /// [maxEntries]) and persists. [current] avoids a re-read when the caller
  /// already holds the list. Returns the updated list for the caller to render.
  static Future<List<LanSyncEndpoint>> record({
    required String host,
    required int port,
    List<LanSyncEndpoint>? current,
  }) async {
    final existing = current ?? await load();
    final updated = mergeRecentEndpoints(existing, (host: host, port: port));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(storageKey, [
      for (final endpoint in updated) _encode(endpoint),
    ]);
    return updated;
  }

  static String _encode(LanSyncEndpoint endpoint) =>
      jsonEncode({'h': endpoint.host, 'p': endpoint.port});

  static LanSyncEndpoint? _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final host = decoded['h'];
      final port = decoded['p'];
      if (host is! String || host.isEmpty || port is! int) return null;
      return (host: host, port: port);
    } catch (e) {
      // Corrupt entry (e.g. hand-edited prefs): log and skip it.
      debugPrint('lan sync: dropping malformed recent endpoint "$raw": $e');
      return null;
    }
  }
}

/// Pure list update: moves/inserts [endpoint] to the front, deduped by
/// `host:port`, capped at [LanSyncRecentEndpoints.maxEntries].
List<LanSyncEndpoint> mergeRecentEndpoints(
  List<LanSyncEndpoint> current,
  LanSyncEndpoint endpoint,
) {
  return [
    endpoint,
    for (final e in current)
      if (e.host != endpoint.host || e.port != endpoint.port) e,
  ].take(LanSyncRecentEndpoints.maxEntries).toList(growable: false);
}
