import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import 'sync_identity.dart';
import 'sync_models.dart';
import 'sync_server.dart';
import 'sync_store.dart';

/// Raised when the peer answers a request with a refusal or an error status.
class SyncClientException implements Exception {
  final String message;
  final int? statusCode;
  const SyncClientException(this.message, {this.statusCode});

  @override
  String toString() => 'SyncClientException($statusCode): $message';
}

/// The result of a hello: either the peer's hello or its refusal.
class SyncHelloOutcome {
  final SyncHello? hello;
  final SyncHelloRefusal? refusal;
  const SyncHelloOutcome(this.hello, this.refusal);
}

/// mTLS HTTP client for LAN sync.
///
/// The client pins the peer's certificate by hash: for a paired device the
/// presented certificate's SHA-256 must equal the stored deviceId, or the
/// handshake is rejected. Pairing is the one moment a certificate is not yet
/// pinned — there we still bind the answer to the certificate actually seen,
/// so a passive relay cannot impersonate the peer's identity.
class SyncClient {
  SyncClient({required this.identity});

  final SyncDeviceIdentity identity;

  /// Pairs with a peer that is showing [pin]. Returns the peer's identity and
  /// the certificate to pin (the one this TLS session actually presented).
  Future<({SyncPairAnswer answer, String certPem})> pair({
    required String host,
    required int port,
    required String pin,
  }) async {
    X509Certificate? presented;
    final client = HttpClient(context: identity.buildContext())
      ..badCertificateCallback = (cert, _, _) {
        presented = cert;
        return true; // first contact: trust happens below, bound to this cert
      }
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(
        Uri.parse('https://$host:$port/pair'),
      );
      _writeJson(request, {
        'pin': pin,
        'deviceId': identity.deviceId,
        'deviceName': identity.name,
        'platform': _platformTag(),
        'certPem': identity.certPem,
      });
      final response = await request.close();
      final body = await _readJson(response);
      if (response.statusCode != HttpStatus.ok) {
        throw SyncClientException(
          (body?['error'] ?? 'pair_failed').toString(),
          statusCode: response.statusCode,
        );
      }
      final answer = SyncPairAnswer(
        deviceId: body!['deviceId'] as String,
        deviceName: (body['deviceName'] as String?) ?? '',
        platform: (body['platform'] as String?) ?? '',
        certPem: body['certPem'] as String,
      );
      final seen = presented;
      if (seen == null) {
        throw const SyncClientException('pair_no_certificate');
      }
      final seenId = crypto.sha256.convert(seen.der).toString();
      if (seenId != answer.deviceId) {
        // The answer claims an identity the TLS session did not present.
        throw const SyncClientException('pair_identity_mismatch');
      }
      return (answer: answer, certPem: answer.certPem);
    } finally {
      client.close(force: true);
    }
  }

  /// Opens a session against a paired peer.
  SyncClientSession openSession(
    SyncPeerRecord peer, {
    required String host,
    required int port,
  }) {
    return SyncClientSession(_httpForPeer(peer), 'https://$host:$port');
  }

  HttpClient _httpForPeer(SyncPeerRecord peer) {
    final client = HttpClient(context: identity.buildContext())
      ..connectionTimeout = const Duration(seconds: 10)
      ..badCertificateCallback = (cert, _, _) =>
          crypto.sha256.convert(cert.der).toString() == peer.deviceId;
    return client;
  }

  static String _platformTag() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  static void _writeJson(HttpClientRequest request, Map<String, dynamic> body) {
    final bytes = gzip.encode(utf8.encode(jsonEncode(body)));
    request.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
    request.headers.contentType = ContentType.json;
    request.contentLength = bytes.length;
    request.add(bytes);
  }

  static Future<Map<String, dynamic>?> _readJson(
    HttpClientResponse response,
  ) async {
    final text = await response.transform(utf8.decoder).join();
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}

/// One bounded sync session from the initiator's side.
class SyncClientSession {
  SyncClientSession(this._client, this._baseUrl);

  final HttpClient _client;
  final String _baseUrl;

  Future<SyncHelloOutcome> hello(SyncHello mine) async {
    final response = await _post('/sync/hello', mine.toJson());
    final body = await SyncClient._readJson(response);
    if (response.statusCode == HttpStatus.conflict && body != null) {
      return SyncHelloOutcome(null, SyncHelloRefusal.fromJson(body));
    }
    if (response.statusCode != HttpStatus.ok || body == null) {
      throw SyncClientException(
        (body?['error'] ?? 'hello_failed').toString(),
        statusCode: response.statusCode,
      );
    }
    return SyncHelloOutcome(SyncHello.fromJson(body), null);
  }

  /// Fetches the subtrees the peer owes this device.
  Future<SyncSubtreeBatch> fetchSubtrees(List<String> conversationIds) async {
    final response = await _post('/sync/subtrees', {'ids': conversationIds});
    final body = await SyncClient._readJson(response);
    if (response.statusCode != HttpStatus.ok || body == null) {
      throw SyncClientException(
        (body?['error'] ?? 'fetch_failed').toString(),
        statusCode: response.statusCode,
      );
    }
    return SyncSubtreeBatch.fromJson(body);
  }

  /// Sends this device's subtrees to the peer.
  Future<int> pushSubtrees(SyncSubtreeBatch batch) async {
    final response = await _put('/sync/subtrees', batch.toJson());
    final body = await SyncClient._readJson(response);
    if (response.statusCode != HttpStatus.ok || body == null) {
      throw SyncClientException(
        (body?['error'] ?? 'push_failed').toString(),
        statusCode: response.statusCode,
      );
    }
    return (body['applied'] as num?)?.toInt() ?? 0;
  }

  void close() => _client.close(force: true);

  Future<HttpClientResponse> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final request = await _client.postUrl(Uri.parse('$_baseUrl$path'));
    SyncClient._writeJson(request, body);
    return request.close();
  }

  Future<HttpClientResponse> _put(
    String path,
    Map<String, dynamic> body,
  ) async {
    final request = await _client.putUrl(Uri.parse('$_baseUrl$path'));
    SyncClient._writeJson(request, body);
    return request.close();
  }
}
