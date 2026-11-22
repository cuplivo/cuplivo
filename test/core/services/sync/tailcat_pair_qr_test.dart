import 'dart:convert';

import 'package:Cuplivo/core/services/sync/sync_pair_qr.dart';
import 'package:Cuplivo/core/services/sync/sync_transport.dart';
import 'package:Cuplivo/core/services/sync/tailcat_pair_qr.dart';
import 'package:flutter_test/flutter_test.dart';

/// The remote pairing code (ADR-0020, decision 6): a separate scheme from the
/// LAN QR on purpose, because an old build must answer "not a sync code" rather
/// than misread it, and the remote address it carries is a capability.
///
/// The scheme is `cuplivo-tailcat:v1:<base64url(JSON)>` with `{d, n, a, pin}`,
/// where `d` is the same certificate fingerprint the LAN QR pins.
void main() {
  // SHA-256-sized lowercase hex, as identities produce.
  final deviceId = '0123456789abcdef' * 4;
  const address = '3a7f9c2e5b1d8046a4c6e8f0b2d4a6c8e0f2a4b6c8d0e2f4';
  const pin = '123456';

  TailcatPairQrPayload payload({
    String name = 'desktop',
    String qrAddress = address,
    String qrPin = pin,
  }) => TailcatPairQrPayload(
    deviceId: deviceId,
    name: name,
    address: qrAddress,
    pin: qrPin,
  );

  /// Builds a QR string straight from JSON so malformed variants stay
  /// hand-controlled (the real encoder cannot produce them).
  String rawQr(Map<String, dynamic> json) =>
      'cuplivo-tailcat:v1:'
      '${base64UrlEncode(utf8.encode(jsonEncode(json)))}';

  Matcher throwsQrCode(String code) => throwsA(
    isA<TailcatPairQrException>().having((e) => e.code, 'code', code),
  );

  String bodyOf(String raw) => raw.substring('cuplivo-tailcat:v1:'.length);

  group('wire format', () {
    test('the encoded body is the documented {d, n, a, pin} map', () {
      final raw = payload().toQrString();
      expect(raw, startsWith('cuplivo-tailcat:v1:'));
      expect(jsonDecode(utf8.decode(base64Url.decode(bodyOf(raw)))), {
        'd': deviceId,
        'n': 'desktop',
        'a': address,
        'pin': pin,
      });
    });

    test('round-trips every field', () {
      final parsed = TailcatPairQrPayload.parse(payload().toQrString());
      expect(parsed.deviceId, deviceId);
      expect(parsed.name, 'desktop');
      expect(parsed.address, address);
      expect(parsed.pin, pin);
    });

    test('the only endpoint candidate is the address on the remote port', () {
      final parsed = TailcatPairQrPayload.parse(payload().toQrString());
      expect(parsed.endpoints, [(tailcatHost(address), kTailcatRemotePort)]);
      expect(kTailcatRemotePort, 9527);
    });

    test('the LAN parser refuses a remote code as a foreign code', () {
      // The two schemes must not collide: this is the "an old app says not a
      // sync code" half of decision 6, checked from the other side.
      expect(
        () => SyncPairQrPayload.parse(payload().toQrString()),
        throwsA(
          isA<SyncPairQrException>().having(
            (e) => e.code,
            'code',
            'not_pairing_qr',
          ),
        ),
      );
    });
  });

  group('a foreign string is not a remote code', () {
    test('a LAN pairing code is not a remote code', () {
      final lan = SyncPairQrPayload(
        deviceId: deviceId,
        name: 'desktop',
        endpoints: const [('192.168.1.7', 9527)],
        pin: pin,
      );
      expect(
        () => TailcatPairQrPayload.parse(lan.toQrString()),
        throwsQrCode('not_tailcat_qr'),
      );
    });

    test('a random string is not a remote code', () {
      expect(
        () => TailcatPairQrPayload.parse('hello, this is not a pairing code'),
        throwsQrCode('not_tailcat_qr'),
      );
    });

    test('an empty string is not a remote code', () {
      expect(
        () => TailcatPairQrPayload.parse(''),
        throwsQrCode('not_tailcat_qr'),
      );
    });
  });

  group('a future version is recognisable but refused', () {
    test('a v2 code is bad_version, not a foreign code', () {
      final v2 = payload().toQrString().replaceFirst('v1:', 'v2:');
      expect(() => TailcatPairQrPayload.parse(v2), throwsQrCode('bad_version'));
    });

    test('a bare scheme without a version is a version error', () {
      expect(
        () => TailcatPairQrPayload.parse('cuplivo-tailcat:'),
        throwsQrCode('bad_version'),
      );
    });
  });

  group('malformed codes are refused', () {
    void expectMalformed(String raw) => expect(
      () => TailcatPairQrPayload.parse(raw),
      throwsQrCode('malformed'),
      reason: raw,
    );

    test('a body that is not base64url JSON is malformed', () {
      expectMalformed('cuplivo-tailcat:v1:not base64!!');
      expectMalformed(
        'cuplivo-tailcat:v1:${base64UrlEncode(utf8.encode('not json'))}',
      );
      // Valid JSON, but not the object the payload is.
      expectMalformed(
        'cuplivo-tailcat:v1:${base64UrlEncode(utf8.encode('[]'))}',
      );
    });

    test('a missing required field is malformed', () {
      // `d` (fingerprint), `a` (address) and `pin` are required; `n` is not.
      expectMalformed(rawQr({'n': 'desktop', 'a': address, 'pin': pin}));
      expectMalformed(rawQr({'d': deviceId, 'n': 'desktop', 'pin': pin}));
      expectMalformed(rawQr({'d': deviceId, 'n': 'desktop', 'a': address}));
    });

    test('a fingerprint that is not 64 hex is malformed', () {
      expectMalformed(rawQr({'d': 'a' * 63, 'a': address, 'pin': pin}));
      expectMalformed(rawQr({'d': 'g' * 64, 'a': address, 'pin': pin}));
      expectMalformed(rawQr({'d': 42, 'a': address, 'pin': pin}));
    });

    test('a pin that is not six digits is malformed', () {
      expectMalformed(rawQr({'d': deviceId, 'a': address, 'pin': '12345'}));
      expectMalformed(rawQr({'d': deviceId, 'a': address, 'pin': '12345a'}));
      expectMalformed(rawQr({'d': deviceId, 'a': address, 'pin': 123456}));
    });

    test('an address that cannot be a tailcat address is malformed', () {
      expectMalformed(rawQr({'d': deviceId, 'a': 42, 'pin': pin}));
      // Too short, a character a URI host cannot carry, the stored `tcat:`
      // form instead of the bare text, and one past the cap.
      expectMalformed(rawQr({'d': deviceId, 'a': 'short', 'pin': pin}));
      expectMalformed(
        rawQr({'d': deviceId, 'a': 'contains/slash/$address', 'pin': pin}),
      );
      expectMalformed(
        rawQr({'d': deviceId, 'a': tailcatHost(address), 'pin': pin}),
      );
      expectMalformed(rawQr({'d': deviceId, 'a': 'a' * 2049, 'pin': pin}));
    });

    test('a non-string name is malformed', () {
      expectMalformed(rawQr({'d': deviceId, 'a': address, 'pin': pin, 'n': 7}));
    });
  });

  group('normalisation', () {
    test('a missing name is the only optional field', () {
      final parsed = TailcatPairQrPayload.parse(
        rawQr({'d': deviceId, 'a': address, 'pin': pin}),
      );
      expect(parsed.name, '');
      expect(parsed.address, address);
    });

    test('an uppercase fingerprint is stored lowercase', () {
      final parsed = TailcatPairQrPayload.parse(
        rawQr({'d': deviceId.toUpperCase(), 'a': address, 'pin': pin}),
      );
      expect(parsed.deviceId, deviceId);
    });

    test('whitespace around a pasted address is stripped before storing', () {
      final parsed = TailcatPairQrPayload.parse(
        rawQr({'d': deviceId, 'n': 'desktop', 'a': '  $address\n', 'pin': pin}),
      );
      expect(parsed.address, address);
      expect(parsed.endpoints, [(tailcatHost(address), kTailcatRemotePort)]);

      // The same tolerance on the encoding side: a payload built from padded
      // text still parses to the bare address.
      final padded = payload(qrAddress: '\n$address ').toQrString();
      expect(TailcatPairQrPayload.parse(padded).address, address);
    });
  });

  group('secrecy', () {
    test('toString never carries the address or the pin', () {
      final text = payload().toString();
      expect(text, isNot(contains(address)), reason: 'the address is a secret');
      expect(text, isNot(contains(pin)), reason: 'the pin is one-shot');
      expect(text, contains(deviceId), reason: 'the fingerprint is not secret');
    });

    test('the exception carries a stable code and no payload', () {
      final text = const TailcatPairQrException('malformed').toString();
      expect(text, 'TailcatPairQrException(malformed)');
    });
  });
}
