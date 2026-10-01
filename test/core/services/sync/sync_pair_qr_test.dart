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

  test('an IPv6 endpoint travels bracketed and comes back bare', () {
    final payload = SyncPairQrPayload(
      deviceId: deviceId,
      name: 'desktop',
      endpoints: const [('fd00::a1b2:c3d4', 9527), ('192.168.1.10', 9527)],
      pin: pin,
    );
    final raw = payload.toQrString();
    final body = utf8.decode(
      base64Decode(raw.substring('cuplivo-pair:v1:'.length)),
    );

    // The wire form brackets the literal, so the port is unambiguous to the
    // parser and to a person reading the payload.
    expect(body, contains('[fd00::a1b2:c3d4]:9527'));
    expect(body, contains('192.168.1.10:9527'));

    // Storage and the dial keep it bare.
    expect(roundTrip(payload).endpoints, const [
      ('fd00::a1b2:c3d4', 9527),
      ('192.168.1.10', 9527),
    ]);
  });

  test('a bracketed IPv6 endpoint is accepted and stored bare', () {
    final parsed = SyncPairQrPayload.parse(
      rawQr({
        'd': deviceId,
        'pin': pin,
        'e': ['[2001:db8:1234::9]:41000'],
      }),
    );
    expect(parsed.endpoints, const [('2001:db8:1234::9', 41000)]);
  });

  test(
    'an IPv4 payload from a 4.0 peer still round-trips byte-identically',
    () {
      // The wire format did not change for IPv4: same string, same order.
      final payload = SyncPairQrPayload(
        deviceId: deviceId,
        name: 'desktop',
        endpoints: const [('192.168.1.10', 9527), ('10.0.0.4', 41000)],
        pin: pin,
      );
      final raw = payload.toQrString();
      final body = utf8.decode(
        base64Decode(raw.substring('cuplivo-pair:v1:'.length)),
      );
      expect(body, contains('192.168.1.10:9527'));
      expect(body, contains('10.0.0.4:41000'));
      expect(roundTrip(payload).endpoints, payload.endpoints);
    },
  );

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
