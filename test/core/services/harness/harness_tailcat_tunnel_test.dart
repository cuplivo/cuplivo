import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/harness/harness_tailcat_dialer.dart';
import 'package:Cuplivo/core/services/harness/harness_tailcat_tunnel.dart';
import 'package:Cuplivo/core/services/harness/harness_tailcat_tunnels.dart';

/// Shape-valid but synthetic: the tests exercise the local forward, not the
/// tailcat binary, so no real capability is required.
const String _address =
    'tcAPpXUQeEXAMPLEaddressEXAMPLEaddressEXAMPLEaddressEXAMPLE00';
const String _address2 =
    'tcZq7rM2nEXAMPLEaddress2EXAMPLEaddress2EXAMPLEaddress2EXAMPL';

class _FakeDialer implements HarnessTailcatDialer {
  _FakeDialer(this.targetPort);

  final int targetPort;
  Object? failure;
  final List<int> dialedPorts = <int>[];
  bool closed = false;

  int get dialCount => dialedPorts.length;

  @override
  Future<Socket> connect(int port) async {
    dialedPorts.add(port);
    final failure = this.failure;
    if (failure != null) throw failure;
    return Socket.connect(InternetAddress.loopbackIPv4, targetPort);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// A dial that never comes back, to exercise the tunnel's own timeout.
class _HangingDialer implements HarnessTailcatDialer {
  final Completer<Socket> _never = Completer<Socket>();
  bool closed = false;

  @override
  Future<Socket> connect(int port) => _never.future;

  @override
  Future<void> close() async {
    closed = true;
  }
}

Future<HttpServer> _echoServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    await utf8.decoder.bind(request).join();
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.text
      ..write('echo');
    await request.response.close();
  });
  return server;
}

Future<String> _get(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    expect(response.statusCode, HttpStatus.ok);
    return await utf8.decoder.bind(response).join();
  } finally {
    client.close(force: true);
  }
}

/// Waits for the local end of a forwarded connection to be closed by the tunnel.
Future<void> _expectLocalClosed(Socket socket) async {
  final closed = Completer<void>();
  socket.listen(
    (_) {},
    onError: (Object _) {
      if (!closed.isCompleted) closed.complete();
    },
    onDone: () {
      if (!closed.isCompleted) closed.complete();
    },
  );
  await closed.future.timeout(const Duration(seconds: 5));
}

void main() {
  group('HarnessTailcatTunnel', () {
    test(
      'rejects an address that cannot be one before asking for a dialer',
      () async {
        var factoryCalls = 0;
        await expectLater(
          HarnessTailcatTunnel.open(
            'not-an-address',
            dialerFactory: (_) {
              factoryCalls++;
              return _FakeDialer(1);
            },
          ),
          throwsA(
            isA<HarnessTailcatTunnelException>().having(
              (error) => error.failure,
              'failure',
              HarnessTailcatTunnelFailure.invalidAddress,
            ),
          ),
        );
        expect(factoryCalls, 0);
      },
    );

    test('rejects a peer port that is not a TCP port', () async {
      var factoryCalls = 0;
      await expectLater(
        HarnessTailcatTunnel.open(
          _address,
          remotePort: 70000,
          dialerFactory: (_) {
            factoryCalls++;
            return _FakeDialer(1);
          },
        ),
        throwsA(isA<HarnessTailcatTunnelException>()),
      );
      expect(factoryCalls, 0);
    });

    test('serves the peer on a loopback HTTP origin', () async {
      final server = await _echoServer();
      addTearDown(() => server.close(force: true));
      final dialer = _FakeDialer(server.port);
      final tunnel = await HarnessTailcatTunnel.open(
        _address,
        remotePort: 14000,
        dialerFactory: (_) => dialer,
      );
      addTearDown(tunnel.close);

      expect(tunnel.localUri.scheme, 'http');
      expect(tunnel.localUri.host, InternetAddress.loopbackIPv4.address);
      expect(tunnel.localUri.port, greaterThan(0));
      expect(tunnel.remotePort, 14000);
      expect(tunnel.isClosed, isFalse);

      expect(await _get(tunnel.localUri.replace(path: '/')), 'echo');
      expect(dialer.dialedPorts, <int>[14000]);
    });

    test('forwards each local connection on its own peer dial', () async {
      final server = await _echoServer();
      addTearDown(() => server.close(force: true));
      final dialer = _FakeDialer(server.port);
      final tunnel = await HarnessTailcatTunnel.open(
        _address,
        dialerFactory: (_) => dialer,
      );
      addTearDown(tunnel.close);

      final bodies = await Future.wait(<Future<String>>[
        _get(tunnel.localUri.replace(path: '/one')),
        _get(tunnel.localUri.replace(path: '/two')),
        _get(tunnel.localUri.replace(path: '/three')),
      ]);

      expect(bodies, everyElement('echo'));
      expect(dialer.dialCount, 3);
    });

    test(
      'a failed peer dial closes the local connection instead of hanging it',
      () async {
        final dialer = _FakeDialer(1)
          ..failure = const SocketException('peer refused');
        final tunnel = await HarnessTailcatTunnel.open(
          _address,
          dialerFactory: (_) => dialer,
        );
        addTearDown(tunnel.close);

        final local = await Socket.connect(
          InternetAddress.loopbackIPv4,
          tunnel.localUri.port,
        );
        await _expectLocalClosed(local);
        expect(dialer.dialCount, 1);
      },
    );

    test(
      'a peer dial that never answers is cut by the connect timeout',
      () async {
        final dialer = _HangingDialer();
        final tunnel = await HarnessTailcatTunnel.open(
          _address,
          connectTimeout: const Duration(milliseconds: 50),
          dialerFactory: (_) => dialer,
        );
        addTearDown(tunnel.close);

        final local = await Socket.connect(
          InternetAddress.loopbackIPv4,
          tunnel.localUri.port,
        );
        await _expectLocalClosed(local);
      },
    );

    test(
      'close stops accepting, drops live connections and closes the client',
      () async {
        final server = await _echoServer();
        addTearDown(() => server.close(force: true));
        final dialer = _FakeDialer(server.port);
        final tunnel = await HarnessTailcatTunnel.open(
          _address,
          dialerFactory: (_) => dialer,
        );

        await tunnel.close();

        expect(tunnel.isClosed, isTrue);
        expect(dialer.closed, isTrue);
        await expectLater(
          Socket.connect(InternetAddress.loopbackIPv4, tunnel.localUri.port),
          throwsA(isA<SocketException>()),
        );
        // Closing twice is harmless: surfaces unwind from more than one path.
        await tunnel.close();
      },
    );

    test('its description never prints the address', () async {
      final server = await _echoServer();
      addTearDown(() => server.close(force: true));
      final tunnel = await HarnessTailcatTunnel.open(
        _address,
        remotePort: 14000,
        dialerFactory: (_) => _FakeDialer(server.port),
      );
      addTearDown(tunnel.close);

      expect(tunnel.toString(), isNot(contains(_address)));
      expect(tunnel.toString(), contains('14000'));
    });
  });

  group('HarnessTailcatTunnels', () {
    late HttpServer server;

    setUp(() async {
      server = await _echoServer();
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('reuses one tunnel for the same address and port', () async {
      var factoryCalls = 0;
      final dialer = _FakeDialer(server.port);
      final tunnels = HarnessTailcatTunnels(
        dialer: (_) {
          factoryCalls++;
          return dialer;
        },
      );
      addTearDown(tunnels.closeAll);

      final first = await tunnels.ensureOpen(_address, remotePort: 14000);
      final second = await tunnels.ensureOpen(_address, remotePort: 14000);

      expect(first, second);
      expect(factoryCalls, 1);
      expect(tunnels.localUriFor(_address), first);
    });

    test('concurrent opens share one handshake', () async {
      var factoryCalls = 0;
      final tunnels = HarnessTailcatTunnels(
        dialer: (_) {
          factoryCalls++;
          return _FakeDialer(server.port);
        },
      );
      addTearDown(tunnels.closeAll);

      final uris = await Future.wait(<Future<Uri>>[
        tunnels.ensureOpen(_address),
        tunnels.ensureOpen(_address),
      ]);

      expect(uris[0], uris[1]);
      expect(factoryCalls, 1);
    });

    test('a new peer port replaces the old tunnel', () async {
      final dialers = <_FakeDialer>[];
      final tunnels = HarnessTailcatTunnels(
        dialer: (_) {
          final dialer = _FakeDialer(server.port);
          dialers.add(dialer);
          return dialer;
        },
      );
      addTearDown(tunnels.closeAll);

      final first = await tunnels.ensureOpen(_address, remotePort: 13080);
      final second = await tunnels.ensureOpen(_address, remotePort: 14000);

      expect(first, isNot(second));
      expect(dialers, hasLength(2));
      expect(dialers.first.closed, isTrue);
      expect(tunnels.localUriFor(_address), second);
    });

    test(
      'a failed handshake is not cached, so the next try runs again',
      () async {
        var factoryCalls = 0;
        final tunnels = HarnessTailcatTunnels(
          dialer: (_) {
            factoryCalls++;
            if (factoryCalls == 1) throw StateError('native library missing');
            return _FakeDialer(server.port);
          },
        );
        addTearDown(tunnels.closeAll);

        await expectLater(
          tunnels.ensureOpen(_address),
          throwsA(
            isA<HarnessTailcatTunnelException>().having(
              (error) => error.failure,
              'failure',
              HarnessTailcatTunnelFailure.tunnelUnavailable,
            ),
          ),
        );
        expect(tunnels.localUriFor(_address), isNull);

        final uri = await tunnels.ensureOpen(_address);
        expect(uri.scheme, 'http');
        expect(factoryCalls, 2);
      },
    );

    test(
      'prune keeps live tunnels and closes the ones nothing references',
      () async {
        final dialers = <String, _FakeDialer>{};
        final tunnels = HarnessTailcatTunnels(
          dialer: (address) => dialers[address] = _FakeDialer(server.port),
        );
        addTearDown(tunnels.closeAll);

        await tunnels.ensureOpen(_address);
        await tunnels.ensureOpen(_address2);

        await tunnels.prune(<String>{_address});

        expect(tunnels.localUriFor(_address), isNotNull);
        expect(tunnels.localUriFor(_address2), isNull);
        expect(dialers[_address2]!.closed, isTrue);
        expect(dialers[_address]!.closed, isFalse);
      },
    );

    test('prune is a no-op when every address is still referenced', () async {
      final dialer = _FakeDialer(server.port);
      final tunnels = HarnessTailcatTunnels(dialer: (_) => dialer);
      addTearDown(tunnels.closeAll);

      final uri = await tunnels.ensureOpen(_address);
      await tunnels.prune(<String>{_address});

      expect(tunnels.localUriFor(_address), uri);
      expect(dialer.closed, isFalse);
    });

    test('an invalid address is rejected before a dialer is built', () async {
      var factoryCalls = 0;
      final tunnels = HarnessTailcatTunnels(
        dialer: (_) {
          factoryCalls++;
          return _FakeDialer(server.port);
        },
      );
      addTearDown(tunnels.closeAll);

      await expectLater(
        tunnels.ensureOpen('not-an-address'),
        throwsA(
          isA<HarnessTailcatTunnelException>().having(
            (error) => error.failure,
            'failure',
            HarnessTailcatTunnelFailure.invalidAddress,
          ),
        ),
      );
      expect(factoryCalls, 0);
    });

    test('closeAll closes everything and refuses new tunnels', () async {
      final dialer = _FakeDialer(server.port);
      final tunnels = HarnessTailcatTunnels(dialer: (_) => dialer);
      final uri = await tunnels.ensureOpen(_address);
      expect(uri.scheme, 'http');

      await tunnels.closeAll();

      expect(tunnels.localUriFor(_address), isNull);
      expect(dialer.closed, isTrue);
      await expectLater(
        tunnels.ensureOpen(_address),
        throwsA(
          isA<HarnessTailcatTunnelException>().having(
            (error) => error.failure,
            'failure',
            HarnessTailcatTunnelFailure.tunnelUnavailable,
          ),
        ),
      );
    });
  });
}
