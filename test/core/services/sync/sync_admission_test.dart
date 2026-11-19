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
  Completer<void>? helloGate;

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
    final gate = helloGate;
    if (gate != null) {
      try {
        await admission.io(() => gate.future);
      } on SyncAdmissionLost {
        helloGateLostWhenReleased = admission.isLost;
        rethrow;
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

  @override
  Future<SyncDeltaBatch> handleFetchSubtrees(
    String peerDeviceId,
    SyncFetchRequest request, {
    required SyncAdmission admission,
  }) async => throw UnimplementedError();

  @override
  Future<SyncApplyAck> handleApplySubtrees(
    String peerDeviceId,
    SyncDeltaBatch batch, {
    required SyncAdmission admission,
  }) async => throw UnimplementedError();

  @override
  Future<bool> handlePutWorkspaceFile(
    String peerDeviceId,
    String workspaceId,
    String relPath, {
    required int size,
    required Stream<List<int>> body,
    required SyncAdmission admission,
  }) async {
    await body.drain<void>();
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
