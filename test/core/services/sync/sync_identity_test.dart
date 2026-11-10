import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/services/sync/sync_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('cuplivo_sync_identity_');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'the identity is stable across loads and keyed by the certificate',
    () async {
      final first = await SyncDeviceIdentity.loadOrCreate(
        directory,
        fallbackName: 'device-a',
      );
      final second = await SyncDeviceIdentity.loadOrCreate(
        directory,
        fallbackName: 'device-b',
      );

      // deviceId is the trust anchor every pin compares against, so a reload
      // must reproduce it exactly — and the fallback name must not overwrite the
      // stored one.
      expect(second.deviceId, first.deviceId);
      expect(second.certPem, first.certPem);
      expect(second.keyPem, first.keyPem);
      expect(second.name, 'device-a');
    },
  );

  test('both TLS credential forms load', () async {
    final identity = await SyncDeviceIdentity.loadOrCreate(
      directory,
      fallbackName: 'device',
    );

    // Other platforms use the PEM pair, which the end-to-end suite exercises
    // by handshaking. The PKCS#12 container is what iOS alone consumes, so it
    // cannot be reached by a test here — but it can still be proven
    // well-formed: BoringSSL parses the same format on every platform, so a
    // generation bug (rather than an OS difference) surfaces as a throw.
    expect(
      () => SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(utf8.encode(identity.certPem))
        ..usePrivateKeyBytes(utf8.encode(identity.keyPem)),
      returnsNormally,
    );
    expect(
      () => SecurityContext(withTrustedRoots: false).usePrivateKeyBytes(
        base64Decode(identity.p12Base64),
        password: SyncDeviceIdentity.p12Password,
      ),
      returnsNormally,
    );
  });
}
