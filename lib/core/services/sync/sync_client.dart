import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import 'sync_identity.dart';
import 'sync_models.dart';
import 'sync_server.dart';
import 'sync_store.dart';

/// Collects the single digest a chunked hash conversion produces.
class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}

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
  ///
  /// [listenPort] is this device's own sync listener port, advertised so the
  /// responder can store a usable endpoint for the return direction.
  ///
  /// [expectedDeviceId] is the QR path: the certificate fingerprint scanned
  /// out-of-band. When set, the TLS callback itself refuses any other
  /// certificate, so the request body — the PIN included — never leaves this
  /// device towards a wrong endpoint. Without it (manual PIN entry) the
  /// answer is still bound to the certificate actually seen, which defeats a
  /// passive relay but not an active one; the QR is the recommended path.
  Future<({SyncPairAnswer answer, String certPem})> pair({
    required String host,
    required int port,
    required String pin,
    int? listenPort,
    String? expectedDeviceId,
  }) async {
    X509Certificate? presented;
    final client = HttpClient(context: identity.buildContext())
      ..badCertificateCallback = (cert, _, _) {
        presented = cert;
        if (expectedDeviceId != null) {
          // Hard pin: reject inside the handshake, before any request byte.
          return crypto.sha256.convert(cert.der).toString() == expectedDeviceId;
        }
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
        if (listenPort != null) 'listenPort': listenPort,
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
        secret: body['secret'] as String,
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
    } on HandshakeException {
      // Only the QR path refuses a certificate inside the callback, and such
      // a refusal must not surface as "unreachable" (HandshakeException
      // extends SocketException).
      if (expectedDeviceId != null) {
        throw const SyncClientException('pair_fingerprint_mismatch');
      }
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// Opens a session against a paired peer. The peer's pinned certificate is
  /// what authenticates *this* side of the channel; the peer's secret is what
  /// authenticates *us* to it (see [SyncServer]).
  SyncClientSession openSession(
    SyncPeerRecord peer, {
    required String host,
    required int port,
  }) {
    return SyncClientSession(
      _httpForPeer(peer),
      'https://$host:$port',
      deviceId: identity.deviceId,
      token: peer.secret,
    );
  }

  HttpClient _httpForPeer(SyncPeerRecord peer) {
    final client = HttpClient(context: identity.buildContext())
      ..connectionTimeout = const Duration(seconds: 10)
      // Pinning the listener's certificate is the whole server-side
      // authentication: nothing else can answer as this peer.
      ..badCertificateCallback = (cert, _, _) =>
          crypto.sha256.convert(cert.der).toString() == peer.deviceId;
    return client;
  }

  /// Unpair propagation (slice 5): tells a still-reachable peer to forget
  /// this device, authenticated by the pairing secret the caller still
  /// holds. Best effort by contract — the caller proceeds with its local
  /// unpair regardless of the outcome, and an unreachable peer falls back to
  /// discovering the revocation at its next session.
  Future<void> revoke({
    required SyncPeerRecord peer,
    required String host,
    required int port,
  }) async {
    final client = _httpForPeer(peer)..connectionTimeout = _revokeTimeout;
    try {
      final request = await client.postUrl(
        Uri.parse('https://$host:$port/sync/revoke'),
      );
      request.headers.set(SyncServer.deviceHeader, identity.deviceId);
      request.headers.set(SyncServer.tokenHeader, peer.secret);
      request.headers.contentType = ContentType.json;
      request.add(const []);
      final response = await request.close().timeout(_revokeTimeout);
      await response.drain<void>();
      if (response.statusCode != HttpStatus.ok) {
        throw SyncClientException(
          'revoke_failed',
          statusCode: response.statusCode,
        );
      }
    } finally {
      client.close(force: true);
    }
  }

  static const _revokeTimeout = Duration(seconds: 3);

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
  SyncClientSession(
    this._client,
    this._baseUrl, {
    required String deviceId,
    required String token,
  }) : // Public names omit the private-field prefix (ChatService convention).
       // ignore: prefer_initializing_formals
       _deviceId = deviceId,
       // ignore: prefer_initializing_formals
       _token = token;

  final HttpClient _client;
  final String _baseUrl;
  final String _deviceId;
  final String _token;

  Future<SyncHelloOutcome> hello(SyncHello mine) async {
    final response = await _post('/sync/hello', mine.toJson());
    final body = await SyncClient._readJson(response);
    if (response.statusCode == HttpStatus.conflict && body != null) {
      return SyncHelloOutcome(null, SyncHelloRefusal.fromJson(body));
    }
    if (response.statusCode == HttpStatus.unauthorized) {
      // The peer's auth gate refused our secret: from this side the pairing
      // is gone — unpaired over there, or re-paired with a rotated secret.
      // Surfacing it as a refusal keeps the localized wording reachable
      // instead of a raw `SyncClientException(401)` on the peer card.
      return const SyncHelloOutcome(
        null,
        SyncHelloRefusal(SyncRefusalReason.notPaired, 'unauthenticated'),
      );
    }
    if (response.statusCode != HttpStatus.ok || body == null) {
      throw SyncClientException(
        (body?['error'] ?? 'hello_failed').toString(),
        statusCode: response.statusCode,
      );
    }
    return SyncHelloOutcome(SyncHello.fromJson(body), null);
  }

  /// Fetches the conversation subtrees and business rows the peer owes this
  /// device. Runs even for an empty request: the responder finalises its own
  /// plan (deletions, checkpoint, report) inside this beat.
  Future<SyncDeltaBatch> fetchSubtrees(SyncFetchRequest request) async {
    final response = await _post('/sync/subtrees', request.toJson());
    final body = await SyncClient._readJson(response);
    if (response.statusCode != HttpStatus.ok || body == null) {
      throw SyncClientException(
        (body?['error'] ?? 'fetch_failed').toString(),
        statusCode: response.statusCode,
      );
    }
    return SyncDeltaBatch.fromJson(body);
  }

  /// Sends this device's changed conversation subtrees and business rows.
  Future<int> pushDelta(SyncDeltaBatch batch) async {
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

  /// Streams one blob into [destination]. A file blob is hashed while it
  /// writes and refused when the digest does not match [entry]'s content hash.
  ///
  /// A skill-directory entry is *not* byte-verified: its hash describes the
  /// unpacked tree (see `SkillDirectorySync`), and the zip bytes have no
  /// published digest of their own. That entry is verified by re-hashing the
  /// extracted directory before it is swapped in, which is strictly stronger
  /// than a transport checksum. Returns the received byte size; [destination]
  /// is deleted on any failure.
  Future<int> fetchBlob(SyncBlobEntry entry, File destination) async {
    final request = await _client.getUrl(
      Uri.parse('$_baseUrl${SyncServer.blobPathPrefix}${entry.contentHash}'),
    );
    _authenticate(request);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      // Drain so the connection can be reused/closed cleanly.
      await response.drain<void>();
      throw SyncClientException(
        'blob_unavailable',
        statusCode: response.statusCode,
      );
    }
    final digestSink = _DigestSink();
    final conversion = crypto.sha256.startChunkedConversion(digestSink);
    var received = 0;
    final sink = destination.openWrite();
    try {
      await for (final chunk in response) {
        conversion.add(chunk);
        received += chunk.length;
        sink.add(chunk);
      }
      conversion.close();
      await sink.flush();
      await sink.close();
    } catch (_) {
      await sink.close();
      await _deleteQuietly(destination);
      rethrow;
    }
    final mustVerifyBytes = entry.kind == SyncBlobEntry.kindFile;
    if (mustVerifyBytes && digestSink.value?.toString() != entry.contentHash) {
      await _deleteQuietly(destination);
      throw const SyncClientException('blob_digest_mismatch');
    }
    return received;
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  void close() => _client.close(force: true);

  Future<HttpClientResponse> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final request = await _client.postUrl(Uri.parse('$_baseUrl$path'));
    _authenticate(request);
    SyncClient._writeJson(request, body);
    return request.close();
  }

  Future<HttpClientResponse> _put(
    String path,
    Map<String, dynamic> body,
  ) async {
    final request = await _client.putUrl(Uri.parse('$_baseUrl$path'));
    _authenticate(request);
    SyncClient._writeJson(request, body);
    return request.close();
  }

  /// Every `/sync/*` request names this device and proves the pairing with its
  /// secret; the listener has no TLS client certificate to check.
  void _authenticate(HttpClientRequest request) {
    request.headers.set(SyncServer.deviceHeader, _deviceId);
    request.headers.set(SyncServer.tokenHeader, _token);
  }
}
