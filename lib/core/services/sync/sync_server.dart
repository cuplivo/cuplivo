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
  Future<Object> handleHello(String peerDeviceId, SyncHello initiatorHello);

  /// Subtrees this device owes the initiator.
  Future<SyncSubtreeBatch> handleFetchSubtrees(
    String peerDeviceId,
    List<String> conversationIds,
  );

  /// Applies subtrees the initiator sent. Returns how many conversations were
  /// accepted (applied or deferred — the engine owns the accounting).
  Future<int> handleApplySubtrees(String peerDeviceId, SyncSubtreeBatch batch);

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

  /// Header names of the app-layer peer authentication.
  static const deviceHeader = 'x-cuplivo-device';
  static const tokenHeader = 'x-cuplivo-token';

  Future<int> start({String address = '0.0.0.0', int requestedPort = 0}) async {
    await stop();
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
    final peerDeviceId = await _authenticatedPeer(request);
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
      default:
        _safeRespond(request, HttpStatus.notFound, {'error': 'not_found'});
    }
  }

  /// /sync/* authentication: the caller must name a paired device and present
  /// that peer's pairing-established secret. Compared in constant time so the
  /// comparison itself leaks nothing. The peer is read from the store per
  /// request, so pairing or unpairing while the listener runs takes effect
  /// immediately.
  Future<String?> _authenticatedPeer(HttpRequest request) async {
    final deviceId = request.headers.value(deviceHeader);
    final token = request.headers.value(tokenHeader);
    if (deviceId == null || token == null) return null;
    final peer = await store.readPeer(deviceId);
    if (peer == null || peer.secret.isEmpty) return null;
    return _constantTimeEquals(peer.secret, token) ? deviceId : null;
  }

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
    );
    if (result is SyncHelloRefusal) {
      _respondJson(request, HttpStatus.conflict, result.toJson());
      return;
    }
    _respondJson(request, HttpStatus.ok, (result as SyncHello).toJson());
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
        SyncSubtreeBatch.fromJson(body),
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
      final ids = (body['ids'] as List? ?? const [])
          .map((id) => id.toString())
          .toList(growable: false);
      final batch = await handler.handleFetchSubtrees(peerDeviceId, ids);
      _respondJson(request, HttpStatus.ok, batch.toJson());
      return;
    }
    _safeRespond(request, HttpStatus.methodNotAllowed, {'error': 'bad_method'});
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
