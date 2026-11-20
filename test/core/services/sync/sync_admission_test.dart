import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/services/sync/sync_admission.dart';
import 'package:Cuplivo/core/services/sync/sync_client.dart';
import 'package:Cuplivo/core/services/sync/sync_identity.dart';
import 'package:Cuplivo/core/services/sync/sync_limits.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:Cuplivo/core/services/sync/sync_server.dart';
import 'package:Cuplivo/core/services/sync/sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// The lanes one listener serves, what may run beside what, and what a request's
/// budget is spent on at both ends.
///
/// These cells use a real [SyncServer] over loopback TLS and a handler that
/// answers instantly, so what they measure is the *lane*, not an engine: a
/// request whose body never finishes arriving holds the write lane for as long
/// as the test likes, and every other request is observed against that. The last
/// cell turns the same trick around: a peer that accepts a push and never reads
/// it is what a transfer budget is for.
///
/// The engine-level halves of the same table (a ring of three devices, a
/// cancelled handler that must not write) live in
/// `sync_engine_integration_test.dart`, where a session can be built.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // This suite needs real sockets, and the test binding installs a mock
  // HttpClient that answers every request with an empty 400 — the same reason
  // `sync_engine_integration_test.dart` clears it.
  HttpOverrides.global = null;

  const peerId = 'peer-device';
  const secret = 'pairing-secret';
  const blobHash =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  late SyncDeviceIdentity identity;
  late Directory root;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('sync-admission-identity-');
    identity = await SyncDeviceIdentity.loadOrCreate(
      root,
      fallbackName: 'admission',
    );
  });

  tearDownAll(() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  Future<SyncServer> startServer(
    _RecordingHandler handler, {
    Duration? deadline,
    Duration Function(String path)? deadlineFor,
  }) async {
    final directory = await Directory.systemTemp.createTemp('sync-admission-');
    final store = SyncStore(directory);
    final server = SyncServer(
      identity: identity,
      store: store,
      handler: handler,
      deadlineFor: deadlineFor ?? (deadline == null ? null : (_) => deadline),
    );
    addTearDown(() async {
      await server.stop();
      try {
        await directory.delete(recursive: true);
      } catch (_) {}
    });
    final port = await server.start(address: '127.0.0.1', requestedPort: 0);
    // After start(): it reloads the peer set from the store, so a record
    // remembered before the bind would be cleared.
    server.rememberPeer(
      SyncPeerRecord(
        deviceId: peerId,
        certPem: '',
        secret: secret,
        name: 'peer',
        platform: 'test',
      ),
    );
    expect(port, greaterThan(0));
    return server;
  }

  /// Holds the write lane with a request that announced a body and then stopped
  /// sending it. The handler is never reached, so nothing but the lane is
  /// occupied — which is exactly the state a twenty-minute push beat leaves.
  Future<SecureSocket> holdWriteLane(int port) async {
    final socket = await SecureSocket.connect(
      '127.0.0.1',
      port,
      onBadCertificate: (_) => true,
    );
    addTearDown(socket.destroy);
    socket.write(
      'PUT /sync/subtrees HTTP/1.1\r\n'
      'Host: 127.0.0.1\r\n'
      '${SyncServer.deviceHeader}: $peerId\r\n'
      '${SyncServer.tokenHeader}: $secret\r\n'
      'Content-Type: application/json\r\n'
      'Content-Length: 900000\r\n'
      '\r\n'
      '{"x":',
    );
    await socket.flush();
    // The loop reads the headers as soon as they arrive; the pause is for the
    // dispatch to have happened before the observation starts.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    return socket;
  }

  HttpClient client() {
    final http = HttpClient()..badCertificateCallback = (_, _, _) => true;
    addTearDown(() => http.close(force: true));
    return http;
  }

  void authenticate(HttpClientRequest request) {
    request.headers.set(SyncServer.deviceHeader, peerId);
    request.headers.set(SyncServer.tokenHeader, secret);
  }

  Future<HttpClientResponse> getBlob(HttpClient http, int port) async {
    final request = await http.getUrl(
      Uri.parse('https://127.0.0.1:$port${SyncServer.blobPathPrefix}$blobHash'),
    );
    authenticate(request);
    return request.close();
  }

  Future<HttpClientResponse> postWorkspaceFile(
    HttpClient http,
    int port,
  ) async {
    final request = await http.postUrl(
      Uri.parse('https://127.0.0.1:$port${SyncServer.workspaceFilePath}'),
    );
    authenticate(request);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'ws': 'w1', 'path': 'a.txt'}));
    return request.close();
  }

  test('a blob fetch is answered while a write beat holds the lane', () async {
    // The ring this exists for: a session's push beat pulls attachments from
    // the other side, so a device waiting on that pull answers it *while its
    // own inbound session runs*. With one lane, three devices wait on each
    // other and none of them can answer.
    final handler = _RecordingHandler();
    final server = await startServer(handler, deadline: null);
    await holdWriteLane(server.port!);

    final watch = Stopwatch()..start();
    final response = await getBlob(client(), server.port!);
    await response.drain<void>();
    watch.stop();

    expect(
      response.statusCode,
      HttpStatus.notFound,
      reason: 'the handler has no such blob; the answer is the point',
    );
    expect(
      watch.elapsed,
      lessThan(const Duration(seconds: 2)),
      reason: 'a read must not be queued behind a running write beat',
    );
    expect(handler.blobFetches, 1);
  });

  test('the read direction of /sync/wsfile answers beside a write', () async {
    final handler = _RecordingHandler();
    final server = await startServer(handler, deadline: null);
    await holdWriteLane(server.port!);

    final watch = Stopwatch()..start();
    final response = await postWorkspaceFile(client(), server.port!);
    await response.drain<void>();
    watch.stop();

    expect(response.statusCode, HttpStatus.notFound);
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    expect(handler.workspaceFetches, 1);
  });

  test('a method that writes nothing is not queued either', () async {
    // Classification is by effect: `GET /sync/hello` matches no write, so it is
    // answered beside the lane even though its path is the write route's.
    final handler = _RecordingHandler();
    final server = await startServer(handler, deadline: null);
    await holdWriteLane(server.port!);

    final http = client();
    final request = await http.getUrl(
      Uri.parse('https://127.0.0.1:${server.port!}/sync/hello'),
    );
    authenticate(request);
    final response = await request.close().timeout(const Duration(seconds: 2));
    await response.drain<void>();

    expect(response.statusCode, HttpStatus.methodNotAllowed);
    expect(handler.hellos, 0, reason: 'the route refuses before the handler');
  });

  test('a write is still queued behind the one in flight', () async {
    // The other half of the table: the read lane must not have become "every
    // request runs at once". A hello is a write, and a write waits.
    final handler = _RecordingHandler();
    final server = await startServer(handler, deadline: null);
    await holdWriteLane(server.port!);

    final http = client();
    final request = await http.postUrl(
      Uri.parse('https://127.0.0.1:${server.port!}/sync/hello'),
    );
    authenticate(request);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(handler.helloBody()));
    await expectLater(
      request.close().timeout(const Duration(milliseconds: 600)),
      throwsA(isA<TimeoutException>()),
      reason: 'a write beat holds the lane until it finishes',
    );
    expect(handler.hellos, 0);
  });

  test('a path this listener does not serve answers without a lane', () async {
    final handler = _RecordingHandler();
    final server = await startServer(handler, deadline: null);
    await holdWriteLane(server.port!);

    final http = client();
    final request = await http.getUrl(
      Uri.parse('https://127.0.0.1:${server.port!}/nothing-here'),
    );
    final response = await request.close().timeout(const Duration(seconds: 2));
    await response.drain<void>();
    expect(response.statusCode, HttpStatus.notFound);
  });

  test('a request queued behind a beat has already spent its budget', () async {
    // The budget starts when the listener reads the request, not when its turn
    // comes: a request that waited thirty minutes behind a beat does not then
    // get thirty minutes of its own.
    final handler = _RecordingHandler();
    final server = await startServer(
      handler,
      deadlineFor: (path) => path == '/sync/hello'
          ? const Duration(milliseconds: 400)
          : const Duration(minutes: 30),
    );
    final holder = await holdWriteLane(server.port!);

    final http = client();
    final request = await http.postUrl(
      Uri.parse('https://127.0.0.1:${server.port!}/sync/hello'),
    );
    authenticate(request);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(handler.helloBody()));
    // Not awaited: it is queued, and the lane is held.
    final pending = request.close();

    // Outlive the hello's budget by a margin, then let the lane go.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    holder.destroy();

    final response = await pending.timeout(const Duration(seconds: 5));
    await response.drain<void>();

    expect(response.statusCode, HttpStatus.gatewayTimeout);
    expect(
      handler.hellos,
      0,
      reason:
          'a request whose budget ran out while it waited never reaches '
          'its handler',
    );
  });

  test('a handler that outlives its budget is told, not just outlived', () async {
    // The old route `.timeout()` answered 504 and left the handler running with
    // no way to know: it went on to install a session and write a checkpoint
    // after its peer had been told the request was over. The gate is what the
    // handler reads to know.
    final handler = _RecordingHandler()..helloGate = Completer<void>();
    final server = await startServer(
      handler,
      deadline: const Duration(milliseconds: 300),
    );

    final http = client();
    final request = await http.postUrl(
      Uri.parse('https://127.0.0.1:${server.port!}/sync/hello'),
    );
    authenticate(request);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(handler.helloBody()));

    final response = await request.close().timeout(const Duration(seconds: 5));
    await response.drain<void>();

    expect(response.statusCode, HttpStatus.gatewayTimeout);
    expect(
      handler.helloGateLostWhenReleased,
      isTrue,
      reason: 'the handler must be able to see that its budget is gone',
    );
  });

  test('a push the peer never reads ends inside its budget', () async {
    // The client's half of the same defect. `addStream` sat outside every timer,
    // so a peer that accepted a push and stopped reading left the upload (and
    // the session behind it) pending forever. The budget belongs to the whole
    // transfer, and the request is aborted when it runs out — a `.timeout` alone
    // leaves the socket open for the next request to queue behind.
    final peer = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      identity.buildContext(),
      requestClientCertificate: false,
    );
    addTearDown(() => peer.close(force: true));
    // Accepted and never read: this is the peer that stops reading, and the
    // socket's own buffers are what the client gets to fill.
    peer.listen((request) {});

    final directory = await Directory.systemTemp.createTemp('sync-push-');
    addTearDown(() => directory.delete(recursive: true));
    final payload = File('${directory.path}${Platform.pathSeparator}x.bin');
    await payload.writeAsBytes(List.filled(32 * 1024 * 1024, 7));

    final session = SyncClient(identity: identity).openSession(
      SyncPeerRecord(
        deviceId: identity.deviceId,
        certPem: identity.certPem,
        secret: secret,
        name: 'self',
        platform: 'test',
      ),
      host: '127.0.0.1',
      port: peer.port,
      blobDeadline: const Duration(milliseconds: 500),
    );
    addTearDown(session.close);

    final watch = Stopwatch()..start();
    Object? failure;
    try {
      await session
          .pushBlob(
            entry: SyncBlobEntry(
              kind: SyncBlobEntry.kindFile,
              key: 'file:///managed/x.bin',
              contentHash: blobHash,
              byteSize: 32 * 1024 * 1024,
            ),
            source: payload,
            size: 32 * 1024 * 1024,
          )
          .timeout(const Duration(seconds: 10));
    } catch (error) {
      failure = error;
    }
    watch.stop();

    expect(
      failure,
      isA<SyncClientException>(),
      reason: 'the transfer must end by its own budget, not hang',
    );
    expect(
      watch.elapsed,
      lessThan(const Duration(seconds: 5)),
      reason: 'and end near the budget it was given',
    );
  });
  test('pairing has its own capped lane, and cannot hold the data plane', () async {
    // `/pair` is the one face that answers before any authentication exists, so
    // it cannot share the data lanes: a stranger filling it must not be able to
    // stop this device syncing — nor to stop the *user* pairing, which is the
    // route they reach for exactly when something is broken.
    final handler = _RecordingHandler()..pairGate = Completer<void>();
    addTearDown(() {
      if (!handler.pairGate!.isCompleted) handler.pairGate!.complete();
    });
    final server = await startServer(handler, deadline: null);
    final http = client();
    final pairBody = jsonEncode({
      'pin': '000000',
      'deviceId': identity.deviceId,
      'deviceName': 'stranger',
      'platform': 'test',
      'certPem': identity.certPem,
    });

    Future<HttpClientResponse> postPair() async {
      final request = await http.postUrl(
        Uri.parse('https://127.0.0.1:${server.port!}/pair'),
      );
      request.headers.contentType = ContentType.json;
      request.write(pairBody);
      // Flushed one at a time, and then waited for by condition: four TLS
      // handshakes fired at once against a freshly bound listener can be
      // aborted under a full test run, and a fixed sleep either hides that or
      // reports it as "the lane is empty".
      await request.flush();
      return request.close();
    }

    // Fill the pairing lane; every one of these reaches the handler and waits.
    final held = <Future<HttpClientResponse>>[];
    for (var i = 0; i < kMaxPairRequestsInFlight; i++) {
      held.add(postPair());
    }
    await _waitUntil(
      () => handler.pairs == kMaxPairRequestsInFlight,
      what:
          'all $kMaxPairRequestsInFlight pairing requests reached the handler',
    );

    // One past the cap is refused, with a status the caller can act on.
    final over = await postPair();
    final overBody = await over.transform(utf8.decoder).join();
    expect(over.statusCode, HttpStatus.serviceUnavailable);
    expect(overBody, contains('pair_busy'));
    expect(handler.pairs, kMaxPairRequestsInFlight, reason: 'never reached it');

    // The data plane is untouched, in both directions: a read answers beside the
    // full pairing lane, and so does a write.
    final blob = await getBlob(http, server.port!);
    await blob.drain<void>();
    expect(blob.statusCode, HttpStatus.notFound);

    final hello = await http.postUrl(
      Uri.parse('https://127.0.0.1:${server.port!}/sync/hello'),
    );
    authenticate(hello);
    hello.headers.contentType = ContentType.json;
    hello.write(jsonEncode(handler.helloBody()));
    final helloResponse = await hello.close().timeout(
      const Duration(seconds: 5),
    );
    await helloResponse.drain<void>();
    expect(helloResponse.statusCode, HttpStatus.ok);
    expect(handler.hellos, 1);

    handler.pairGate!.complete();
    for (final response in held) {
      await (await response).drain<void>();
    }
  });

  test('an unauthenticated request never joins a queue', () async {
    // The other half of N1: a forged `POST /sync/hello` used to be answered 401
    // *on the write lane*, so a stranger could fill the queue in front of a
    // paired peer's beat with requests that were only ever going to be refused.
    final handler = _RecordingHandler();
    final server = await startServer(handler, deadline: null);
    final holder = await holdWriteLane(server.port!);

    final http = client();
    final request = await http.postUrl(
      Uri.parse('https://127.0.0.1:${server.port!}/sync/hello'),
    );
    request.headers.set(SyncServer.deviceHeader, 'stranger');
    request.headers.set(SyncServer.tokenHeader, 'not-the-secret');
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(handler.helloBody()));

    final response = await request.close().timeout(const Duration(seconds: 2));
    await response.drain<void>();

    expect(response.statusCode, HttpStatus.unauthorized);
    expect(handler.hellos, 0);
    holder.destroy();
  });

  test('a request that waited keeps only what is left of its budget', () async {
    // A queued request does not get a second budget. It runs — with the budget
    // the wait left it — so a beat that would fit in a fresh budget is cut short
    // here, and the caller is told 504. (`a request queued behind a beat has
    // already spent its budget` is the other end: nothing left, so it never runs.)
    final handler = _RecordingHandler()
      ..helloDelay = const Duration(milliseconds: 400);
    final server = await startServer(
      handler,
      deadlineFor: (path) => path == '/sync/hello'
          ? const Duration(milliseconds: 600)
          : const Duration(minutes: 30),
    );
    final holder = await holdWriteLane(server.port!);

    final http = client();
    final request = await http.postUrl(
      Uri.parse('https://127.0.0.1:${server.port!}/sync/hello'),
    );
    authenticate(request);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(handler.helloBody()));
    final pending = request.close();

    // Spend most of the hello's budget while it waits, then let it run.
    await Future<void>.delayed(const Duration(milliseconds: 450));
    holder.destroy();
    final watch = Stopwatch()..start();
    final response = await pending.timeout(const Duration(seconds: 5));
    await response.drain<void>();
    watch.stop();

    expect(
      response.statusCode,
      HttpStatus.gatewayTimeout,
      reason: '400 ms of work does not fit in the ~150 ms the wait left',
    );
    expect(handler.hellos, 1, reason: 'it did run — unlike a spent budget');
    expect(
      watch.elapsed,
      lessThan(const Duration(milliseconds: 550)),
      reason: 'and was cut at what was left, not given a fresh 600 ms',
    );
  });

  test('an error body that never ends is not waited out', () async {
    // A refusal is drained so the connection can be reused, and a body that then
    // stops arriving used to leave that drain pending forever — the peer had
    // answered, and the caller still hung.
    final peer = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      identity.buildContext(),
      requestClientCertificate: false,
    );
    addTearDown(() => peer.close(force: true));
    peer.listen((request) {
      request.response.statusCode = HttpStatus.notFound;
      // Headers out, body opened and never finished.
      request.response.write('{"error":');
      unawaited(request.response.flush());
    });

    final directory = await Directory.systemTemp.createTemp('sync-drain-');
    addTearDown(() => directory.delete(recursive: true));
    final destination = File('${directory.path}${Platform.pathSeparator}x.bin');

    final session = SyncClient(identity: identity).openSession(
      SyncPeerRecord(
        deviceId: identity.deviceId,
        certPem: identity.certPem,
        secret: secret,
        name: 'self',
        platform: 'test',
      ),
      host: '127.0.0.1',
      port: peer.port,
      blobDeadline: const Duration(milliseconds: 400),
    );
    addTearDown(session.close);

    final watch = Stopwatch()..start();
    Object? failure;
    try {
      await session
          .fetchBlob(
            SyncBlobEntry(
              kind: SyncBlobEntry.kindFile,
              key: 'file:///managed/x.bin',
              contentHash: blobHash,
              byteSize: 4,
            ),
            destination,
          )
          .timeout(const Duration(seconds: 10));
    } catch (error) {
      failure = error;
    }
    watch.stop();

    expect(failure, isNotNull, reason: 'the drain must end by its budget');
    expect(
      watch.elapsed,
      lessThan(const Duration(seconds: 5)),
      reason: 'and end near the 400 ms budget, not hang',
    );
  });

  test('a cancelled write handler cannot commit beside the next one', () async {
    // The write lane orders *responses*, not handler lifetimes: a handler the
    // deadline abandoned keeps running until its next await or check. What keeps
    // that safe is the gate — only a live admission commits — and this cell is
    // that claim, stated as what the code does rather than as "no two handlers
    // overlap", which the lane cannot promise once it has answered 504.
    final handler = _RecordingHandler()
      ..helloGate = Completer<void>()
      ..gateIgnoresAdmission = true
      ..recordCommit = true;
    final server = await startServer(
      handler,
      deadlineFor: (_) => const Duration(milliseconds: 300),
    );
    final http = client();

    Future<HttpClientResponse> hello() async {
      final request = await http.postUrl(
        Uri.parse('https://127.0.0.1:${server.port!}/sync/hello'),
      );
      authenticate(request);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(handler.helloBody()));
      return request.close();
    }

    final first = hello();
    await _waitUntil(
      () => handler.hellos == 1,
      what: 'the first hello reached the handler',
    );
    final firstResponse = await first;
    await firstResponse.drain<void>();
    expect(firstResponse.statusCode, HttpStatus.gatewayTimeout);

    // The lane admits the next write while the abandoned one is still inside its
    // handler — the overlap, measured rather than assumed.
    final second = await hello();
    await second.drain<void>();
    expect(second.statusCode, HttpStatus.ok);

    // One handler committed, and it was the live one.
    expect(handler.commits, [true]);

    handler.helloGate!.complete();
    await _waitUntil(
      () => handler.commits.length == 2,
      what: 'the abandoned handler reached its commit point',
    );
    expect(handler.commits, [true, false]);
  });

  test('a body that keeps arriving is cut at the deadline, not at its end', () async {
    // `Stream.timeout` restarts on every event, so it bounds *silence*: a peer
    // that dribbles a chunk inside every interval would hold the handler — and
    // its temp file and its beat — for as long as it likes. The budget is
    // absolute, so the read must end at the deadline whether or not the body
    // stopped.
    final handler = _RecordingHandler()..observeBody = true;
    final server = await startServer(
      handler,
      deadlineFor: (_) => const Duration(milliseconds: 400),
    );
    final http = client();
    final request = await http.putUrl(
      Uri.parse(
        'https://127.0.0.1:${server.port!}${SyncServer.workspaceFilePath}',
      ),
    );
    authenticate(request);
    request.headers.set(
      SyncServer.workspaceIdHeader,
      base64Url.encode(utf8.encode('w1')),
    );
    request.headers.set(
      SyncServer.workspaceRelPathHeader,
      base64Url.encode(utf8.encode('a.txt')),
    );
    const chunks = 20;
    request.contentLength = chunks * 4;
    final watch = Stopwatch()..start();
    final body = Stream<List<int>>.periodic(
      const Duration(milliseconds: 50),
      (_) => const [1, 2, 3, 4],
    ).take(chunks);
    final pending = request.addStream(body).then((_) => request.close());
    HttpClientResponse? response;
    Object? sendError;
    try {
      response = await pending.timeout(const Duration(seconds: 10));
    } catch (error) {
      // The listener closed the connection with the body still arriving, so the
      // uploader may never read a status. Which of the two it gets is not what
      // this cell measures: the read ending is.
      sendError = error;
    }
    if (response != null) {
      await response.drain<void>();
      expect(response.statusCode, HttpStatus.gatewayTimeout);
    } else {
      // Whichever end it reaches, the upload ends: a status or a dead socket.
      expect(sendError, isNotNull);
    }
    watch.stop();
    // Two mechanisms can end the read at the deadline, and which one wins is a
    // race this cell does not need to settle: the gate's per-event check (the
    // unit cell below) or the response being written and the connection closed
    // under the still-arriving body. What must not happen is the third outcome:
    // a body read to its end after the budget was gone.
    expect(
      handler.bodyError,
      isNotNull,
      reason: 'the read ends, it is not drained',
    );
    expect(
      handler.bodyChunks,
      lessThan(chunks),
      reason: 'a drip cannot reach the end of the body inside the budget',
    );
    expect(
      watch.elapsed,
      lessThan(const Duration(seconds: 3)),
      reason: 'and the beat ends at the deadline, not after the body',
    );
  });

  test('a stream that keeps emitting is cut when the budget ends', () async {
    // `Stream.timeout` restarts its countdown on every event, so on its own it
    // bounds silence: a stream that emits inside every interval would never trip
    // it. This is the mechanism that makes the budget absolute, tested without a
    // socket so the gate — not a torn-down connection — is what ends it.
    final gate = SyncAdmission(budget: const Duration(milliseconds: 200));
    final watch = Stopwatch()..start();
    var seen = 0;
    Object? failure;
    try {
      await for (final _ in gate.ioStream(
        Stream<int>.periodic(
          const Duration(milliseconds: 20),
          (value) => value,
        ).take(200),
      )) {
        seen++;
      }
    } catch (error) {
      failure = error;
    }
    watch.stop();

    expect(failure, isA<SyncAdmissionLost>());
    expect(seen, lessThan(200), reason: 'the stream is cut, not consumed');
    expect(
      watch.elapsed,
      lessThan(const Duration(seconds: 2)),
      reason: 'at the budget, not at the end of the stream',
    );
  });

  test('every route takes the lane its effect names', () async {
    // `SyncServer._classify` is one row per route and the dispatch is an
    // exhaustive switch over it, so a route cannot be served without a lane. This
    // cell is the other half: the lane a row claims is the lane *observed* — with
    // the write lane held by a stalled body, a write route waits and nothing else
    // does. Without it a row flipped by hand (a `PUT` called a read) would pass
    // every other test in this file, because they only exercise the routes they
    // care about.
    final cases = <(String, String, bool)>[
      ('POST', '/sync/hello', true),
      ('PUT', '/sync/subtrees', true),
      ('POST', '/sync/subtrees', true),
      ('POST', '/sync/revoke', true),
      ('PUT', SyncServer.workspaceFilePath, true),
      ('PUT', '${SyncServer.blobPathPrefix}$blobHash', true),
      // A method the route does not serve answers its 405 beside the lanes: it
      // must not queue on the lane the right method would have taken.
      ('GET', '/sync/hello', false),
      ('DELETE', '/sync/hello', false),
      ('GET', '/sync/subtrees', false),
      ('GET', '/sync/revoke', false),
      ('POST', SyncServer.workspaceFilePath, false),
      ('GET', '${SyncServer.blobPathPrefix}$blobHash', false),
      // Its own lanes, and no path at all.
      ('POST', '/sync/ping', false),
      ('POST', '/pair', false),
      ('GET', '/pair', false),
      ('GET', '/nothing-here', false),
    ];
    for (final (method, path, writes) in cases) {
      final handler = _RecordingHandler();
      final server = await startServer(handler, deadline: null);
      final holder = await holdWriteLane(server.port!);
      final http = client();
      final request = await http.openUrl(
        method,
        Uri.parse('https://127.0.0.1:${server.port!}$path'),
      );
      authenticate(request);
      request.headers.contentType = ContentType.json;
      if (method != 'GET') {
        // A body each route can parse: the held lane releases the queued request
        // when it is destroyed, and a 500 from a request this cell never looks at
        // would be noise in the suite's output.
        request.write(
          jsonEncode(path == '/sync/hello' ? handler.helloBody() : {}),
        );
      }
      final pending = request.close();
      pending.ignore();
      HttpClientResponse? answered;
      try {
        answered = await pending.timeout(const Duration(seconds: 1));
      } on TimeoutException {
        answered = null;
      }
      if (writes) {
        expect(
          answered,
          isNull,
          reason: '$method $path writes, so it must wait for the write lane',
        );
      } else {
        expect(
          answered,
          isNotNull,
          reason:
              '$method $path writes nothing, so it must not wait for the '
              'write lane',
        );
        await answered!.drain<void>();
      }
      holder.destroy();
    }
  });
}

/// Polls [condition] until it holds, or fails naming what never happened.
///
/// A fixed sleep is the wrong synchronisation for "the listener has read these
/// requests yet": under a full test run it is either too short (a false red) or
/// too long (a slow suite), and it reports the wait rather than the fact.
Future<void> _waitUntil(
  bool Function() condition, {
  required String what,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after $timeout waiting until $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// A handler that answers every route immediately, counting what it was asked.
///
/// The lanes are what these tests measure, so nothing here may block: a route
/// that stalls here would be indistinguishable from a lane that queues.
class _RecordingHandler implements SyncServerHandler {
  int hellos = 0;
  int blobFetches = 0;
  int pairs = 0;

  /// Held open by a test that wants the pairing lane full.
  Completer<void>? pairGate;
  int workspaceFetches = 0;

  /// Held open by a test that wants a write handler to outlive its budget.
  ///
  /// It holds the **first** hello only, so a test can hold one handler past its
  /// deadline and still let the next request through the same route.
  Completer<void>? helloGate;

  /// Wait for [helloGate] without consulting the admission — the shape the
  /// engine's reverse-dial awaits have, where the deadline abandons the handler
  /// rather than unwinding it.
  bool gateIgnoresAdmission = false;

  /// Record whether this handler's own commit point was allowed. True is a live
  /// admission; false is the refusal a cancelled handler gets.
  bool recordCommit = false;

  /// One entry per handler that reached its commit point, in arrival order.
  final List<bool> commits = [];

  /// How long the hello handler takes before answering — a beat that can be cut
  /// short by what a queue wait left of the budget.
  Duration? helloDelay;

  /// What the hello's admission said once its `io()` gave up — the fact a
  /// cancelled handler has to be able to observe.
  bool? helloGateLostWhenReleased;

  Map<String, dynamic> helloBody() => {
    'protocolVersion': kSyncProtocolVersion,
    'schemaVersion': 1,
    'deviceId': 'admission-test',
    'deviceName': 'admission',
    'platform': 'test',
    'manifest': const <String, dynamic>{},
  };

  @override
  Future<Object> handleHello(
    String peerDeviceId,
    SyncHello initiatorHello, {
    String? remoteAddress,
    required SyncAdmission admission,
  }) async {
    hellos++;
    final delay = helloDelay;
    if (delay != null) await Future<void>.delayed(delay);
    final gate = hellos == 1 ? helloGate : null;
    if (gate != null) {
      if (gateIgnoresAdmission) {
        await gate.future;
      } else {
        try {
          await admission.io(() => gate.future);
        } on SyncAdmissionLost {
          helloGateLostWhenReleased = admission.isLost;
          rethrow;
        }
      }
    }
    if (recordCommit) {
      try {
        admission.check();
        commits.add(true);
      } on SyncAdmissionLost {
        commits.add(false);
      }
    }
    return SyncHello(
      protocolVersion: kSyncProtocolVersion,
      schemaVersion: 1,
      deviceId: 'admission-test',
      deviceName: 'admission',
      platform: 'test',
      manifest: const SyncManifest(<String, SyncManifestEntry>{}),
    );
  }

  @override
  Future<File?> handleFetchBlob(
    String peerDeviceId,
    String contentHash, {
    required SyncAdmission admission,
  }) async {
    blobFetches++;
    return null;
  }

  @override
  Future<File?> handleFetchWorkspaceFile(
    String peerDeviceId,
    String workspaceId,
    String relPath, {
    required SyncAdmission admission,
  }) async {
    workspaceFetches++;
    return null;
  }

  /// Answered, not thrown: the lane table's cell releases a queued write when it
  /// destroys the held lane, and a throw there would print a 500 from a request
  /// the test never looks at.
  @override
  Future<SyncDeltaBatch> handleFetchSubtrees(
    String peerDeviceId,
    SyncFetchRequest request, {
    required SyncAdmission admission,
  }) async => const SyncDeltaBatch(<SyncSubtreePayload>[]);

  @override
  Future<SyncApplyAck> handleApplySubtrees(
    String peerDeviceId,
    SyncDeltaBatch batch, {
    required SyncAdmission admission,
  }) async => const SyncApplyAck(applied: 0);

  /// Read the PUT body chunk by chunk and record where the read ended, instead
  /// of draining it at once — the shape a drip test needs.
  bool observeBody = false;

  /// How many chunks the body reader saw.
  int bodyChunks = 0;

  /// What ended the read, when it was not the end of the body.
  Object? bodyError;

  @override
  Future<bool> handlePutWorkspaceFile(
    String peerDeviceId,
    String workspaceId,
    String relPath, {
    required int size,
    required Stream<List<int>> body,
    required SyncAdmission admission,
  }) async {
    if (!observeBody) {
      await body.drain<void>();
      return true;
    }
    try {
      await for (final _ in body) {
        bodyChunks++;
      }
    } catch (error) {
      bodyError = error;
    }
    return true;
  }

  @override
  Future<bool> handlePutBlob(
    String peerDeviceId,
    String contentHash, {
    required String kind,
    required String key,
    required int size,
    required Stream<List<int>> body,
    required SyncAdmission admission,
  }) async {
    await body.drain<void>();
    return true;
  }

  @override
  Future<SyncPairAnswer?> handlePair(
    SyncPairRequest request,
    String? initiatorHost, {
    required SyncAdmission admission,
  }) async {
    pairs++;
    final gate = pairGate;
    if (gate != null) {
      try {
        await admission.io(() => gate.future);
      } on SyncAdmissionLost {
        rethrow;
      }
    }
    return null;
  }

  @override
  Future<void> handleRevoke(
    String peerDeviceId, {
    required SyncAdmission admission,
  }) async {}
}
