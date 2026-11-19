import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/services/sync/sync_identity.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:Cuplivo/core/services/sync/sync_server.dart';
import 'package:Cuplivo/core/services/sync/sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// The lanes one listener serves, and what may run beside what.
///
/// These cells use a real [SyncServer] over loopback TLS and a handler that
/// answers instantly, so what they measure is the *lane*, not an engine: a
/// request whose body never finishes arriving holds the write lane for as long
/// as the test likes, and every other request is observed against that.
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
  }) async {
    final directory = await Directory.systemTemp.createTemp('sync-admission-');
    final store = SyncStore(directory);
    final server = SyncServer(
      identity: identity,
      store: store,
      handler: handler,
      deadlineFor: deadline == null ? null : (_) => deadline,
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
}

/// A handler that answers every route immediately, counting what it was asked.
///
/// The lanes are what these tests measure, so nothing here may block: a route
/// that stalls here would be indistinguishable from a lane that queues.
class _RecordingHandler implements SyncServerHandler {
  int hellos = 0;
  int blobFetches = 0;
  int workspaceFetches = 0;

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
  }) async {
    hellos++;
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
  Future<File?> handleFetchBlob(String peerDeviceId, String contentHash) async {
    blobFetches++;
    return null;
  }

  @override
  Future<File?> handleFetchWorkspaceFile(
    String peerDeviceId,
    String workspaceId,
    String relPath,
  ) async {
    workspaceFetches++;
    return null;
  }

  @override
  Future<SyncDeltaBatch> handleFetchSubtrees(
    String peerDeviceId,
    SyncFetchRequest request,
  ) async => throw UnimplementedError();

  @override
  Future<SyncApplyAck> handleApplySubtrees(
    String peerDeviceId,
    SyncDeltaBatch batch,
  ) async => throw UnimplementedError();

  @override
  Future<bool> handlePutWorkspaceFile(
    String peerDeviceId,
    String workspaceId,
    String relPath, {
    required int size,
    required Stream<List<int>> body,
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
  }) async {
    await body.drain<void>();
    return true;
  }

  @override
  Future<SyncPairAnswer?> handlePair(
    SyncPairRequest request,
    String? initiatorHost,
  ) async => null;

  @override
  Future<void> handleRevoke(String peerDeviceId) async {}
}
