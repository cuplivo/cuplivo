import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  Future<SyncPairAnswer?> handlePair(SyncPairRequest request);
}

class SyncPairRequest {
  final String pin;
  final String deviceId;
  final String deviceName;
  final String platform;
  final String certPem;

  const SyncPairRequest({
    required this.pin,
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.certPem,
  });

  static SyncPairRequest fromJson(Map<String, dynamic> json) => SyncPairRequest(
    pin: json['pin'] as String,
    deviceId: json['deviceId'] as String,
    deviceName: (json['deviceName'] as String?) ?? '',
    platform: (json['platform'] as String?) ?? '',
    certPem: json['certPem'] as String,
  );
}

class SyncPairAnswer {
  final String deviceId;
  final String deviceName;
  final String platform;
  final String certPem;

  const SyncPairAnswer({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.certPem,
  });

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'deviceName': deviceName,
    'platform': platform,
    'certPem': certPem,
  };
}

/// mTLS HTTP server for LAN sync.
///
/// One listener serves both pairing and sync routes. TLS always *requests* a
/// client certificate but never *requires* one at the handshake layer (an
/// unpinned device must still be able to reach `/pair`); authentication of
/// `/sync/*` happens at the application layer by pinning the presented
/// certificate's SHA-256 (= deviceId) against the peer store. The sync face
/// carries API keys in later slices — never weaken this pin.
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
  final Set<String> _pinnedDeviceIds = {};

  Future<int> start({String address = '0.0.0.0', int requestedPort = 0}) async {
    await stop();
    _pinnedDeviceIds.clear();
    for (final peer in await store.listPeers()) {
      _pinnedDeviceIds.add(peer.deviceId);
    }
    final server = await HttpServer.bindSecure(
      address,
      requestedPort,
      identity.buildContext(),
      // Requested, never required: an unpinned device must still reach /pair.
      // /sync/* is authenticated at the application layer by certificate pin.
      requestClientCertificate: true,
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
    final peerDeviceId = _pinnedDeviceId(request);
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

  /// /sync/* authentication: the certificate presented in this TLS session
  /// must hash to a pinned deviceId. The peer's DER pin IS its identity.
  String? _pinnedDeviceId(HttpRequest request) {
    final cert = request.certificate;
    if (cert == null) return null;
    final deviceId = crypto.sha256.convert(cert.der).toString();
    return _pinnedDeviceIds.contains(deviceId) ? deviceId : null;
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
    // The claimed deviceId must match the certificate actually presented —
    // a passive relay cannot forge this binding. (A full MITM that terminates
    // both legs remains possible in the PIN path; the QR fingerprint path
    // added later closes it.)
    final presented = request.certificate;
    if (presented != null &&
        crypto.sha256.convert(presented.der).toString() !=
            pairRequest.deviceId) {
      _safeRespond(request, HttpStatus.forbidden, {'error': 'id_mismatch'});
      return;
    }
    final answer = await handler.handlePair(pairRequest);
    if (answer == null) {
      _safeRespond(request, HttpStatus.forbidden, {'error': 'invalid_pin'});
      return;
    }
    _pinnedDeviceIds.add(pairRequest.deviceId);
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
