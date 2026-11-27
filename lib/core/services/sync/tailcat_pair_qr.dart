import 'dart:convert';

import 'sync_transport.dart';

/// One remote pairing code, as shown by one device and scanned or pasted into
/// another.
///
/// This is the remote counterpart of the LAN pairing code (`SyncPairQrPayload`,
/// ADR-0003): the LAN code carries the peer's endpoints because the LAN pairing
/// walk dials them directly, while the remote code carries the peer's tailcat
/// address because
/// that address is the only way to reach it. The scheme is separate on
/// purpose — an old app scanning a remote code must answer "not a sync code",
/// not misread it, and the LAN parser is left untouched by this feature.
class TailcatPairQrPayload {
  const TailcatPairQrPayload({
    required this.deviceId,
    required this.name,
    required this.address,
    required this.pin,
  });

  static const String scheme = 'cuplivo-tailcat:';
  static const String _prefix = '${scheme}v1:';

  static final RegExp _deviceIdPattern = RegExp(r'^[0-9a-fA-F]{64}$');
  static final RegExp _pinPattern = RegExp(r'^\d{6}$');

  /// The peer's certificate fingerprint, the trust anchor pairing exchanges
  /// (the same value the LAN QR carries).
  final String deviceId;

  /// The peer's self-reported device name, shown before pairing completes.
  final String name;

  /// The peer's tailcat address text. Secret: it is the capability to reach
  /// the device, which is why the payload only ever travels in the pairing
  /// dialog's QR/paste flow.
  final String address;

  /// The one-shot pairing PIN, from the same pairing window the LAN flow uses.
  final String pin;

  /// The endpoint candidate a pairing walk starts from.
  List<(String, int)> get endpoints => [
    (tailcatHost(address), kTailcatRemotePort),
  ];

  /// The text a QR code encodes.
  String toQrString() {
    final json = jsonEncode({
      'd': deviceId,
      'n': name,
      'a': address,
      'pin': pin,
    });
    return '$_prefix${base64UrlEncode(utf8.encode(json))}';
  }

  /// Parses [raw], throwing [TailcatPairQrException] for anything that is not
  /// a valid remote pairing code.
  static TailcatPairQrPayload parse(String raw) {
    final text = raw.trim();
    if (!text.startsWith(scheme)) {
      throw const TailcatPairQrException('not_tailcat_qr');
    }
    if (!text.startsWith(_prefix)) {
      throw const TailcatPairQrException('bad_version');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(
        utf8.decode(base64Url.decode(text.substring(_prefix.length))),
      );
    } on FormatException {
      throw const TailcatPairQrException('malformed');
    }
    if (decoded is! Map) throw const TailcatPairQrException('malformed');
    final deviceId = decoded['d'];
    final name = decoded['n'];
    final address = decoded['a'];
    final pin = decoded['pin'];
    if (deviceId is! String ||
        !_deviceIdPattern.hasMatch(deviceId) ||
        address is! String ||
        !looksLikeTailcatAddress(address) ||
        pin is! String ||
        !_pinPattern.hasMatch(pin) ||
        (name != null && name is! String)) {
      throw const TailcatPairQrException('malformed');
    }
    return TailcatPairQrPayload(
      deviceId: deviceId.toLowerCase(),
      name: name is String ? name : '',
      address: normalizeTailcatAddress(address),
      pin: pin,
    );
  }

  /// Redacted description: the address is a secret, and an object dumped into
  /// a log must not carry it.
  @override
  String toString() =>
      'TailcatPairQrPayload(deviceId: $deviceId, name: $name, address: <redacted>, pin: <redacted>)';
}

/// Why a scanned or pasted value is not a remote pairing code.
class TailcatPairQrException implements Exception {
  const TailcatPairQrException(this.code);

  /// Stable error code for the UI layer: `not_tailcat_qr`, `bad_version` or
  /// `malformed`.
  final String code;

  @override
  String toString() => 'TailcatPairQrException($code)';
}
