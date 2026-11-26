import 'dart:convert';
import 'dart:io';

import 'package:libtailcat/libtailcat.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The identity this install presents to tailcat peers.
///
/// The private key is a credential: it is what proves "the same device" to a
/// server that configured an allow-list. The public key is derived from it by
/// tailcat and is safe to show, copy and paste into the ds-hu plugin's
/// "allowed client public keys" list.
class HarnessTailcatIdentity {
  const HarnessTailcatIdentity({
    required this.privateKey,
    required this.publicKey,
  });

  /// The node key the tailcat client signs with. Never rendered or logged.
  final TailcatPrivateKey privateKey;

  /// `nodekey:<64 hex>`, the form the ds-hu plugin's allow-list stores.
  final String publicKey;

  @override
  String toString() => 'HarnessTailcatIdentity(publicKey: $publicKey)';
}

/// Loads (or creates once) this install's [HarnessTailcatIdentity].
///
/// One store instance backs both surfaces that need the identity — the tunnel
/// dialer and the settings key row — so the key a user adds to an allow-list is
/// the key the tunnel actually presents.
abstract interface class HarnessTailcatIdentityStore {
  Future<HarnessTailcatIdentity> load();
}

/// Keeps the identity in the app support directory, generating it on first use.
///
/// A server's allow-list names the client public key, so the key has to survive
/// restarts; an ephemeral client key would stop working the moment the app
/// restarts. The private key stays in the app's private support directory.
final class FileHarnessTailcatIdentityStore
    implements HarnessTailcatIdentityStore {
  FileHarnessTailcatIdentityStore({
    Future<Directory> Function()? supportDirectory,
    TailcatKeys Function()? generateKeys,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _generateKeys = generateKeys ?? TailcatKeys.generate;

  /// The ds-hu plugin accepts exactly `nodekey:` plus 32 bytes of hex.
  static final RegExp _publicKeyShape = RegExp(r'^nodekey:[0-9a-f]{64}$');

  static const String _directoryName = 'harness';
  static const String _fileName = 'tailcat-client-identity.json';
  static const int _version = 1;

  final Future<Directory> Function() _supportDirectory;
  final TailcatKeys Function() _generateKeys;

  Future<HarnessTailcatIdentity>? _loading;

  @override
  Future<HarnessTailcatIdentity> load() async {
    final existing = _loading;
    if (existing != null) return existing;
    final future = _load();
    _loading = future;
    try {
      return await future;
    } catch (_) {
      // A load that failed says nothing about the next one (the disk may have
      // been full, the directory temporarily unavailable): let a retry run.
      if (identical(_loading, future)) _loading = null;
      rethrow;
    }
  }

  Future<HarnessTailcatIdentity> _load() async {
    final support = await _supportDirectory();
    final file = File(p.join(support.path, _directoryName, _fileName));
    final stored = await _read(file);
    if (stored != null) return stored;
    // Missing or unreadable: this device has no identity worth keeping, so
    // mint one. The write replaces a damaged file instead of accumulating.
    final keys = _generateKeys();
    final identity = HarnessTailcatIdentity(
      privateKey: keys.privateKey,
      publicKey: keys.publicKey,
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(<String, Object?>{
        'version': _version,
        'privateKey': identity.privateKey.reveal(),
        'publicKey': identity.publicKey,
      }),
      flush: true,
    );
    return identity;
  }

  Future<HarnessTailcatIdentity?> _read(File file) async {
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) return null;
      if (decoded['version'] != _version) return null;
      final privateKey = decoded['privateKey'];
      final publicKey = decoded['publicKey'];
      if (privateKey is! String || privateKey.isEmpty) return null;
      if (publicKey is! String || !_publicKeyShape.hasMatch(publicKey)) {
        return null;
      }
      return HarnessTailcatIdentity(
        privateKey: TailcatPrivateKey(privateKey),
        publicKey: publicKey,
      );
    } catch (_) {
      // Unreadable or unrecognisable: regenerate over it below. An allow-list
      // entry for the old key cannot be used by a key we cannot read anyway.
      return null;
    }
  }
}
