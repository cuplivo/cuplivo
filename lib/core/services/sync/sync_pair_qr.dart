import 'dart:convert';

import 'sync_local_addresses.dart';

/// Raised when a scanned string is not a usable Cuplivo pairing QR.
///
/// [code] is a stable identifier the UI maps to a localized message:
/// `not_pairing_qr`, `bad_version` or `malformed`.
class SyncPairQrException implements Exception {
  final String code;
  const SyncPairQrException(this.code);

  @override
  String toString() => 'SyncPairQrException($code)';
}

/// The pairing QR payload (ADR-0003, slice 4): one image carries everything
/// the joining device needs —
///
/// - `deviceId`, which **is** the responder's certificate fingerprint: the
///   joiner pins it inside the TLS callback, so a wrong certificate never
///   receives the request body (the PIN included). This is what a 6-digit
///   PIN cannot do and the reason the QR is the recommended pairing path.
/// - the responder's candidate endpoints with the *actually bound* port,
///   tried in order by the joiner (the multi-adapter case a human would
///   otherwise guess at).
/// - the display name and the one-shot window's PIN, binding the image to
///   the currently open pairing window — a stale photo pairs nothing.
///
/// The wire format follows the app's QR convention — a versioned prefix
/// followed by base64-encoded JSON, as in the provider share codes — here
/// `cuplivo-pair:v1:` followed by the encoded body.
class SyncPairQrPayload {
  static const _schemePrefix = 'cuplivo-pair:';
  static const _prefix = 'cuplivo-pair:v1:';

  /// Certificate fingerprint this payload pins (64 lowercase hex).
  final String deviceId;

  /// Human-readable device name (may be empty).
  final String name;

  /// Candidate endpoints (`host`, `port`), tried in order by the joiner.
  final List<(String, int)> endpoints;

  /// The pairing window's 6-digit PIN.
  final String pin;

  SyncPairQrPayload({
    required this.deviceId,
    required this.name,
    required this.endpoints,
    required this.pin,
  });

  /// Builds the QR string.
  String toQrString() =>
      '$_prefix${base64Encode(utf8.encode(jsonEncode(_toJson())))}';

  Map<String, dynamic> _toJson() => {
    'd': deviceId,
    'n': name,
    // Bracketed for an IPv6 literal, so the port stays unambiguous to a parser
    // (this payload splits on the last colon) and to a person reading it.
    'e': [for (final (host, port) in endpoints) formatHostPort(host, port)],
    'pin': pin,
  };

  /// Parses a scanned string. Throws [SyncPairQrException] on anything that
  /// is not a v1 pairing payload with well-formed fields; an empty endpoint
  /// list is valid (fingerprint + PIN without a reachable address — the
  /// joiner then enters the host by hand, still pinned to the fingerprint).
  static SyncPairQrPayload parse(String raw) {
    final text = raw.trim();
    if (!text.startsWith(_schemePrefix)) {
      throw const SyncPairQrException('not_pairing_qr');
    }
    if (!text.startsWith(_prefix)) {
      // A future version's QR: recognizable as ours, but not consumable.
      throw const SyncPairQrException('bad_version');
    }
    final Map<String, dynamic> json;
    try {
      json =
          jsonDecode(utf8.decode(base64Decode(text.substring(_prefix.length))))
              as Map<String, dynamic>;
    } catch (_) {
      throw const SyncPairQrException('malformed');
    }
    final deviceId = json['d'];
    if (deviceId is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(deviceId)) {
      throw const SyncPairQrException('malformed');
    }
    final pin = json['pin'];
    if (pin is! String || !RegExp(r'^[0-9]{6}$').hasMatch(pin)) {
      throw const SyncPairQrException('malformed');
    }
    final name = json['n'];
    if (name != null && name is! String) {
      throw const SyncPairQrException('malformed');
    }
    final rawEndpoints = json['e'];
    if (rawEndpoints != null && rawEndpoints is! List) {
      throw const SyncPairQrException('malformed');
    }
    final endpoints = <(String, int)>[];
    for (final item in rawEndpoints as List? ?? const []) {
      if (item is! String) {
        throw const SyncPairQrException('malformed');
      }
      final split = item.lastIndexOf(':');
      if (split <= 0) {
        throw const SyncPairQrException('malformed');
      }
      final port = int.tryParse(item.substring(split + 1));
      // Stored bare: the wire form brackets an IPv6 literal, the layers that
      // dial and compare endpoints do not.
      final host = normalizeHost(item.substring(0, split));
      if (host.isEmpty || port == null || port < 1 || port > 65535) {
        throw const SyncPairQrException('malformed');
      }
      endpoints.add((host, port));
    }
    return SyncPairQrPayload(
      deviceId: deviceId,
      name: name ?? '',
      endpoints: endpoints,
      pin: pin,
    );
  }
}
