import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/services/sync/sync_admission.dart';
import 'package:Cuplivo/core/services/sync/sync_client.dart';
import 'package:Cuplivo/core/services/sync/sync_identity.dart';
import 'package:Cuplivo/core/services/sync/sync_server.dart';
import 'package:Cuplivo/core/services/sync/sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// The `x-cuplivo-remote` marker (ADR-0021, decision 7): a remote session
/// arrives through this device's own tailcat relay, so the socket's source is
/// loopback and says nothing about the peer. The server turns the marker into
/// "no source hint", and the peer's advertised candidates carry the return
/// direction instead.
///
/// This is the server half in isolation: a real [SyncServer] over loopback TLS,
/// with a handler that records what the `/pair` route was told. The engine half
/// — the responder's peer record not gaining a `127.0.0.1` endpoint — is in
/// `sync_engine_integration_test.dart`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Real sockets: the test binding installs a mock HttpClient that answers
  // every request with an empty 400, which never reaches a listener.
  HttpOverrides.global = null;

  late Directory identityRoot;
  late SyncDeviceIdentity identity;

  setUpAll(() async {
    identityRoot = await Directory.systemTemp.createTemp(
      'sync-remote-header-identity-',
    );
    identity = await SyncDeviceIdentity.loadOrCreate(
      identityRoot,
      fallbackName: 'header',
    );
  });

  tearDownAll(() async {
    try {
      await identityRoot.delete(recursive: true);
    } catch (_) {}
  });

  Future<(_PairRecordingHandler, int)> startServer() async {
    final directory = await Directory.systemTemp.createTemp(
      'sync-remote-header-',
    );
    final handler = _PairRecordingHandler(identity);
    final server = SyncServer(
      identity: identity,
      store: SyncStore(directory),
      handler: handler,
    );
    addTearDown(() async {
      await server.stop();
      try {
        await directory.delete(recursive: true);
      } catch (_) {}
    });
    final port = await server.start(address: '127.0.0.1', requestedPort: 0);
    expect(port, greaterThan(0));
    return (handler, port);
  }

  /// One `/pair` request that reaches the handler. [remote] is the marker a
  /// remote session's client puts on every request.
  Future<void> postPair(int port, {required bool remote}) async {
    final client = SyncClient.directClient(identity.buildContext())
      ..badCertificateCallback = (_, _, _) => true;
    addTearDown(() => client.close(force: true));
    final request = await client.postUrl(
      Uri.parse('https://127.0.0.1:$port/pair'),
    );
    if (remote) request.headers.set(SyncServer.remoteHeader, '1');
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'pin': '123456',
        'deviceId': identity.deviceId,
        'deviceName': 'initiator',
        'platform': 'test',
        'certPem': identity.certPem,
        'listenPort': 41000,
      }),
    );
    final response = await request.close().timeout(const Duration(seconds: 10));
    await response.drain<void>().timeout(const Duration(seconds: 10));
    expect(response.statusCode, HttpStatus.ok);
  }

  test('a relayed pairing request reports no initiator address', () async {
    final (handler, port) = await startServer();
    await postPair(port, remote: true);
    expect(
      handler.initiatorHosts,
      [null],
      reason:
          'a relayed connection comes from this device\'s own loopback; '
          'remembering it would store an endpoint that dials this device',
    );
  });

  test('a LAN pairing request still reports the caller address', () async {
    final (handler, port) = await startServer();
    await postPair(port, remote: false);
    expect(handler.initiatorHosts, [
      '127.0.0.1',
    ], reason: 'the marker is the only thing that suppresses the source hint');
  });
}

/// A handler that records the address the `/pair` route passed down. Every
/// other route is unimplemented: this test only needs the one face.
class _PairRecordingHandler implements SyncServerHandler {
  _PairRecordingHandler(this.identity);

  final SyncDeviceIdentity identity;

  /// One entry per pairing request that reached the handler: the initiator's
  /// source address, or null when the request carried the remote marker.
  final List<String?> initiatorHosts = <String?>[];

  @override
  Future<SyncPairAnswer?> handlePair(
    SyncPairRequest request,
    String? initiatorHost, {
    required SyncAdmission admission,
  }) async {
    initiatorHosts.add(initiatorHost);
    return SyncPairAnswer(
      deviceId: identity.deviceId,
      deviceName: 'responder',
      platform: 'test',
      certPem: identity.certPem,
      secret: 'pair-secret',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
