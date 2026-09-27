import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart' as crypto;

/// Per-install sync identity (ADR-0003): a self-signed certificate IS the
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

  /// PKCS#12 container holding the same key and certificate, base64 (standard
  /// alphabet). iOS is the reason it exists: `SecurityContext` there accepts
  /// only PKCS#12, and in a single `usePrivateKey` call rather than the
  /// certificate-chain + private-key pair. Every other platform uses the PEM
  /// fields directly.
  final String p12Base64;

  String name;

  /// Password on the PKCS#12 blob. It sits beside the unprotected private key
  /// in the same file, so it is a container format requirement, not a secret.
  static const p12Password = 'cuplivo-sync';

  SyncDeviceIdentity._({
    required this.deviceId,
    required this.certPem,
    required this.keyPem,
    required this.p12Base64,
    required this.name,
  });

  static String _deviceIdForCertPem(String certPem) => crypto.sha256
      .convert(CryptoUtils.getBytesFromPEMString(certPem))
      .toString();

  static String _p12For(String keyPem, String certPem) => base64Encode(
    Pkcs12Utils.generatePkcs12(
      keyPem,
      [certPem],
      password: p12Password,
      friendlyName: 'cuplivo-sync',
    ),
  );

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
      final certPem = map['certPem'] as String;
      final keyPem = map['keyPem'] as String;
      final identity = SyncDeviceIdentity._(
        deviceId: map['deviceId'] as String,
        certPem: certPem,
        keyPem: keyPem,
        // Rebuilt when absent rather than refusing the identity: the PEM pair
        // is the source of truth and the container is derived from it.
        p12Base64: (map['p12Base64'] as String?) ?? _p12For(keyPem, certPem),
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
    final keyPem = CryptoUtils.encodeRSAPrivateKeyToPem(privateKey);
    final identity = SyncDeviceIdentity._(
      deviceId: _deviceIdForCertPem(certPem),
      certPem: certPem,
      keyPem: keyPem,
      p12Base64: _p12For(keyPem, certPem),
      name: fallbackName,
    );
    await directory.create(recursive: true);
    await file.writeAsString(jsonEncode(identity._toJson()));
    return identity;
  }

  Map<String, dynamic> _toJson() => {
    'deviceId': deviceId,
    'certPem': certPem,
    'keyPem': keyPem,
    'p12Base64': p12Base64,
    'name': name,
    'createdAtMs': DateTime.now().millisecondsSinceEpoch,
  };

  Future<void> persist(File file) => file.writeAsString(jsonEncode(_toJson()));

  /// DER bytes of the certificate, for pinning checks.
  Uint8List get certDer => CryptoUtils.getBytesFromPEMString(certPem);

  /// The TLS credential. `useCertificateChainBytes`/`usePrivateKeyBytes` read
  /// PEM (or PKCS#12) containers — passing the DER bytes of the certificate
  /// fails the handshake at startup with `BAD_PKCS12_DATA`; iOS accepts only
  /// the PKCS#12 form.
  SecurityContext buildContext() {
    final context = SecurityContext(withTrustedRoots: false);
    if (Platform.isIOS) {
      context.usePrivateKeyBytes(
        base64Decode(p12Base64),
        password: p12Password,
      );
    } else {
      context.useCertificateChainBytes(utf8.encode(certPem));
      context.usePrivateKeyBytes(utf8.encode(keyPem));
    }
    return context;
  }
}

class SyncIdentityException implements Exception {
  final String message;
  const SyncIdentityException(this.message);

  @override
  String toString() => 'SyncIdentityException: $message';
}
