import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The seam the state layer keeps DeepSeek Harness credentials behind.
///
/// Only a cookie is ever kept here — never the launch token. Abstract so the
/// connection state machine can be tested with an in-memory implementation,
/// while the app uses [SecureDshCredentialStore].
abstract interface class DshCredentialStore {
  Future<String?> readCookie(String remoteId);

  Future<void> writeCookie(String remoteId, String cookie);

  Future<void> deleteCookie(String remoteId);
}

/// The platform-keychain implementation: the DSH v1 browser cookie is per
/// (device, server) and outlives a `dsh web` restart, so it is the reconnect
/// credential. It lives in `flutter_secure_storage` rather than the connection
/// record (a `BusinessPreferences` JSON blob is backed up and restoreable — a
/// credential is not), keyed by the remote id so a deleted remote's cookie can
/// be deleted with it.
///
/// Only a successful login writes a cookie. A 401 later means the cookie is
/// gone and the user has to paste a fresh WebUI link, which the settings page
/// surfaces as a failure rather than retrying silently.
class SecureDshCredentialStore implements DshCredentialStore {
  const SecureDshCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? _defaultStorage;

  /// Prefix of the keychain entry; one entry per remote id.
  static const String cookieKeyPrefix = 'cuplivo.dsh.cookie.';

  static const FlutterSecureStorage _defaultStorage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  final FlutterSecureStorage _storage;

  static String cookieKey(String remoteId) => '$cookieKeyPrefix$remoteId';

  @override
  Future<String?> readCookie(String remoteId) =>
      _storage.read(key: cookieKey(remoteId));

  @override
  Future<void> writeCookie(String remoteId, String cookie) =>
      _storage.write(key: cookieKey(remoteId), value: cookie);

  /// Best-effort cleanup when a remote is deleted. A locked keychain must not
  /// block the deletion: the record goes and the orphan entry is unusable
  /// without its id.
  @override
  Future<void> deleteCookie(String remoteId) async {
    try {
      await _storage.delete(key: cookieKey(remoteId));
    } catch (_) {}
  }
}
