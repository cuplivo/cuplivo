import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart' as crypto;

import 'sync_admission.dart';
import 'sync_identity.dart';
import 'sync_limits.dart';
import 'sync_local_addresses.dart';
import 'sync_models.dart';
import 'sync_store.dart';
import 'sync_transport.dart';

/// Handler surface the sync engine implements behind [SyncServer]. The server
/// is transport only: mTLS, routing, JSON/gzip codecs, certificate pinning.
///
/// Every method takes the request's [SyncAdmission]. It is the only way the
/// handler can know that the deadline already took this request: the transport
/// answers 504 at the deadline, and a handler that has not been told would keep
/// writing after its peer was told the request is over. A handler must call
/// `check()` at each commit point (before installing a session, writing a
/// checkpoint, landing a file — never inside a transaction) and must run every
/// await that can hang through `io()`/`ioStream()`.
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
    required SyncAdmission admission,
  });

  /// Everything this device owes the initiator for the request's conversations
  /// and business rows.
  Future<SyncDeltaBatch> handleFetchSubtrees(
    String peerDeviceId,
    SyncFetchRequest request, {
    required SyncAdmission admission,
  });

  /// Applies what the initiator sent (conversation subtrees + business rows).
  /// Returns the acknowledgement the initiator's checkpoint advance needs:
  /// what was applied, what was deferred, and whether the business apply was
  /// deferred as a whole.
  Future<SyncApplyAck> handleApplySubtrees(
    String peerDeviceId,
    SyncDeltaBatch batch, {
    required SyncAdmission admission,
  });

  /// The local file backing one blob this device published, or null when the
  /// hash is unknown here (or the file is gone). The server only ever streams
  /// a file the handler names — a request never supplies a path.
  Future<File?> handleFetchBlob(
    String peerDeviceId,
    String contentHash, {
    required SyncAdmission admission,
  });

  /// The local file backing one `(workspace, path)` this device advertised in
  /// its file table for that peer, or null when it did not advertise it — or
  /// advertised a version the file is no longer.
  ///
  /// Same rule as [handleFetchBlob]: the request names something, it never
  /// supplies a path. The handler resolves the pair through the set it walked
  /// and published itself, so a crafted path cannot reach a file outside the
  /// workspace (slice 18).
  Future<File?> handleFetchWorkspaceFile(
    String peerDeviceId,
    String workspaceId,
    String relPath, {
    required SyncAdmission admission,
  });

  /// Receives one workspace file this device asked the caller to push, as the
  /// raw request body (slice 23).
  ///
  /// [size] is the body's declared length and [mtimeMs] the advertised
  /// version's stamp. The handler accepts the pair only when this session asked
  /// for exactly that version — the request set the push beat built is the
  /// write authorization, and it can only name files the caller itself
  /// advertised. Returns whether the file landed.
  ///
  /// A refusal reads the body out to [size] before answering instead of
  /// closing on the peer mid-write: the peer has spent the send either way, and
  /// what it gets back is a status it can log rather than a connection reset.
  Future<bool> handlePutWorkspaceFile(
    String peerDeviceId,
    String workspaceId,
    String relPath, {
    required int size,
    required Stream<List<int>> body,
    required SyncAdmission admission,
  });

  /// Receives one blob this device asked the caller to push, as the raw request
  /// body (slice 24).
  ///
  /// [contentHash] is the route's own hash — the one this device asked for —
  /// and [kind] plus [key] name the entry it asked about, so the handler can
  /// find that exact request and refuse anything else. [size] is the body's
  /// declared length, which is what a file blob is checked against; a skill's
  /// zip has no length agreed in advance.
  ///
  /// Same rule as [handlePutWorkspaceFile]: the request set the push beat built
  /// is the write authorization. Returns whether the blob landed.
  Future<bool> handlePutBlob(
    String peerDeviceId,
    String contentHash, {
    required String kind,
    required String key,
    required int size,
    required Stream<List<int>> body,
    required SyncAdmission admission,
  });

  /// Pairing: validate the PIN, persist the peer, answer with our identity.
  /// Returns null when the PIN is wrong or pairing is not open.
  ///
  /// [initiatorHost] is the address the initiator connected from (as this
  /// server saw it) and [request.listenPort] the initiator's own sync
  /// listener — together they let the responder store a usable endpoint.
  ///
  /// This route writes a peer record and a secret, so its admission matters more
  /// than most: a pairing abandoned at the deadline must not install the peer,
  /// because the peer never receives the answer and would hold a pairing this
  /// device granted but it cannot prove.
  Future<SyncPairAnswer?> handlePair(
    SyncPairRequest request,
    String? initiatorHost, {
    required SyncAdmission admission,
  });

  /// Unpair propagation (slice 5): a paired peer presented its secret and
  /// asks this device to forget it. The handler drops the caller's peer
  /// record; only the caller's — the secret authenticates exactly that
  /// identity.
  Future<void> handleRevoke(
    String peerDeviceId, {
    required SyncAdmission admission,
  });
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

  /// The initiator's own candidate addresses, so the responder remembers more
  /// than the one address this connection came from: a device that roams would
  /// otherwise be reachable only at the network it paired on. Additive and
  /// optional — a peer that does not send it pairs exactly as it did before.
  final List<String> candidateHosts;

  const SyncPairRequest({
    required this.pin,
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.certPem,
    this.listenPort,
    this.candidateHosts = const [],
  });

  static SyncPairRequest fromJson(Map<String, dynamic> json) => SyncPairRequest(
    pin: json['pin'] as String,
    deviceId: json['deviceId'] as String,
    deviceName: (json['deviceName'] as String?) ?? '',
    platform: (json['platform'] as String?) ?? '',
    certPem: json['certPem'] as String,
    listenPort: (json['listenPort'] as num?)?.toInt(),
    candidateHosts: [
      for (final host in (json['candidateHosts'] as List?) ?? const [])
        if (host is String && host.isNotEmpty) host,
    ],
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

/// The lanes a request can be served on, decided by `SyncServer._laneOf`.
enum _Lane { ping, pair, read, write }

/// Every route this listener serves. One row per route in [_classify], and the
/// subject of [_route]'s exhaustive switch: adding a route is adding an arm
/// there, and that arm cannot compile without a lane here.
enum _Route { ping, pair, hello, subtrees, revoke, workspaceFile, blob }

/// HTTPS server for sync.
///
/// One listener serves both pairing and sync routes, authenticated in two
/// layers (a remote session's bytes arrive through the tailcat relay and are
/// handed to this same listener — ADR-0020):
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
    Duration Function(String path)? deadlineFor,
  }) : _deadlineForOverride = deadlineFor;

  final SyncDeviceIdentity identity;
  final SyncStore store;
  final SyncServerHandler handler;

  /// Test seam for the route budgets: a test that proves the recovery from a
  /// stalled request must not wait a real one out. Production leaves it null
  /// and gets [_defaultDeadlineFor].
  final Duration Function(String path)? _deadlineForOverride;

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

  /// Set by a remote session's client on every request (ADR-0020).
  ///
  /// A remote connection arrives through this device's own tailcat relay, so
  /// its socket comes from loopback — not from where the peer is. Without the
  /// marker the engine would remember `127.0.0.1` as the peer's LAN endpoint
  /// and dial it back on the next session. The marker is not authentication:
  /// it only suppresses an address guess, and a peer that sends it merely
  /// loses the source-address hint.
  static const String remoteHeader = 'x-cuplivo-remote';

  void rememberPeer(SyncPeerRecord peer) {
    _peerSecrets[peer.deviceId] = peer.secret;
  }

  void forgetPeer(String deviceId) {
    _peerSecrets.remove(deviceId);
  }

  /// The IPv6 any-address, which a dual-stack stack also accepts IPv4 callers
  /// on (they arrive mapped, see [_remoteHost]).
  static const anyIpv6 = '::';

  /// The IPv4 any-address this listener used before it went dual-stack, kept as
  /// the fallback for a machine where the IPv6 bind cannot succeed.
  static const anyIpv4 = '0.0.0.0';

  Future<int> start({String address = anyIpv6, int requestedPort = 0}) async {
    await stop();
    _peerSecrets
      ..clear()
      ..addEntries(
        (await store.listPeers()).map(
          (peer) => MapEntry(peer.deviceId, peer.secret),
        ),
      );
    final server = await _bind(address, requestedPort);
    _server = server;
    unawaited(_serve(server));
    return server.port;
  }

  /// Binds [address], falling back to IPv4 when the IPv6 any-address is
  /// refused.
  ///
  /// `::` is the dual-stack bind: measured on Windows, a listener on it accepts
  /// IPv4 callers as well (they appear as `::ffff:a.b.c.d`), and the test suite
  /// dials IPv4 loopback against an `::` listener on every platform it runs on.
  /// A machine with IPv6 disabled refuses the bind, and that refusal is what the
  /// fallback is for: the IPv4 any-address is exactly what this listener was
  /// before, so no configuration ends up worse off than the previous release.
  ///
  /// Known limit: a host configured with `bindv6only=1` (a Linux sysctl)
  /// *accepts* the `::` bind and then serves IPv6 only — nothing here notices,
  /// and IPv4 peers cannot reach this device. Detecting it needs a self-connect
  /// probe against the bound port, which is an untestable branch on every
  /// machine without that sysctl; the default is dual-stack on each platform
  /// this app ships to, so the limit is written down rather than worked around.
  ///
  /// A port already in use fails both attempts; the original error is rethrown
  /// then, and the caller's ephemeral-port fallback handles it either way.
  Future<HttpServer> _bind(String address, int port) async {
    try {
      return await HttpServer.bindSecure(
        address,
        port,
        identity.buildContext(),
        // Never request a client certificate: see the class comment. Peers are
        // authenticated per request by their pairing-established secret.
        requestClientCertificate: false,
      );
    } on SocketException catch (error) {
      if (address != anyIpv6) rethrow;
      try {
        return await HttpServer.bindSecure(
          anyIpv4,
          port,
          identity.buildContext(),
          requestClientCertificate: false,
        );
      } on SocketException {
        throw error;
      }
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server != null) await server.close(force: true);
  }

  Future<void> _serve(HttpServer server) async {
    // The *loop* must not block waiting for a request: a data beat can run for
    // twenty minutes, and a request the loop never reads is a request nothing
    // can answer. Each request is handed to a lane straight from the loop, and
    // its budget starts here — at the instant the listener read it — so the time
    // it spends queued is time it has spent.
    //
    // Authentication is decided here too, once, before any lane: a `/sync/*`
    // request that cannot name a paired caller is answered 401 without ever
    // occupying a place in a queue. Answering it on the write lane — which is
    // where an unauthenticated `POST /sync/hello` used to be refused — let a
    // stranger's flood of forged requests queue in front of a paired peer's.
    var writeTail = Future<void>.value();
    await for (final request in server) {
      final admission = SyncAdmission(budget: _deadlineFor(request.uri.path));
      final lane = _laneOf(request);
      if (lane == _Lane.pair) {
        // Unauthenticated by nature — a pairing has no secret yet — so it
        // answers on a lane of its own, capped: a stranger who fills it gets a
        // 503 that says so, and the data routes keep running beside it. What the
        // cap does *not* do is spare this device's own pairing — in the responder
        // role that request is the fifth one, and it is refused too. The refusal
        // is why it is worth retrying rather than queueing, and why the client
        // renders `pair_busy` as "busy, try again" instead of an unreachable
        // address.
        unawaited(_servePair(request, admission));
        continue;
      }
      final peer = request.uri.path.startsWith('/sync/')
          ? _authenticatedPeer(request)
          : null;
      if (peer == null && request.uri.path.startsWith('/sync/')) {
        _safeRespond(request, HttpStatus.unauthorized, {
          'error': SyncRefusalReason.notPaired.wire,
        });
        continue;
      }
      if (lane == _Lane.ping) {
        // Idempotent, no session state, bounded concurrency: safe beside the
        // lanes. A probe queued behind a running session would report the peer
        // offline for the whole session, every tick, for every peer.
        unawaited(_servePing(request, peer!));
        continue;
      }
      if (lane == _Lane.read) {
        // A read serves what a running write *published*, never what it is in
        // the middle of building, so it needs no place in the write order. This
        // is what a peer's blob pull rides on: a session's push beat pulls
        // attachments from the other side, and that pull used to queue behind
        // this device's own inbound session — three devices then waited on each
        // other in a ring.
        unawaited(_serveOne(request, peer, admission));
      } else {
        writeTail = writeTail.then((_) => _serveOne(request, peer, admission));
      }
    }
    await writeTail;
  }

  /// How many `/pair` requests this listener answers at once.
  int _pairsInFlight = 0;

  /// One pairing request, on the capped pairing lane.
  ///
  /// Past the cap the caller is answered 503 `pair_busy`: a refusal it can act
  /// on ("try again", or the other device is busy), not a place in a queue it
  /// cannot see. The refusal is the same shape `ping_busy` has, because it says
  /// the same thing — the listener is loaded, not that the peer is wrong.
  Future<void> _servePair(HttpRequest request, SyncAdmission admission) async {
    if (_pairsInFlight >= kMaxPairRequestsInFlight) {
      _safeRespond(request, HttpStatus.serviceUnavailable, {
        'error': 'pair_busy',
      });
      return;
    }
    _pairsInFlight++;
    try {
      await _serveOne(request, null, admission);
    } finally {
      _pairsInFlight--;
    }
  }

  /// Which lane one request belongs to: **by effect, not by path**.
  ///
  /// Reads the same table [_route] dispatches from, so a route is classified
  /// exactly once — the lane and the handler are two answers about one row.
  _Lane _laneOf(HttpRequest request) =>
      _classify(request.method, request.uri.path)?.$2 ?? _Lane.read;

  /// Every route this listener serves: which one it is, and which lane it takes.
  ///
  /// One table, read by [_laneOf] and by [_route]. It used to be two — a
  /// `_writesState` that answered read/write and a `switch` that answered
  /// "which handler" — and the gap between them was **fail-open**: a mutating
  /// route added to the dispatch and forgotten in `_writesState` ran on the
  /// concurrent read lane, beside a write beat, with nothing failing loudly. The
  /// enum is what closes it: the dispatch is an exhaustive `switch` over it, so
  /// a route cannot be served without a row here, and a row cannot exist without
  /// a lane.
  ///
  /// Classification is by *effect*, not by path: `POST /sync/wsfile` streams a
  /// file this device advertised (a read) while `PUT` on the same path lands one
  /// (a write), and `GET /sync/hello` writes nothing even though every `POST`
  /// there installs a session. A method a route does not serve still gets a row
  /// — on the read lane, where it answers its 405 — so a wrong method can never
  /// queue on the lane it would have taken.
  ///
  /// What the read lane's concurrency rests on, and both facts predate it:
  /// a read resolves against state that is *swapped whole* when it changes
  /// (`WorkspaceContentSync.publish` builds a new table and assigns it), and no
  /// write runs a network await inside a database transaction (`_fetchOne` is
  /// network, then file, then DB) — so a read waiting on the database waits for
  /// one transaction, not for a transfer.
  static (_Route, _Lane)? _classify(String method, String path) {
    if (path == pingPath) return (_Route.ping, _Lane.ping);
    if (path == '/pair') return const (_Route.pair, _Lane.pair);
    if (path == '/sync/hello') {
      return (_Route.hello, method == 'POST' ? _Lane.write : _Lane.read);
    }
    if (path == '/sync/subtrees') {
      final writes = method == 'POST' || method == 'PUT';
      return (_Route.subtrees, writes ? _Lane.write : _Lane.read);
    }
    if (path == '/sync/revoke') {
      return (_Route.revoke, method == 'POST' ? _Lane.write : _Lane.read);
    }
    if (path == workspaceFilePath) {
      return (_Route.workspaceFile, method == 'PUT' ? _Lane.write : _Lane.read);
    }
    if (path.startsWith(blobPathPrefix)) {
      return (_Route.blob, method == 'PUT' ? _Lane.write : _Lane.read);
    }
    // Served by nothing: it answers its 404 beside the lanes.
    return null;
  }

  /// One request, on whichever lane the loop put it, bounded by its budget.
  ///
  /// The deadline is spent through [SyncAdmission], not through a bare
  /// `.timeout()`: it must both end the wait here *and* take the handler's right
  /// to write, because a `.timeout()` alone leaves the abandoned handler running
  /// — writing a checkpoint, installing a session — after the peer has been told
  /// the request is over. The budget is what is *left* of the request's, so a
  /// request that queued behind a long beat starts already spent.
  ///
  /// A request whose budget ran out while it waited is answered 504 without
  /// reaching its handler. This method never throws — the write lane is a future
  /// chain, and one uncaught error would break every request queued behind it.
  Future<void> _serveOne(
    HttpRequest request,
    String? peerDeviceId,
    SyncAdmission admission,
  ) async {
    try {
      admission.check();
      await admission.io(() => _route(request, peerDeviceId, admission));
    } on SyncAdmissionLost {
      _safeRespond(request, HttpStatus.gatewayTimeout, {'error': 'timeout'});
    } on _RequestBodyTooLarge {
      _safeRespond(request, HttpStatus.requestEntityTooLarge, {
        'error': 'body_too_large',
      });
    } on SyncRequestRefusal catch (refusal) {
      // A request the handler refused before touching any state, with the status
      // that says *why*: a beat that belongs to no live session is a 409 the
      // caller can act on, where the 500 every other failure produced named an
      // exception the peer has no use for.
      _safeRespond(request, refusal.statusCode, {'error': refusal.error});
    } catch (error, stack) {
      // A handler exception can name the request URL, and a sync URL carries
      // the peer's tailcat address when the request came through a tunnel.
      // Scrub the capability before it reaches either the response or the log.
      final reason = redactEndpointText('$error');
      _safeRespond(request, HttpStatus.internalServerError, {'error': reason});
      // ignore: avoid_print
      print('sync server: $reason\n$stack');
    }
  }

  /// Answers one liveness probe beside the request lanes.
  ///
  /// Idempotent by construction: no body, no session lookup, no write. The
  /// answer is the point — an authenticated status line proves both halves a
  /// sync needs (the address answers *and* this device's secret is still good),
  /// which a bare TCP connect cannot say. The caller measures the latency
  /// itself, so the response carries nothing.
  ///
  /// [peerDeviceId] is the caller's authenticated identity, decided once at the
  /// loop before this is dispatched: an unauthenticated probe is answered 401
  /// there, so it never takes one of the lane's slots.
  Future<void> _servePing(HttpRequest request, String peerDeviceId) async {
    if (_pingsInFlight >= kMaxPingsInFlight) {
      _safeRespond(request, HttpStatus.serviceUnavailable, {
        'error': 'ping_busy',
      });
      return;
    }
    _pingsInFlight++;
    try {
      if (request.method != 'POST') {
        _safeRespond(request, HttpStatus.methodNotAllowed, {
          'error': 'post_only',
        });
        return;
      }
      // Drained and ignored: an empty body is the contract, and a caller that
      // sent one must not be left with a half-read request.
      await request.drain<void>().timeout(_pingDeadline);
      await _respondNoContent(request, HttpStatus.noContent);
    } catch (_) {
      // A probe's caller is the one that classifies a failed answer; there is
      // nothing to salvage on this side. What must *not* happen is closing a
      // response that was never given a status: HTTP then sends 200 OK, and the
      // caller reads a stalled body as "the peer answered in 5 s", which is the
      // one thing a liveness probe must never invent. The deadline is named
      // instead, so the caller sees a slow address as a slow address.
      try {
        await _respondNoContent(request, HttpStatus.requestTimeout);
      } catch (_) {}
    } finally {
      _pingsInFlight--;
    }
  }

  /// Probes in flight. Bounded so a peer (or a bug) cannot open thousands of
  /// connections: the probe path answers 503 past the cap, which the caller
  /// reads as "not now" instead of queueing it behind the session it is
  /// supposed to outlive. The ceiling itself lives in `sync_limits.dart`,
  /// derived from the endpoint cap — see the note there on why the two bounds
  /// have to move together.
  int _pingsInFlight = 0;

  /// Path of the liveness probe. Authenticated like every other `/sync/*`
  /// route, so a success is reachability *and* pairing, in one round trip.
  static const String pingPath = '/sync/ping';

  /// A route's total budget. These are backstops against a peer that stops
  /// answering, not performance targets: the data routes are sized for a large
  /// push and the reverse blob pulls the responder performs inside it.
  static const _pairDeadline = Duration(seconds: 60);
  static const _helloDeadline = Duration(seconds: 60);
  static const _revokeDeadline = Duration(seconds: 30);
  static const _dataDeadline = Duration(minutes: 30);

  /// A probe that has not answered in seconds is not slow, it is gone; it runs
  /// on its own fast lane, so this deadline only bounds how long one of them
  /// may hold a connection slot.
  static const Duration _pingDeadline = Duration(seconds: 5);

  Duration _deadlineFor(String path) =>
      _deadlineForOverride?.call(path) ?? _defaultDeadlineFor(path);

  static Duration _defaultDeadlineFor(String path) => switch (path) {
    '/pair' => _pairDeadline,
    '/sync/hello' => _helloDeadline,
    '/sync/revoke' => _revokeDeadline,
    pingPath => _pingDeadline,
    _ => _dataDeadline,
  };

  /// Routes one already-authenticated request, over the same table that chose
  /// its lane.
  ///
  /// [peerDeviceId] is null only for `/pair`, the one route that answers before
  /// any authentication exists. The authentication decision itself is made once,
  /// at the loop (see [_serve]) — not here as well.
  Future<void> _route(
    HttpRequest request,
    String? peerDeviceId,
    SyncAdmission admission,
  ) async {
    final match = _classify(request.method, request.uri.path);
    if (match == null) {
      _safeRespond(request, HttpStatus.notFound, {'error': 'not_found'});
      return;
    }
    final route = match.$1;
    if (route == _Route.pair) {
      await _handlePair(request, admission);
      return;
    }
    final peer = peerDeviceId;
    if (peer == null) {
      _safeRespond(request, HttpStatus.notFound, {'error': 'not_found'});
      return;
    }
    switch (route) {
      case _Route.ping:
        // Answered at the loop, on its own lane: it never reaches this method,
        // and the arm is here so the switch stays exhaustive over the table.
        _safeRespond(request, HttpStatus.notFound, {'error': 'not_found'});
      case _Route.pair:
        // Handled above, before the peer is needed: pairing has no secret yet.
        _safeRespond(request, HttpStatus.notFound, {'error': 'not_found'});
      case _Route.hello:
        await _handleHello(request, peer, admission);
      case _Route.subtrees:
        await _handleSubtrees(request, peer, admission);
      case _Route.revoke:
        await _handleRevoke(request, peer, admission);
      case _Route.workspaceFile:
        await _handleWorkspaceFile(request, peer, admission);
      case _Route.blob:
        await _handleBlob(request, peer, admission);
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

  /// The workspace file route: one advertised `(workspace, relative path)` per
  /// request, streamed back as bytes. A POST rather than a GET because the
  /// request has a body (the pair) and a path that must not be squeezed into a
  /// URL: workspace paths hold spaces, `#`, `%` and non-ASCII, and every one of
  /// them would be an encoding question on one side and a decoding bug on the
  /// other.
  static const String workspaceFilePath = '/sync/wsfile';

  /// The push direction of the same route (slice 23): the initiator streams the
  /// bytes of one file this device asked for. The pair travels base64url in
  /// headers — a workspace path holds spaces, `#`, `%` and non-ASCII, and base64
  /// is the one form that needs no encoding decision on either side — and the
  /// body is the raw file, so a large one streams through instead of being
  /// buffered as JSON.
  static const String workspaceIdHeader = 'x-sync-workspace';
  static const String workspaceRelPathHeader = 'x-sync-path';

  /// The push direction of the blob route (slice 24). The hash travels in the
  /// path — it is the request's whole subject — and the entry's kind and key
  /// travel beside it, because the receiver has to find *the entry it asked
  /// about* rather than guess which target a hash belongs to when the same
  /// content sits under two names. The key is base64url for the same reason a
  /// workspace path is: it is a URI, and a header has no place to put an
  /// encoding question.
  static const String blobKindHeader = 'x-sync-blob-kind';
  static const String blobKeyHeader = 'x-sync-blob-key';

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

  /// The caller's address, in the canonical form the engine stores.
  ///
  /// On a dual-stack listener an IPv4 caller arrives as `::ffff:a.b.c.d`, and
  /// that mapped form is a valid address to a socket but not to a URI or to a
  /// human: stored as-is it would become an endpoint that cannot be dialed
  /// back and would double every IPv4 peer under two names.
  String? _remoteHost(HttpRequest request) {
    // A relayed connection's source is this device's own loopback, so the
    // address says nothing about the peer: report "no source hint" instead,
    // and let the peer's advertised candidates (its tailcat host among them)
    // carry the return direction.
    if (request.headers.value(remoteHeader) == '1') return null;
    final address = request.connectionInfo?.remoteAddress.address;
    return address == null ? null : normalizeHost(address);
  }

  Future<void> _handlePair(HttpRequest request, SyncAdmission admission) async {
    if (request.method != 'POST') {
      _safeRespond(request, HttpStatus.methodNotAllowed, {
        'error': 'post_only',
      });
      return;
    }
    // /pair is the one route that answers before any authentication, so its
    // body is the only unauthenticated input this listener ever folds into
    // memory: a pairing request is a certificate plus metadata (a few KB), and
    // anything past the cap is answered, not buffered.
    final Map<String, dynamic>? body;
    try {
      body = await _readJson(request, admission, maxBytes: _pairMaxBodyBytes);
    } on _RequestBodyTooLarge {
      _safeRespond(request, HttpStatus.requestEntityTooLarge, {
        'error': 'body_too_large',
      });
      return;
    }
    if (body == null) {
      _safeRespond(request, HttpStatus.badRequest, {'error': 'bad_json'});
      return;
    }
    final SyncPairRequest pairRequest;
    try {
      pairRequest = SyncPairRequest.fromJson(body);
    } catch (_) {
      // Malformed but authenticated-shape JSON: a 4xx answer, not a 500 with
      // the server's stack trace in the log.
      _safeRespond(request, HttpStatus.badRequest, {'error': 'bad_request'});
      return;
    }
    // The claimed deviceId must hash to the certificate the caller sent: a
    // passive relay cannot forge that binding. (A full MITM that terminates
    // both legs remains possible in the PIN path; the QR fingerprint path
    // added later closes it.)
    final String presentedId;
    try {
      presentedId = crypto.sha256
          .convert(CryptoUtils.getBytesFromPEMString(pairRequest.certPem))
          .toString();
    } catch (_) {
      // An unparseable certificate is a client error, not a 500.
      _safeRespond(request, HttpStatus.badRequest, {'error': 'bad_cert'});
      return;
    }
    if (presentedId != pairRequest.deviceId) {
      _safeRespond(request, HttpStatus.forbidden, {'error': 'id_mismatch'});
      return;
    }
    final answer = await handler.handlePair(
      pairRequest,
      _remoteHost(request),
      admission: admission,
    );
    if (answer == null) {
      _safeRespond(request, HttpStatus.forbidden, {'error': 'invalid_pin'});
      return;
    }
    _respondJson(request, HttpStatus.ok, answer.toJson());
  }

  Future<void> _handleHello(
    HttpRequest request,
    String peerDeviceId,
    SyncAdmission admission,
  ) async {
    if (request.method != 'POST') {
      _safeRespond(request, HttpStatus.methodNotAllowed, {
        'error': 'post_only',
      });
      return;
    }
    final body = await _readJson(
      request,
      admission,
      maxBytes: kSyncMaxBodyBytes,
    );
    if (body == null) {
      _safeRespond(request, HttpStatus.badRequest, {'error': 'bad_json'});
      return;
    }
    final result = await handler.handleHello(
      peerDeviceId,
      SyncHello.fromJson(body),
      remoteAddress: _remoteHost(request),
      admission: admission,
    );
    if (result is SyncHelloRefusal) {
      _respondJson(request, HttpStatus.conflict, result.toJson());
      return;
    }
    _respondJson(request, HttpStatus.ok, (result as SyncHello).toJson());
  }

  /// One blob, in either direction.
  ///
  /// `GET` streams the content this device published for the hash. `PUT` is the
  /// other direction (slice 24): the initiator pushing a blob this device asked
  /// for because it could not fetch it. The handler resolves which local file
  /// (if any) backs a served hash, and a peer-supplied file entry is only ever
  /// remembered for a managed blob root, so a request can never read an
  /// arbitrary path off this device.
  Future<void> _handleBlob(
    HttpRequest request,
    String peerDeviceId,
    SyncAdmission admission,
  ) async {
    if (request.method == 'PUT') {
      await _receiveBlob(request, peerDeviceId, admission);
      return;
    }
    if (request.method != 'GET') {
      _safeRespond(request, HttpStatus.methodNotAllowed, {
        'error': 'get_or_put',
      });
      return;
    }
    final hash = Uri.decodeComponent(
      request.uri.path.substring(blobPathPrefix.length),
    );
    if (!isBlobHash(hash)) {
      _safeRespond(request, HttpStatus.badRequest, {'error': 'bad_hash'});
      return;
    }
    final file = await admission.io(
      () => handler.handleFetchBlob(peerDeviceId, hash, admission: admission),
    );
    await _streamFile(
      request,
      file,
      admission: admission,
      error: 'blob_unavailable',
    );
  }

  /// Receives one pushed blob. The hash is the route's subject, the entry's
  /// kind and key are in headers, and the body is the raw bytes with a declared
  /// length — nothing is buffered as JSON, so an attachment streams through.
  Future<void> _receiveBlob(
    HttpRequest request,
    String peerDeviceId,
    SyncAdmission admission,
  ) async {
    if (request.headers.value(HttpHeaders.contentEncodingHeader) != null) {
      // The bytes are the content the hash names; a coded body would have to be
      // decoded before its length or its digest meant anything.
      _safeRespond(request, HttpStatus.badRequest, {'error': 'unencoded_only'});
      return;
    }
    final hash = Uri.decodeComponent(
      request.uri.path.substring(blobPathPrefix.length),
    );
    final kind = request.headers.value(blobKindHeader);
    final key = _decodedHeader(request, blobKeyHeader);
    final size = request.contentLength;
    if (!isBlobHash(hash) ||
        kind == null ||
        !SyncBlobEntry.kinds.contains(kind) ||
        key == null ||
        key.isEmpty) {
      _safeRespond(request, HttpStatus.badRequest, {'error': 'bad_request'});
      return;
    }
    if (size < 0) {
      // A chunked push declares no length, and the length is part of what the
      // receiver checks a file blob against.
      _safeRespond(request, HttpStatus.lengthRequired, {
        'error': 'length_required',
      });
      return;
    }
    final landed = await handler.handlePutBlob(
      peerDeviceId,
      hash,
      kind: kind,
      key: key,
      size: size,
      // The body is the one await here that can hang forever: a peer that sends
      // a length and then stops arriving. Wrapped so the handler's own read
      // throws at the budget instead of holding the lane.
      body: admission.ioStream(request),
      admission: admission,
    );
    await _respondNoContent(
      request,
      landed ? HttpStatus.noContent : HttpStatus.notFound,
    );
  }

  /// One workspace file, in either direction.
  ///
  /// `POST` streams back a file this device advertised to the caller. The pair
  /// is resolved by the handler against the table it walked and published; a
  /// pair it did not advertise — including one whose file changed since the
  /// walk — is answered 404, which the caller counts as an unapplied file and
  /// retries next session.
  ///
  /// `PUT` is the other direction: the initiator pushing a file this device
  /// asked for, because it could not fetch it (slice 23).
  Future<void> _handleWorkspaceFile(
    HttpRequest request,
    String peerDeviceId,
    SyncAdmission admission,
  ) async {
    if (request.method == 'PUT') {
      await _receiveWorkspaceFile(request, peerDeviceId, admission);
      return;
    }
    if (request.method != 'POST') {
      _safeRespond(request, HttpStatus.methodNotAllowed, {
        'error': 'post_or_put',
      });
      return;
    }
    final body = await _readJson(
      request,
      admission,
      maxBytes: _workspaceFileMaxBodyBytes,
    );
    if (body == null) {
      _safeRespond(request, HttpStatus.badRequest, {'error': 'bad_json'});
      return;
    }
    final workspaceId = body['ws'];
    final relPath = body['path'];
    if (workspaceId is! String ||
        workspaceId.isEmpty ||
        relPath is! String ||
        relPath.isEmpty) {
      _safeRespond(request, HttpStatus.badRequest, {'error': 'bad_request'});
      return;
    }
    final file = await admission.io(
      () => handler.handleFetchWorkspaceFile(
        peerDeviceId,
        workspaceId,
        relPath,
        admission: admission,
      ),
    );
    await _streamFile(
      request,
      file,
      admission: admission,
      error: 'workspace_file_unavailable',
    );
  }

  /// Receives one pushed workspace file. The metadata is in the headers and the
  /// bytes are the body, so nothing is buffered and the declared length is what
  /// the handler checks the file against.
  Future<void> _receiveWorkspaceFile(
    HttpRequest request,
    String peerDeviceId,
    SyncAdmission admission,
  ) async {
    if (request.headers.value(HttpHeaders.contentEncodingHeader) != null) {
      // The body is bytes, not a codec: a compressed one would have to be
      // decompressed before its length means anything, and the length is the
      // whole check.
      _safeRespond(request, HttpStatus.badRequest, {'error': 'unencoded_only'});
      return;
    }
    final workspaceId = _decodedHeader(request, workspaceIdHeader);
    final relPath = _decodedHeader(request, workspaceRelPathHeader);
    final size = request.contentLength;
    if (workspaceId == null ||
        workspaceId.isEmpty ||
        relPath == null ||
        relPath.isEmpty) {
      _safeRespond(request, HttpStatus.badRequest, {'error': 'bad_request'});
      return;
    }
    if (size < 0) {
      // A chunked push declares no length, and this route exists to check the
      // bytes against a length that was agreed in advance.
      _safeRespond(request, HttpStatus.lengthRequired, {
        'error': 'length_required',
      });
      return;
    }
    final landed = await handler.handlePutWorkspaceFile(
      peerDeviceId,
      workspaceId,
      relPath,
      size: size,
      body: admission.ioStream(request),
      admission: admission,
    );
    await _respondNoContent(
      request,
      landed ? HttpStatus.noContent : HttpStatus.notFound,
    );
  }

  /// One header's base64url-decoded UTF-8 value, or null when it is absent or
  /// not that. Peer input, so it never throws.
  static String? _decodedHeader(HttpRequest request, String name) {
    final raw = request.headers.value(name);
    if (raw == null || raw.isEmpty) return null;
    try {
      return utf8.decode(base64Url.decode(raw));
    } catch (_) {
      return null;
    }
  }

  /// One file, streamed with its length. A refusal (null or a file that
  /// vanished) is a 404 with [error] as its code; a peer that hangs up
  /// mid-stream is not an error this side can act on.
  Future<void> _streamFile(
    HttpRequest request,
    File? file, {
    required SyncAdmission admission,
    required String error,
  }) async {
    if (file == null || !await file.exists()) {
      _safeRespond(request, HttpStatus.notFound, {'error': error});
      return;
    }
    try {
      final length = await file.length();
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.binary;
      request.response.headers.set(HttpHeaders.contentLengthHeader, '$length');
      // A peer that stops reading never completes `addStream`, so this is the
      // await that would hold the read lane forever without the budget.
      await admission.io(
        () => request.response.addStream(admission.ioStream(file.openRead())),
      );
      await admission.io(() => request.response.close());
    } on SyncAdmissionLost {
      // The budget died mid-file, and the status line went out as `200` with the
      // full length before the first chunk did: no 504 can follow it now, and
      // `_serveOne`'s arm never runs because this method returns normally. What
      // the peer holds is a truncated body under a 200 — its client reads that
      // as a stream error and re-fetches, which is the retry this side wants.
      // (An earlier note here claimed the peer "was told 504"; it was not, and
      // the status is decided before the first await for exactly that reason.)
      try {
        await request.response.close().timeout(const Duration(seconds: 5));
      } catch (_) {}
    } catch (_) {
      // The peer hung up mid-stream; nothing to salvage.
      try {
        await request.response.close().timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
  }

  Future<void> _handleSubtrees(
    HttpRequest request,
    String peerDeviceId,
    SyncAdmission admission,
  ) async {
    if (request.method == 'PUT') {
      final body = await _readJson(
        request,
        admission,
        maxBytes: kSyncMaxBodyBytes,
      );
      if (body == null) {
        _safeRespond(request, HttpStatus.badRequest, {'error': 'bad_json'});
        return;
      }
      final ack = await handler.handleApplySubtrees(
        peerDeviceId,
        SyncDeltaBatch.fromJson(body),
        admission: admission,
      );
      _respondJson(request, HttpStatus.ok, ack.toJson());
      return;
    }
    if (request.method == 'POST') {
      final body = await _readJson(
        request,
        admission,
        maxBytes: kSyncMaxBodyBytes,
      );
      if (body == null) {
        _safeRespond(request, HttpStatus.badRequest, {'error': 'bad_json'});
        return;
      }
      final batch = await handler.handleFetchSubtrees(
        peerDeviceId,
        SyncFetchRequest.fromJson(body),
        admission: admission,
      );
      _respondJson(request, HttpStatus.ok, batch.toJson());
      return;
    }
    _safeRespond(request, HttpStatus.methodNotAllowed, {'error': 'bad_method'});
  }

  /// Unpair propagation. The auth gate already proved the caller holds the
  /// paired secret, so this is the minimal "forget me" — one status, no body
  /// semantics to version.
  Future<void> _handleRevoke(
    HttpRequest request,
    String peerDeviceId,
    SyncAdmission admission,
  ) async {
    if (request.method != 'POST') {
      _safeRespond(request, HttpStatus.methodNotAllowed, {
        'error': 'post_only',
      });
      return;
    }
    await handler.handleRevoke(peerDeviceId, admission: admission);
    _safeRespond(request, HttpStatus.ok, {'revoked': true});
  }

  // ---- codecs ----

  /// Cap on a `/pair` request body. The route is reachable without a pairing,
  /// so this is the one body an unauthenticated host controls; a real pairing
  /// request (certificate PEM + metadata) is a few KB.
  static const int _pairMaxBodyBytes = 64 * 1024;

  // The cap on an authenticated `/sync/*` JSON body, counted after
  // decompression, is [kSyncMaxBodyBytes]. It lives in `sync_limits.dart`
  // because the client's push budget is derived from it: a sender that built a
  // body this side refuses would stall the pair for good.

  /// Cap on a workspace file request body: one workspace id and one relative
  /// path. A path can be long, but nothing legitimate here is a kilobyte.
  static const int _workspaceFileMaxBodyBytes = 64 * 1024;

  /// Reads and decodes one JSON object body. Null means the body was not a
  /// decodable JSON object (the caller answers 400). A body whose wire or
  /// decompressed size exceeds [maxBytes] throws [_RequestBodyTooLarge]
  /// instead — only after the body has been read to the end (an HttpRequest
  /// allows a single listen, and abandoning it mid-stream aborts the
  /// connection before the refusal can be delivered), while nothing past the
  /// cap is buffered.
  ///
  /// The read is *not* wrapped in the admission's stream deadline, and that is
  /// deliberate. Cancelling a request body's subscription makes the server drop
  /// the connection, which takes the 504 down with it — a peer that announces a
  /// length and then stalls still deserves to be told the request is over (the
  /// half-sent `/pair` case is exactly this). Such a route opens no beat and
  /// commits nothing before its body is parsed, so an abandoned read leaves no
  /// state behind; the route's own `io()` is what returns the 504. Bodies that
  /// stream *inside* a handler (the two `PUT`s) are bounded with `ioStream`,
  /// where unwinding matters and a peer that is not reading its own upload is
  /// not owed an answer.
  Future<Map<String, dynamic>?> _readJson(
    HttpRequest request,
    SyncAdmission admission, {
    int? maxBytes,
  }) async {
    final buffer = <int>[];
    var received = 0;
    var tooLarge = false;
    try {
      final source = request.headers.value('content-encoding') == 'gzip'
          ? gzip.decoder.bind(request)
          : request;
      await for (final chunk in source) {
        received += chunk.length;
        if (maxBytes != null && received > maxBytes) {
          if (!tooLarge) buffer.clear();
          tooLarge = true;
          continue;
        }
        buffer.addAll(chunk);
      }
    } catch (_) {
      return null;
    }
    // A body that finished arriving after the deadline took the request must not
    // reach its handler: the peer has been told the request is over.
    admission.check();
    if (tooLarge) throw const _RequestBodyTooLarge();
    try {
      return jsonDecode(utf8.decode(buffer)) as Map<String, dynamic>;
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

  /// A status line and nothing else. 204 forbids a body, and the probe's whole
  /// answer is the status: the caller measures the round trip itself.
  Future<void> _respondNoContent(HttpRequest request, int status) async {
    try {
      request.response.statusCode = status;
      request.response.headers.removeAll(HttpHeaders.contentEncodingHeader);
      request.response.headers.contentType = null;
      request.response.headers.contentLength = 0;
      await request.response.close();
    } catch (_) {
      // The peer hung up first; nothing to salvage.
    }
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

/// Raised by `_readJson` when a body exceeded its cap. A class of its own so
/// the size refusal can surface as 413 while every other malformed body stays
/// a 400.
class _RequestBodyTooLarge implements Exception {
  const _RequestBodyTooLarge();
}

/// A request the handler refuses *before* touching any session state, carrying
/// the status the peer should read it as.
///
/// [SyncServerHandler] returns payloads, not status lines, so a beat that
/// belongs to no session could previously only be reported by throwing a
/// `StateError` — which the server answered as a 500 and the peer classified as
/// an internal error, naming neither the session nor the fix. A refusal the peer
/// can act on has to name itself.
class SyncRequestRefusal implements Exception {
  const SyncRequestRefusal(this.statusCode, this.error);

  /// A fetch beat that arrived before the push it belongs to.
  ///
  /// The responder's workspace ledger is what the push beat produced, so
  /// answering the fetch without it would advance the checkpoint with an *empty*
  /// ledger — which the content plan reads as "we never agreed about these
  /// files" and re-transfers, and which reads a file this device deleted as a
  /// file the peer never had.
  const SyncRequestRefusal.pushRequired()
    : statusCode = HttpStatus.conflict,
      error = 'push_required';

  /// The beat belongs to no live session for this peer: it was never accepted
  /// here, or it has already ended (see the engine's session sweeps).
  const SyncRequestRefusal.sessionMissing()
    : statusCode = HttpStatus.conflict,
      error = 'sync_session_missing';

  /// A second push beat on a session that already took one.
  ///
  /// Every session is *one* push followed by one fetch, and the fetch beat
  /// enforces its half of that ([pushRequired]); this is the other half. The
  /// push beat writes the session's outcome — the workspace ledger, the blob
  /// retry set, the business payload and its apply — while the counters a later
  /// push landing books into keep accumulating, so answering a replay would
  /// replace the outcome the report is built from and still count the bytes
  /// twice. A client that retries a request it never got an answer for cannot be
  /// told apart from a replay here, and a re-sent push re-runs every apply; the
  /// honest answer is that the session already has its push.
  const SyncRequestRefusal.pushAlreadyTaken()
    : statusCode = HttpStatus.conflict,
      error = 'push_already_taken';

  final int statusCode;
  final String error;

  @override
  String toString() => 'SyncRequestRefusal($statusCode): $error';
}
