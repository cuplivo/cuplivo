import 'dart:convert';

import 'package:Cuplivo/core/services/sync/sync_pair_qr.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // SHA-256-sized lowercase hex, as identities produce.
  final deviceId = 'a' * 64;
  const pin = '123456';

  SyncPairQrPayload roundTrip(SyncPairQrPayload payload) =>
      SyncPairQrPayload.parse(payload.toQrString());

  /// Builds a QR string straight from JSON so malformed variants stay
  /// hand-controlled (the real encoder cannot produce them).
  String rawQr(Map<String, dynamic> json) =>
      'cuplivo-pair:v1:${base64Encode(utf8.encode(jsonEncode(json)))}';

  test('round-trips every field', () {
    final payload = SyncPairQrPayload(
      deviceId: deviceId,
      name: 'desktop',
      endpoints: const [('192.168.1.10', 9527), ('10.0.0.4', 41000)],
      pin: pin,
    );
    final parsed = roundTrip(payload);
    expect(parsed.deviceId, deviceId);
    expect(parsed.name, 'desktop');
    expect(parsed.endpoints, const [
      ('192.168.1.10', 9527),
      ('10.0.0.4', 41000),
    ]);
    expect(parsed.pin, pin);
  });

  test('empty endpoint list is valid (fingerprint + pin only)', () {
    final parsed = roundTrip(
      SyncPairQrPayload(
        deviceId: deviceId,
        name: '',
        endpoints: const [],
        pin: pin,
      ),
    );
    expect(parsed.endpoints, isEmpty);
    expect(parsed.name, '');
  });

  test('a foreign string is not a pairing QR', () {
    expect(
      () => SyncPairQrPayload.parse('ai-provider:v1:whatever'),
      throwsA(
        isA<SyncPairQrException>().having(
          (e) => e.code,
          'code',
          'not_pairing_qr',
        ),
      ),
    );
  });

  test('a future version is recognisable but rejected', () {
    final payload = SyncPairQrPayload(
      deviceId: deviceId,
      name: '',
      endpoints: const [],
      pin: pin,
    );
    final v2 = payload.toQrString().replaceFirst('v1:', 'v2:');
    expect(
      () => SyncPairQrPayload.parse(v2),
      throwsA(
        isA<SyncPairQrException>().having((e) => e.code, 'code', 'bad_version'),
      ),
    );
  });

  test('malformed bodies and fields are rejected', () {
    void expectMalformed(String raw) {
      expect(
        () => SyncPairQrPayload.parse(raw),
        throwsA(
          isA<SyncPairQrException>().having((e) => e.code, 'code', 'malformed'),
        ),
      );
    }

    // Not base64 at all.
    expectMalformed('cuplivo-pair:v1:not-base64!!');

    // A deviceId that is not 64 lowercase hex.
    expectMalformed(rawQr({'d': 'a' * 63, 'pin': pin}));
    expectMalformed(rawQr({'d': 'A' * 64, 'pin': pin}));

    // A pin that is not six digits.
    expectMalformed(rawQr({'d': deviceId, 'pin': '12345'}));
    expectMalformed(rawQr({'d': deviceId, 'pin': '12345a'}));

    // An endpoint without a port, or with a port out of range.
    expectMalformed(
      rawQr({
        'd': deviceId,
        'pin': pin,
        'e': ['192.168.1.10'],
      }),
    );
    expectMalformed(
      rawQr({
        'd': deviceId,
        'pin': pin,
        'e': ['192.168.1.10:70000'],
      }),
    );

    // A non-string endpoint or name.
    expectMalformed(
      rawQr({
        'd': deviceId,
        'pin': pin,
        'e': [42],
      }),
    );
    expectMalformed(rawQr({'d': deviceId, 'pin': pin, 'n': 7}));
  });
}
