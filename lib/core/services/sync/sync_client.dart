import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import 'sync_identity.dart';
import 'sync_local_addresses.dart';
import 'sync_models.dart';
import 'sync_server.dart';
import 'sync_store.dart';
import 'sync_transport.dart';

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

/// A transfer's budget ran out between two awaits.
///
/// A class of its own so the expiry is recognisable where it is thrown
/// (`left()`), rather than being reported as a peer refusal: the request must be
/// aborted on this path exactly as on a timed-out await, and `_transfer` cannot
/// see an exception it cannot name.
class _TransferBudgetSpent implements Exception {
  const _TransferBudgetSpent();
}

/// Default request budgets (see [SyncClientSession]). The control beats answer
/// in milliseconds on a LAN; the data beats are sized for a large push.
const Duration kSyncHelloDeadline = Duration(seconds: 60);
const Duration kSyncDataDeadline = Duration(minutes: 20);
const Duration kSyncBlobDeadline = Duration(minutes: 15);

/// Budget for one liveness probe: a request the peer answers with a bare
/// status line. A LAN host answers in milliseconds, so anything past this is
/// gone rather than slow.
const Duration kSyncPingDeadline = Duration(seconds: 5);

/// Budget for the pairing round: one control request against a device the user
/// is standing in front of, so the provider's `unreachable` wording stays
/// reachable instead of an `await` that never settles.
const Duration kSyncPairDeadline = Duration(seconds: 60);

/// Budget for one TCP connect attempt towards a candidate address. The probe
/// layer has already established that a reached candidate answers, so this only
/// has to cover the address dying between the probe and the dial: ten seconds
/// of LAN timeout would only make a black-holed address feel slower.
const Duration kSyncDialConnectTimeout = Duration(seconds: 3);

/// Budget for one TCP connect towards a remote peer. The dial crosses the
/// tailcat tunnel, whose first connection may need a relay round trip and NAT
/// traversal, so the LAN budget would report every remote peer unreachable.
const Duration kSyncRemoteDialConnectTimeout = Duration(seconds: 60);

/// Budget for the control beats over a tunnel. The hello is the first request
/// of a session and therefore pays for the tunnel coming up, which on a relayed
/// path can take seconds; the LAN deadlines would time out mid-connect.
const Duration kSyncRemoteHelloDeadline = Duration(seconds: 120);

/// Budget for one liveness probe over a tunnel: a relayed path is slow, not
/// gone, and a probe that falsely answers "offline" paints the card wrong.
const Duration kSyncRemotePingDeadline = Duration(seconds: 30);

/// The result of a hello: either the peer's hello or its refusal.
class SyncHelloOutcome {
  final SyncHello? hello;
  final SyncHelloRefusal? refusal;
  const SyncHelloOutcome(this.hello, this.refusal);
}

/// mTLS HTTP client for sync: direct against a LAN endpoint, tunneled through
/// tailcat against a remote one (ADR-0020).
///
/// The client pins the peer's certificate by hash: for a paired device the
/// presented certificate's SHA-256 must equal the stored deviceId, or the
/// handshake is rejected. Pairing is the one moment a certificate is not yet
/// pinned — there we still bind the answer to the certificate actually seen,
/// so a passive relay cannot impersonate the peer's identity.
class SyncClient {
  SyncClient({required this.identity, this.transport});

  final SyncDeviceIdentity identity;

  /// Rewrites remote (`tcat:`) endpoints and dials their tunnels. Null on a
  /// build that has no tailcat runtime; LAN sync never touches it.
  final SyncTransport? transport;

  /// Whether [host] names a remote peer rather than a network address.
  bool _isRemoteHost(String host) =>
      transport != null && isTailcatEndpointHost(host);

  /// The endpoint an HTTP client should dial for [host], and whether it is
  /// remote. Both call sites that build a peer URL go through this, so the
  /// remote rewrite cannot be bypassed.
  ({SyncUriEndpoint endpoint, bool remote}) _dialTarget(String host, int port) {
    final remote = _isRemoteHost(host);
    return (
      endpoint: remote
          ? transport!.uriEndpointFor(host, port)
          : (host: host, port: port),
      remote: remote,
    );
  }

  /// The HTTP client for a peer: direct for a LAN endpoint, tunneled for a
  /// remote one. The remote factory is installed here and nowhere else, and so
  /// is the TLS layer that goes on top of it.
  ///
  /// [certificateHandler] is the certificate pin. For a LAN client it is the
  /// `HttpClient.badCertificateCallback`; for a remote one it is passed to the
  /// TLS handshake this client performs itself, because a `HttpClient` with a
  /// `connectionFactory` writes HTTP **without** wrapping the socket in TLS
  /// (dart:io treats the factory as "already the transport this scheme needs").
  /// A remote session therefore proves the peer's identity in the same
  /// handshake as a LAN one — the socket underneath is just bytes from a
  /// tunnel instead of a NIC.
  ///
  /// [expectedDeviceId] is the identity the tunneled certificate must have. The
  /// callback refuses it, and [_secureTunnelSocket] checks it again after the
  /// handshake; the LAN path keeps using the callback alone.
  HttpClient _newClient({
    required bool remote,
    required bool Function(X509Certificate certificate) certificateHandler,
    String? expectedDeviceId,
  }) {
    final client = SyncClient.directClient(identity.buildContext());
    if (!remote) {
      return client
        ..badCertificateCallback = (cert, _, _) => certificateHandler(cert);
    }
    final factory = transport!.connectionFactory;
    return client
      ..connectionFactory = (uri, proxyHost, proxyPort) async {
        final task = await _tunnelConnectionTask(
          factory,
          uri,
          proxyHost,
          proxyPort,
        );
        final secure = _secureTunnelSocket(
          task,
          certificateHandler,
          expectedDeviceId,
        );
        return ConnectionTask.fromSocket(secure, task.cancel);
      }
      ..connectionTimeout = kSyncRemoteDialConnectTimeout;
  }

  /// Dials the tunnel, translating its failures into the dial taxonomy the
  /// reachability code classifies on.
  Future<ConnectionTask<Socket>> _tunnelConnectionTask(
    Future<ConnectionTask<Socket>> Function(Uri, String?, int?) factory,
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) async {
    try {
      return await factory(uri, proxyHost, proxyPort);
    } on IOException catch (error) {
      // A tailcat dial failure is an IOException but not a SocketException,
      // while every sync dial path classifies reachability by the socket
      // type. Translating at the seam keeps the tunnel's failures in the one
      // taxonomy the callers already understand.
      throw SocketException('remote tunnel: ${redactEndpointText('$error')}');
    } on TimeoutException catch (error) {
      throw TimeoutException('remote tunnel: ${redactEndpointText('$error')}');
    }
  }

  /// Completes the TLS handshake the `HttpClient` skipped, over the tunnel's
  /// plain socket.
  ///
  /// No `host` is passed, so the name the handshake verifies is the socket's
  /// own address — the loopback relay (`127.0.0.1`), never a DNS name and never
  /// the surrogate URI host (a tailcat address), which is not in the SNI
  /// extension either.
  ///
  /// The context carries no trusted roots on purpose. A self-signed peer
  /// certificate can never validate against it, so [SecureSocket.secure] always
  /// asks [certificateHandler] and the pin is the deciding check. The default
  /// context would trust the platform store: a certificate chaining to an
  /// installed root (a corporate/MDM or user root, with an IP SAN for the
  /// loopback address) would then complete the handshake without the callback
  /// running at all. [expectedDeviceId] is checked once more after the
  /// handshake so the pin does not depend on that context choice alone.
  Future<Socket> _secureTunnelSocket(
    ConnectionTask<Socket> task,
    bool Function(X509Certificate certificate) certificateHandler,
    String? expectedDeviceId,
  ) async {
    final socket = await task.socket;
    try {
      final secure = await SecureSocket.secure(
        socket,
        context: SecurityContext(withTrustedRoots: false),
        onBadCertificate: certificateHandler,
      );
      if (expectedDeviceId != null) {
        final peer = secure.peerCertificate;
        if (peer == null ||
            crypto.sha256.convert(peer.der).toString() != expectedDeviceId) {
          throw const TlsException(
            'the tunneled peer presented a certificate that is not the pinned '
            'device',
          );
        }
      }
      return secure;
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }

  /// Pairs with a peer that is showing [pin]. Returns the peer's identity and
  /// the certificate to pin (the one this TLS session actually presented).
  ///
  /// [listenPort] is this device's own sync listener port, advertised so the
  /// responder can store a usable endpoint for the return direction.
  ///
  /// [candidateHosts] is this device's own advertised addresses: the responder
  /// remembers them beside the address this connection came from, so a peer
  /// that later roams is still reachable on a network it was never paired on.
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
    List<String> candidateHosts = const [],
  }) async {
    X509Certificate? presented;
    final target = _dialTarget(host, port);
    final client =
        _newClient(
            remote: target.remote,
            expectedDeviceId: target.remote ? expectedDeviceId : null,
            certificateHandler: (cert) {
              presented = cert;
              if (expectedDeviceId != null) {
                // Hard pin: reject inside the handshake, before any request byte.
                return crypto.sha256.convert(cert.der).toString() ==
                    expectedDeviceId;
              }
              return true; // first contact: trust happens below, bound to this cert
            },
          )
          ..connectionTimeout = target.remote
              ? kSyncRemoteDialConnectTimeout
              : kSyncDialConnectTimeout;
    try {
      final request = await client.postUrl(
        Uri.parse(
          'https://${uriHost(target.endpoint.host)}:${target.endpoint.port}/pair',
        ),
      );
      if (target.remote) {
        request.headers.set(SyncServer.remoteHeader, '1');
      }
      _writeJson(request, {
        'pin': pin,
        'deviceId': identity.deviceId,
        'deviceName': identity.name,
        'platform': _platformTag(),
        'certPem': identity.certPem,
        if (listenPort != null) 'listenPort': listenPort,
        if (candidateHosts.isNotEmpty) 'candidateHosts': candidateHosts,
      });
      final response = await request.close().timeout(kSyncPairDeadline);
      final body = await _readJson(response).timeout(kSyncPairDeadline);
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
      // Only the QR path refuses a certificate inside the callback, and such a
      // refusal must not surface as "unreachable": a `HandshakeException`
      // implements `TlsException`, **not** `SocketException`, so a caller that
      // catches the socket type alone never sees this one.
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
    Duration helloDeadline = kSyncHelloDeadline,
    Duration dataDeadline = kSyncDataDeadline,
    Duration blobDeadline = kSyncBlobDeadline,
    Duration pingDeadline = kSyncPingDeadline,
    Duration? connectTimeout,
  }) {
    final target = _dialTarget(host, port);
    return SyncClientSession(
      _httpForPeer(
        peer,
        remote: target.remote,
        // A probe-derived LAN budget (a small multiple of the measured round
        // trip) says nothing about how long a tunnel takes to come up, so a
        // remote session uses the tunnel budget whatever the caller derived.
        connectTimeout: target.remote
            ? kSyncRemoteDialConnectTimeout
            : connectTimeout,
      ),
      'https://${uriHost(target.endpoint.host)}:${target.endpoint.port}',
      deviceId: identity.deviceId,
      token: peer.secret,
      // A tunneled session is the same protocol on a slower pipe: the data and
      // blob budgets already allow for a large push, but the first control
      // beat pays for the tunnel coming up and a probe must not be fooled by
      // relay latency into reporting a present peer offline.
      helloDeadline: target.remote ? kSyncRemoteHelloDeadline : helloDeadline,
      dataDeadline: dataDeadline,
      blobDeadline: blobDeadline,
      pingDeadline: target.remote ? kSyncRemotePingDeadline : pingDeadline,
      remote: target.remote,
    );
  }

  HttpClient _httpForPeer(
    SyncPeerRecord peer, {
    Duration? connectTimeout,
    bool remote = false,
  }) {
    // Pinning the listener's certificate is the whole server-side
    // authentication: nothing else can answer as this peer. A tunneled client
    // names the expected identity so the pin is checked again after the
    // handshake, independently of which context built the TLS layer.
    final client =
        _newClient(
            remote: remote,
            expectedDeviceId: remote ? peer.deviceId : null,
            certificateHandler: (cert) =>
                crypto.sha256.convert(cert.der).toString() == peer.deviceId,
          )
          ..connectionTimeout =
              connectTimeout ??
              (remote
                  ? kSyncRemoteDialConnectTimeout
                  : kSyncDialConnectTimeout);
    return client;
  }

  /// An HTTP client for a peer, always connected **directly**. The one place
  /// that builds a client for a peer, so the rule cannot be bypassed by a second
  /// call site, and public so a test can ask what it would do — the rule itself
  /// is invisible at the call sites.
  ///
  /// Dart's default `findProxy` is `findProxyFromEnvironment`, so a proxy in the
  /// environment (a Clash/v2ray style `HTTP_PROXY`/`ALL_PROXY`, which developers
  /// and many desktop users run) swallows every dial towards a peer whose
  /// address its `NO_PROXY` does not list — and that list is usually private
  /// ranges only, while a peer is remembered at whatever address its network
  /// handed out: a NAT'd public address, or an IPv6 one. A sync peer is reached
  /// by its own address or through a tailcat tunnel (remote clients install
  /// that factory, see [_newClient]); there is no situation in which a proxy
  /// can reach a peer this device cannot.
  ///
  /// The probe is not a second exception to this rule any more: it goes through
  /// this same client (see `syncEndpointProbe`), so a proxied dial and a proxied
  /// probe agree instead of one of them reporting a peer the other can never
  /// reach. The *pairing* walk is the remaining bare-TCP one, by necessity —
  /// there is no secret to authenticate with until the PIN has been spent.
  static HttpClient directClient(SecurityContext context) =>
      HttpClient(context: context)..findProxy = (_) => 'DIRECT';

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
    final target = _dialTarget(host, port);
    final budget = target.remote
        ? kSyncRemoteDialConnectTimeout
        : _revokeTimeout;
    final client = _httpForPeer(
      peer,
      remote: target.remote,
      connectTimeout: budget,
    );
    try {
      final request = await client.postUrl(
        Uri.parse(
          'https://${uriHost(target.endpoint.host)}:'
          '${target.endpoint.port}/sync/revoke',
        ),
      );
      if (target.remote) {
        request.headers.set(SyncServer.remoteHeader, '1');
      }
      request.headers.set(SyncServer.deviceHeader, identity.deviceId);
      request.headers.set(SyncServer.tokenHeader, peer.secret);
      request.headers.contentType = ContentType.json;
      request.add(const []);
      final response = await request.close().timeout(budget);
      await response.drain<void>().timeout(budget);
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
///
/// Every request runs under a deadline. The peer is on the same LAN, so a
/// request that does not answer within one is not slow — it is gone (Wi-Fi
/// dropped, process killed). Without a deadline the caller's `await` never
/// settles: the provider's `busyDeviceIds` would stay set and automatic rounds
/// would stop for the life of the process. The deadlines are injectable so a
/// test can drive the stalled-peer paths without waiting one out.
class SyncClientSession {
  SyncClientSession(
    this._client,
    this._baseUrl, {
    required String deviceId,
    required String token,
    this.helloDeadline = kSyncHelloDeadline,
    this.dataDeadline = kSyncDataDeadline,
    this.blobDeadline = kSyncBlobDeadline,
    this.pingDeadline = kSyncPingDeadline,
    this.remote = false,
  }) : // Public names omit the private-field prefix (ChatService convention).
       // ignore: prefer_initializing_formals
       _deviceId = deviceId,
       // ignore: prefer_initializing_formals
       _token = token;

  final HttpClient _client;
  final String _baseUrl;
  final String _deviceId;
  final String _token;

  /// Budget for the control beats: the hello carries a manifest, nothing more.
  final Duration helloDeadline;

  /// Budget for a push or a fetch: rows for every conversation in play.
  final Duration dataDeadline;

  /// Budget for one blob: a file up to the import cap, or a skill's zip.
  final Duration blobDeadline;

  /// Budget for one liveness probe.
  final Duration pingDeadline;

  /// Whether this session crosses the tailcat tunnel. Every request carries
  /// the server's remote marker so a peer does not remember its relay's
  /// loopback source as this device's address (ADR-0020).
  final bool remote;

  /// One authenticated liveness probe: a request answered with a bare 204.
  ///
  /// The value is the *answer*, not the body: success means the address
  /// answered **and** the peer still recognises this device's pairing secret,
  /// which is the pair of facts a sync will need. Idempotent — the listener
  /// writes nothing — so the caller may repeat it as often as it likes, and
  /// the caller measures the elapsed time itself.
  ///
  /// A 503 (`ping_busy`) is not a verdict: the listener is saturated, so the
  /// answer says nothing about the peer. It is reported as its own code so the
  /// caller keeps whatever it already knew instead of painting the peer
  /// offline.
  Future<void> ping() async {
    final request = await _client.postUrl(
      Uri.parse('$_baseUrl${SyncServer.pingPath}'),
    );
    _authenticate(request);
    request.contentLength = 0;
    final response = await request.close().timeout(pingDeadline);
    await response.drain<void>().timeout(pingDeadline);
    switch (response.statusCode) {
      case HttpStatus.noContent:
        return;
      case HttpStatus.serviceUnavailable:
        throw SyncClientException(
          'ping_busy',
          statusCode: HttpStatus.serviceUnavailable,
        );
      case HttpStatus.unauthorized:
        // This device's pairing is gone over there; the peer answered, which
        // is still an answer.
        throw SyncClientException(
          'not_paired',
          statusCode: HttpStatus.unauthorized,
        );
      default:
        throw SyncClientException(
          'ping_failed',
          statusCode: response.statusCode,
        );
    }
  }

  Future<SyncHelloOutcome> hello(SyncHello mine) async {
    final response = await _post(
      '/sync/hello',
      mine.toJson(),
    ).timeout(helloDeadline);
    final body = await SyncClient._readJson(response).timeout(helloDeadline);
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
    final response = await _post(
      '/sync/subtrees',
      request.toJson(),
    ).timeout(dataDeadline);
    final body = await SyncClient._readJson(response).timeout(dataDeadline);
    if (response.statusCode != HttpStatus.ok || body == null) {
      throw SyncClientException(
        (body?['error'] ?? 'fetch_failed').toString(),
        statusCode: response.statusCode,
      );
    }
    return SyncDeltaBatch.fromJson(body);
  }

  /// Sends this device's changed conversation subtrees and business rows.
  /// The answer is an acknowledgement, not a receipt: the responder reports
  /// what it deferred, and only confirmed state may advance the checkpoint.
  Future<SyncApplyAck> pushDelta(SyncDeltaBatch batch) async {
    final response = await _put(
      '/sync/subtrees',
      batch.toJson(),
    ).timeout(dataDeadline);
    final body = await SyncClient._readJson(response).timeout(dataDeadline);
    if (response.statusCode != HttpStatus.ok || body == null) {
      throw SyncClientException(
        (body?['error'] ?? 'push_failed').toString(),
        statusCode: response.statusCode,
      );
    }
    return SyncApplyAck.fromJson(body);
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
    final response = await request.close().timeout(blobDeadline);
    if (response.statusCode != HttpStatus.ok) {
      // Drain so the connection can be reused/closed cleanly — bounded, because
      // a body that never ends is the same stalled peer one step later.
      await response.drain<void>().timeout(blobDeadline);
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
      // A stream that goes silent is the stalled-peer case: inactivity, not
      // total size, is what a blob transfer must not wait out forever.
      await for (final chunk in response.timeout(blobDeadline)) {
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

  /// Streams one workspace file into [destination] (slice 18).
  ///
  /// [workspaceId] and [relPath] name a file the peer advertised in its table
  /// for this session; anything else is refused there. There is no content hash
  /// to verify against — a workspace file's identity is its size and mtime, and
  /// the caller checks the size after landing (a truncated body throws here,
  /// because the response carries its length).
  Future<int> fetchWorkspaceFile({
    required String workspaceId,
    required String relPath,
    required File destination,
  }) async {
    final request = await _client.postUrl(
      Uri.parse('$_baseUrl${SyncServer.workspaceFilePath}'),
    );
    _authenticate(request);
    SyncClient._writeJson(request, {'ws': workspaceId, 'path': relPath});
    final response = await request.close().timeout(blobDeadline);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>().timeout(blobDeadline);
      throw SyncClientException(
        'workspace_file_unavailable',
        statusCode: response.statusCode,
      );
    }
    var received = 0;
    final sink = destination.openWrite();
    try {
      // Inactivity, not total size, is what a transfer must not wait out
      // forever: a stalled stream is a peer that went away mid-file.
      await for (final chunk in response.timeout(blobDeadline)) {
        received += chunk.length;
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
    } catch (_) {
      await sink.close();
      await _deleteQuietly(destination);
      rethrow;
    }
    return received;
  }

  /// One pushed transfer, from its first byte to its last drain, under **one**
  /// budget.
  ///
  /// `addStream` used to sit outside every timer: a peer that stopped reading a
  /// 200 MB upload left this `await` pending forever, and the session's own
  /// `busyDeviceIds` with it. A per-await `.timeout` is not the fix either — the
  /// budget belongs to the transfer, so a peer that reads a byte a minute is as
  /// gone as one that reads nothing.
  ///
  /// The request is *aborted* when the budget runs out, whichever way it ran
  /// out. `.timeout` alone only stops waiting: the socket stays open, the peer
  /// keeps the connection, and this session's next request queues behind it.
  /// The budget can also be found already spent by the *next* `left()` — an
  /// await can complete in the same turn its timer would have fired — so both
  /// ways out abort.
  ///
  /// [body] receives the remaining budget as a function rather than a duration,
  /// so each await inside it spends what is actually left.
  Future<void> _transfer(
    HttpClientRequest request,
    Duration budget,
    Future<void> Function(Duration Function() left) body,
  ) async {
    final watch = Stopwatch()..start();
    Duration left() {
      final remaining = budget - watch.elapsed;
      if (remaining <= Duration.zero) throw const _TransferBudgetSpent();
      return remaining;
    }

    try {
      await body(left);
    } on TimeoutException {
      request.abort(TimeoutException('transfer_timeout', budget));
      throw const SyncClientException('transfer_timeout');
    } on _TransferBudgetSpent {
      request.abort(const SyncClientException('transfer_timeout'));
      throw const SyncClientException('transfer_timeout');
    } finally {
      watch.stop();
    }
  }

  /// Pushes one workspace file the peer asked for (slice 23).
  ///
  /// The pair travels base64url in headers and the bytes are the raw body with a
  /// declared length, which is what the receiver checks the file against. No
  /// content hash is involved for the same reason a fetched file has none: a
  /// workspace file's identity is its size and mtime, and the mtime travels
  /// beside the bytes so the receiver can stamp what it lands.
  Future<void> pushWorkspaceFile({
    required String workspaceId,
    required String relPath,
    required File source,
    required WorkspaceFileStamp advertised,
  }) async {
    final request = await _client.putUrl(
      Uri.parse('$_baseUrl${SyncServer.workspaceFilePath}'),
    );
    _authenticate(request);
    request.headers.set(
      SyncServer.workspaceIdHeader,
      base64Url.encode(utf8.encode(workspaceId)),
    );
    request.headers.set(
      SyncServer.workspaceRelPathHeader,
      base64Url.encode(utf8.encode(relPath)),
    );
    request.headers.contentType = ContentType.binary;
    request.headers.contentLength = advertised.size;
    await _transfer(request, blobDeadline, (left) async {
      // `left()` is taken *before* the future it bounds, every time. `f.timeout(g())`
      // evaluates `f` first, so asking for the budget in the argument position
      // creates the request body — or the close future — with nobody to listen
      // to it: the budget then throws, `_transfer` aborts, and the abort
      // completes an unlistened future, which reports to the zone instead of to
      // the caller.
      final sendWait = left();
      await request.addStream(source.openRead()).timeout(sendWait);
      final closeWait = left();
      final response = await request.close().timeout(closeWait);
      if (response.statusCode != HttpStatus.noContent) {
        // The refusal *is* the answer, so a body that then stalls — or a
        // connection the peer tears down under it — must not turn it into a
        // generic transport error: the socket is aborted and the peer's status
        // is what the caller hears.
        try {
          final refuseWait = left();
          await response.drain<void>().timeout(refuseWait);
        } catch (_) {
          request.abort(const SyncClientException('transfer_timeout'));
        }
        throw SyncClientException(
          'workspace_push_refused',
          statusCode: response.statusCode,
        );
      }
      final drainWait = left();
      await response.drain<void>().timeout(drainWait);
    });
  }

  /// Pushes one blob the peer asked for (slice 24).
  ///
  /// The hash is the route's subject and the entry's kind and key travel in
  /// headers, so the receiver matches the push to the exact entry it asked
  /// about. [size] is declared as the body's length, which is what a file blob
  /// is checked against; the bytes are the file's own, streamed rather than
  /// buffered.
  Future<void> pushBlob({
    required SyncBlobEntry entry,
    required File source,
    required int size,
  }) async {
    final request = await _client.putUrl(
      Uri.parse('$_baseUrl${SyncServer.blobPathPrefix}${entry.contentHash}'),
    );
    _authenticate(request);
    request.headers.set(SyncServer.blobKindHeader, entry.kind);
    request.headers.set(
      SyncServer.blobKeyHeader,
      base64Url.encode(utf8.encode(entry.key)),
    );
    request.headers.contentType = ContentType.binary;
    request.headers.contentLength = size;
    await _transfer(request, blobDeadline, (left) async {
      // Same rule as the workspace push: the budget is read before the future it
      // bounds, so a spent one starts no body and leaves no unlistened future.
      final sendWait = left();
      await request.addStream(source.openRead()).timeout(sendWait);
      final closeWait = left();
      final response = await request.close().timeout(closeWait);
      if (response.statusCode != HttpStatus.noContent) {
        try {
          final refuseWait = left();
          await response.drain<void>().timeout(refuseWait);
        } catch (_) {
          request.abort(const SyncClientException('transfer_timeout'));
        }
        throw SyncClientException(
          'blob_push_refused',
          statusCode: response.statusCode,
        );
      }
      final drainWait = left();
      await response.drain<void>().timeout(drainWait);
    });
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
    if (remote) request.headers.set(SyncServer.remoteHeader, '1');
  }
}
