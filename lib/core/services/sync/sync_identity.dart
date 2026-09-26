import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart' as crypto;

/// Per-install sync identity (ADR-0002): a self-signed certificate IS the
/// device identity — `deviceId` is the SHA-256 of its DER encoding, and the
/// certificate doubles as the TLS credential so pairing = certificate pinning.
///
/// Generated lazily on first use and stored under the app's `sync/` directory,
/// which is deliberately outside the backup face: the private key must never
/// travel in a backup or a sync payload.
class SyncDeviceIdentity {
  final String deviceId;
  final String certPem;
  final String keyPem;
  String name;

  SyncDeviceIdentity._({
    required this.deviceId,
    required this.certPem,
    required this.keyPem,
    required this.name,
  });

  static String _deviceIdForCertPem(String certPem) => crypto.sha256
      .convert(CryptoUtils.getBytesFromPEMString(certPem))
      .toString();

  /// Loads the identity from [directory]/identity.json, creating it on first
  /// use. [fallbackName] seeds the human-readable device name.
  static Future<SyncDeviceIdentity> loadOrCreate(
    Directory directory, {
    required String fallbackName,
  }) async {
    final file = File(
      '${directory.path}${Platform.pathSeparator}identity.json',
    );
    if (await file.exists()) {
      final map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final identity = SyncDeviceIdentity._(
        deviceId: map['deviceId'] as String,
        certPem: map['certPem'] as String,
        keyPem: map['keyPem'] as String,
        name: (map['name'] as String?) ?? fallbackName,
      );
      if (_deviceIdForCertPem(identity.certPem) != identity.deviceId) {
        throw const SyncIdentityException('sync_identity_corrupt');
      }
      return identity;
    }

    final keyPair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
    final privateKey = keyPair.privateKey as RSAPrivateKey;
    final publicKey = keyPair.publicKey as RSAPublicKey;
    final csr = X509Utils.generateRsaCsrPem(
      {'CN': 'cuplivo-sync'},
      privateKey,
      publicKey,
    );
    final certPem = X509Utils.generateSelfSignedCertificate(
      privateKey,
      csr,
      // ~20 years; the certificate is pinned by hash, not by expiry windows.
      7300,
      serialNumber: DateTime.now().microsecondsSinceEpoch.toString(),
    );
    final identity = SyncDeviceIdentity._(
      deviceId: _deviceIdForCertPem(certPem),
      certPem: certPem,
      keyPem: CryptoUtils.encodeRSAPrivateKeyToPem(privateKey),
      name: fallbackName,
    );
    await directory.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'deviceId': identity.deviceId,
        'certPem': identity.certPem,
        'keyPem': identity.keyPem,
        'name': identity.name,
        'createdAtMs': DateTime.now().millisecondsSinceEpoch,
      }),
    );
    return identity;
  }

  Future<void> persist(File file) => file.writeAsString(
    jsonEncode({
      'deviceId': deviceId,
      'certPem': certPem,
      'keyPem': keyPem,
      'name': name,
    }),
  );

  /// DER bytes of the certificate, for pinning checks.
  Uint8List get certDer => CryptoUtils.getBytesFromPEMString(certPem);

  SecurityContext buildContext() {
    final context = SecurityContext(withTrustedRoots: false);
    context.useCertificateChainBytes(certDer);
    context.usePrivateKeyBytes(CryptoUtils.getBytesFromPEMString(keyPem));
    return context;
  }
}

class SyncIdentityException implements Exception {
  final String message;
  const SyncIdentityException(this.message);

  @override
  String toString() => 'SyncIdentityException: $message';
}
