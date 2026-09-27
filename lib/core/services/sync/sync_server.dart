import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart' as crypto;

import 'sync_identity.dart';
import 'sync_models.dart';
import 'sync_store.dart';

/// Handler surface the sync engine implements behind [SyncServer]. The server
/// is transport only: mTLS, routing, JSON/gzip codecs, certificate pinning.
abstract class SyncServerHandler {
  /// Returns this device's hello, or a refusal. [peerDeviceId] is the pinned
  /// identity of the caller.
  ///
  /// [remoteAddress] is the address the caller connected from, as this server
  /// saw it: with the caller's advertised `listenPort` it is what lets the
  /// responder pull blobs back over the initiator's own listener (slice 3).
  Future<Object> handleHello(
    String peerDeviceId,
    SyncHello initiatorHello, {
    String? remoteAddress,
  });

  /// Everything this device owes the initiator for the request's conversations
  /// and business rows.
  Future<SyncDeltaBatch> handleFetchSubtrees(
    String peerDeviceId,
    SyncFetchRequest request,
  );

  /// Applies what the initiator sent (conversation subtrees + business rows).
  /// Returns how many conversations were accepted (applied or deferred — the
  /// engine owns the accounting).
  Future<int> handleApplySubtrees(String peerDeviceId, SyncDeltaBatch batch);

  /// The local file backing one blob this device published, or null when the
  /// hash is unknown here (or the file is gone). The server only ever streams
  /// a file the handler names — a request never supplies a path.
  Future<File?> handleFetchBlob(String peerDeviceId, String contentHash);

  /// Pairing: validate the PIN, persist the peer, answer with our identity.
  /// Returns null when the PIN is wrong or pairing is not open.
  ///
  /// [initiatorHost] is the address the initiator connected from (as this
  /// server saw it) and [request.listenPort] the initiator's own sync
  /// listener — together they let the responder store a usable endpoint.
  Future<SyncPairAnswer?> handlePair(
    SyncPairRequest request,
    String? initiatorHost,
  );

  /// Unpair propagation (slice 5): a paired peer presented its secret and
  /// asks this device to forget it. The handler drops the caller's peer
  /// record; only the caller's — the secret authenticates exactly that
  /// identity.
  Future<void> handleRevoke(String peerDeviceId);
}

class SyncPairRequest {
  final String pin;
  final String deviceId;
  final String deviceName;
  final String platform;
  final String certPem;

  /// The initiator's own sync listener port, so the responder can store a
  /// usable endpoint (its remote address is known from the connection).
  final int? listenPort;

  const SyncPairRequest({
    required this.pin,
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.certPem,
    this.listenPort,
  });

  static SyncPairRequest fromJson(Map<String, dynamic> json) => SyncPairRequest(
    pin: json['pin'] as String,
    deviceId: json['deviceId'] as String,
    deviceName: (json['deviceName'] as String?) ?? '',
    platform: (json['platform'] as String?) ?? '',
    certPem: json['certPem'] as String,
    listenPort: (json['listenPort'] as num?)?.toInt(),
  );
}

class SyncPairAnswer {
  final String deviceId;
  final String deviceName;
  final String platform;
  final String certPem;

  /// The per-peer secret this responder minted for the pairing. The initiator
  /// stores it and presents it on every later `/sync/*` request; it never
  /// travels outside the pinned TLS session.
  final String secret;

  const SyncPairAnswer({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.certPem,
    required this.secret,
  });

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'deviceName': deviceName,
    'platform': platform,
    'certPem': certPem,
    'secret': secret,
  };
}

/// HTTPS server for LAN sync.
///
/// One listener serves both pairing and sync routes, authenticated in two
/// layers:
///
/// - **Server → client**: the listener presents this device's self-signed
///   certificate, and the client pins it (SHA-256 of the DER must equal the
///   paired deviceId). A LAN attacker cannot impersonate the responder.
/// - **Client → server**: a per-peer secret established at pairing, sent in
///   the `X-Cuplivo-Token` header (with `X-Cuplivo-Device`) on every
///   `/sync/*` request and compared in constant time against the peer store.
///
/// Mutual TLS with pinned client certificates is **not** what this is, and the
/// reason is empirical rather than preferential: `HttpServer.bindSecure` with
/// `requestClientCertificate: true` aborts the handshake against a self-signed
/// client certificate on this platform (`Connection closed before full header
/// was received`), with an empty *and* a system trust store alike (measured,
/// Dart 3.13 / Flutter 3.47). Requesting a certificate therefore cannot be the
/// authentication mechanism while unpaired devices must still reach `/pair`
/// over the same listener. The token restores the property that matters — the
/// sync face carries API keys, so a paired identity must be proven before any
/// sync route answers — and the pairing PIN remains the human gate.
class SyncServer {
  SyncServer({
    required this.identity,
    required this.store,
    required this.handler,
  });

  final SyncDeviceIdentity identity;
  final SyncStore store;
  final SyncServerHandler handler;

  HttpServer? _server;
  int? get port => _server?.port;

  /// deviceId → shared secret for every paired peer. Held in memory because it
  /// is consulted on every `/sync/*` request: a disk read per request would put
  /// a file write race on the authentication path. Both pairing roles call
  /// [rememberPeer], so a peer paired while the listener runs is accepted at
  /// once and [forgetPeer] refuses an unpaired one at once.
  final Map<String, String> _peerSecrets = {};

  /// Header names of the app-layer peer authentication.
  static const deviceHeader = 'x-cuplivo-device';
  static const tokenHeader = 'x-cuplivo-token';

  void rememberPeer(SyncPeerRecord peer) {
    _peerSecrets[peer.deviceId] = peer.secret;
  }

  void forgetPeer(String deviceId) {
    _peerSecrets.remove(deviceId);
  }

  Future<int> start({String address = '0.0.0.0', int requestedPort = 0}) async {
    await stop();
    _peerSecrets
      ..clear()
      ..addEntries(
        (await store.listPeers()).map(
          (peer) => MapEntry(peer.deviceId, peer.secret),
        ),
      );
    final server = await HttpServer.bindSecure(
      address,
      requestedPort,
      identity.buildContext(),
      // Never request a client certificate: see the class comment. Peers are
      // authenticated per request by their pairing-established secret.
      requestClientCertificate: false,
    );
    _server = server;
    unawaited(_serve(server));
    return server.port;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server != null) await server.close(force: true);
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      try {
        await _route(request);
      } catch (error, stack) {
        _safeRespond(request, HttpStatus.internalServerError, {
          'error': '$error',
        });
        // ignore: avoid_print
        print('sync server: $error\n$stack');
      }
    }
  }

  Future<void> _route(HttpRequest request) async {
    if (request.uri.path == '/pair') {
      await _handlePair(request);
      return;
    }
    if (!request.uri.path.startsWith('/sync/')) {
      _safeRespond(request, HttpStatus.notFound, {'error': 'not_found'});
      return;
    }
    final peerDeviceId = _authenticatedPeer(request);
    if (peerDeviceId == null) {
      _safeRespond(request, HttpStatus.unauthorized, {
        'error': SyncRefusalReason.notPaired.wire,
      });
      return;
    }
    switch (request.uri.path) {
      case '/sync/hello':
        await _handleHello(request, peerDeviceId);
        break;
      case '/sync/subtrees':
        await _handleSubtrees(request, peerDeviceId);
        break;
      case '/sync/revoke':
        await _handleRevoke(request, peerDeviceId);
        break;
      default:
        if (request.uri.path.startsWith(blobPathPrefix)) {
          await _handleBlob(request, peerDeviceId);
          break;
        }
        _safeRespond(request, HttpStatus.notFound, {'error': 'not_found'});
    }
  }

  /// /sync/* authentication: the caller must name a paired device and present
  /// that peer's pairing-established secret. Compared in constant time so the
  /// comparison itself leaks nothing.
  String? _authenticatedPeer(HttpRequest request) {
    final deviceId = request.headers.value(deviceHeader);
    final token = request.headers.value(tokenHeader);
    if (deviceId == null || token == null) return null;
    final expected = _peerSecrets[deviceId];
    if (expected == null || expected.isEmpty) return null;
    return _constantTimeEquals(expected, token) ? deviceId : null;
  }

  /// Path prefix of the blob route: `/sync/blob/<sha256>`.
  static const blobPathPrefix = '/sync/blob/';

  /// A well-formed blob hash: the sha256 hex digest the manifest publishes.
  static final RegExp _blobHashPattern = RegExp(r'^[0-9a-f]{64}$');

  static bool _constantTimeEquals(String a, String b) {
    final left = utf8.encode(a);
    final right = utf8.encode(b);
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }

  Future<void> _handlePair(HttpRequest request) async {
    if (request.method != 'POST') {
      _safeRespond(request, HttpStatus.methodNotAllowed, {
        'error': 'post_only',
      });
      return;
    }
    final body = await _readJson(request);
    if (body == null) {
      _safeRespond(request, HttpStatus.badRequest, {'error': 'bad_json'});
      return;
    }
    final pairRequest = SyncPairRequest.fromJson(body);
    // The claimed deviceId must hash to the certificate the caller sent: a
    // passive relay cannot forge that binding. (A full MITM that terminates
    // both legs remains possible in the PIN path; the QR fingerprint path
    // added later closes it.)
    final presentedId = crypto.sha256
        .convert(CryptoUtils.getBytesFromPEMString(pairRequest.certPem))
        .toString();
    if (presentedId != pairRequest.deviceId) {
      _safeRespond(request, HttpStatus.forbidden, {'error': 'id_mismatch'});
      return;
    }
    final answer = await handler.handlePair(
      pairRequest,
      request.connectionInfo?.remoteAddress.address,
    );
    if (answer == null) {
      _safeRespond(request, HttpStatus.forbidden, {'error': 'invalid_pin'});
      return;
    }
    _respondJson(request, HttpStatus.ok, answer.toJson());
  }

  Future<void> _handleHello(HttpRequest request, String peerDeviceId) async {
    if (request.method != 'POST') {
      _safeRespond(request, HttpStatus.methodNotAllowed, {
        'error': 'post_only',
      });
      return;
    }
    final body = await _readJson(request);
    if (body == null) {
      _safeRespond(request, HttpStatus.badRequest, {'error': 'bad_json'});
      return;
    }
    final result = await handler.handleHello(
      peerDeviceId,
      SyncHello.fromJson(body),
      remoteAddress: request.connectionInfo?.remoteAddress.address,
    );
    if (result is SyncHelloRefusal) {
      _respondJson(request, HttpStatus.conflict, result.toJson());
      return;
    }
    _respondJson(request, HttpStatus.ok, (result as SyncHello).toJson());
  }

  /// Streams one blob. The hash names the content; the handler decides which
  /// local file (if any) backs it, so a request can never read an arbitrary
  /// path off this device.
  Future<void> _handleBlob(HttpRequest request, String peerDeviceId) async {
    if (request.method != 'GET') {
      _safeRespond(request, HttpStatus.methodNotAllowed, {'error': 'get_only'});
      return;
    }
    final hash = Uri.decodeComponent(
      request.uri.path.substring(blobPathPrefix.length),
    );
    if (!_blobHashPattern.hasMatch(hash)) {
      _safeRespond(request, HttpStatus.badRequest, {'error': 'bad_hash'});
      return;
    }
    final file = await handler.handleFetchBlob(peerDeviceId, hash);
    if (file == null || !await file.exists()) {
      _safeRespond(request, HttpStatus.notFound, {'error': 'blob_unavailable'});
      return;
    }
    try {
      final length = await file.length();
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.binary;
      request.response.headers.set(HttpHeaders.contentLengthHeader, '$length');
      await request.response.addStream(file.openRead());
      await request.response.close();
    } catch (_) {
      // The peer hung up mid-stream; nothing to salvage.
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _handleSubtrees(HttpRequest request, String peerDeviceId) async {
    if (request.method == 'PUT') {
      final body = await _readJson(request);
      if (body == null) {
        _safeRespond(request, HttpStatus.badRequest, {'error': 'bad_json'});
        return;
      }
      final applied = await handler.handleApplySubtrees(
        peerDeviceId,
        SyncDeltaBatch.fromJson(body),
      );
      _respondJson(request, HttpStatus.ok, {'applied': applied});
      return;
    }
    if (request.method == 'POST') {
      final body = await _readJson(request);
      if (body == null) {
        _safeRespond(request, HttpStatus.badRequest, {'error': 'bad_json'});
        return;
      }
      final batch = await handler.handleFetchSubtrees(
        peerDeviceId,
        SyncFetchRequest.fromJson(body),
      );
      _respondJson(request, HttpStatus.ok, batch.toJson());
      return;
    }
    _safeRespond(request, HttpStatus.methodNotAllowed, {'error': 'bad_method'});
  }

  /// Unpair propagation. The auth gate already proved the caller holds the
  /// paired secret, so this is the minimal "forget me" — one status, no body
  /// semantics to version.
  Future<void> _handleRevoke(HttpRequest request, String peerDeviceId) async {
    if (request.method != 'POST') {
      _safeRespond(request, HttpStatus.methodNotAllowed, {
        'error': 'post_only',
      });
      return;
    }
    await handler.handleRevoke(peerDeviceId);
    _safeRespond(request, HttpStatus.ok, {'revoked': true});
  }

  // ---- codecs ----

  Future<Map<String, dynamic>?> _readJson(HttpRequest request) async {
    try {
      final bytes = await request.fold<List<int>>(
        <int>[],
        (buffer, chunk) => buffer..addAll(chunk),
      );
      final decoded = request.headers.value('content-encoding') == 'gzip'
          ? gzip.decode(bytes)
          : bytes;
      return jsonDecode(utf8.decode(decoded)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  void _respondJson(
    HttpRequest request,
    int status,
    Map<String, dynamic> body,
  ) {
    _safeRespond(request, status, body);
  }

  void _safeRespond(
    HttpRequest request,
    int status,
    Map<String, dynamic> body,
  ) {
    try {
      final bytes = gzip.encode(utf8.encode(jsonEncode(body)));
      request.response.statusCode = status;
      request.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
      request.response.headers.contentType = ContentType.json;
      request.response.add(bytes);
      request.response.close();
    } catch (_) {
      // The peer hung up mid-response; nothing to salvage.
    }
  }
}
