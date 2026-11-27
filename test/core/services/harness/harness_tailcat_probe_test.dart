import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/harness/harness_connection_probe.dart';
import 'package:Cuplivo/core/services/harness/harness_tailcat_dialer.dart';
import 'package:Cuplivo/core/services/harness/harness_tailcat_probe.dart';
import 'package:Cuplivo/core/services/harness/harness_tailcat_tunnels.dart';

const String _address =
    'tcAPpXUQeEXAMPLEaddressEXAMPLEaddressEXAMPLEaddressEXAMPLE00';

class _FakeDialer implements HarnessTailcatDialer {
  _FakeDialer(this.targetPort, {this.failure});

  final int targetPort;
  final Object? failure;
  final List<int> dialedPorts = <int>[];

  @override
  Future<Socket> connect(int port) async {
    dialedPorts.add(port);
    final failure = this.failure;
    if (failure != null) throw failure;
    return Socket.connect(InternetAddress.loopbackIPv4, targetPort);
  }

  @override
  Future<void> close() async {}
}

/// An HTTP server that behaves like the plugin's door: a bare request is
/// answered with 303 and the WebUI cookie, the replay with the index page.
class _FakeDoor {
  _FakeDoor._(this._server, this._behaviour);

  final HttpServer _server;
  final String _behaviour;

  int get port => _server.port;
  final List<String?> seenCookies = <String?>[];

  static Future<_FakeDoor> start({String behaviour = 'claim'}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final door = _FakeDoor._(server, behaviour);
    server.listen(door._handle);
    return door;
  }

  Future<void> _handle(HttpRequest request) async {
    final cookie = request.headers.value(HttpHeaders.cookieHeader);
    seenCookies.add(cookie);
    final response = request.response;
    if (_behaviour == 'hang') {
      // Keep the response open: the point is an exchange that never answers.
      return;
    }
    switch (_behaviour) {
      case 'direct':
        response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write('<html><title>DeepSeek Harness</title></html>');
      case 'rejected':
        response.statusCode = HttpStatus.unauthorized;
      case 'broken':
        response.statusCode = HttpStatus.internalServerError;
      case 'claim':
        if (cookie == null || !cookie.contains('dsh-door=')) {
          response
            ..statusCode = HttpStatus.seeOther
            ..headers.add(
              HttpHeaders.setCookieHeader,
              'dsh-door=granted; Path=/; HttpOnly',
            )
            ..headers.set(HttpHeaders.locationHeader, './');
        } else {
          response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.html
            ..write('<html><title>DeepSeek Harness</title></html>');
        }
      default:
        response.statusCode = HttpStatus.internalServerError;
    }
    await response.close();
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  late List<_FakeDoor> doors;
  late List<_FakeDialer> dialers;

  Future<HarnessTailcatTunnels> tunnelsFor(_FakeDoor door) async {
    final dialer = _FakeDialer(door.port);
    dialers.add(dialer);
    final tunnels = HarnessTailcatTunnels(dialer: (_) => dialer);
    addTearDown(tunnels.closeAll);
    return tunnels;
  }

  Future<_FakeDoor> door({String behaviour = 'claim'}) async {
    final started = await _FakeDoor.start(behaviour: behaviour);
    doors.add(started);
    return started;
  }

  setUp(() {
    doors = <_FakeDoor>[];
    dialers = <_FakeDialer>[];
  });

  tearDown(() async {
    for (final door in doors) {
      await door.close();
    }
  });

  group('HarnessTailcatProbe', () {
    test('a claimed page loads through the tunnel', () async {
      final fake = await door();
      final probe = HarnessTailcatProbe(tunnels: await tunnelsFor(fake));

      final result = await probe.check(_address);

      expect(result.isConnected, isTrue);
      expect(result.failure, isNull);
      expect(dialers.single.dialedPorts, <int>[13080]);
      expect(fake.seenCookies, hasLength(2));
      expect(fake.seenCookies.first, isNull);
      expect(fake.seenCookies.last, contains('dsh-door=granted'));
    });

    test('a door that serves the index directly counts as connected', () async {
      final fake = await door(behaviour: 'direct');
      final probe = HarnessTailcatProbe(tunnels: await tunnelsFor(fake));

      final result = await probe.check(_address);

      expect(result.isConnected, isTrue);
      expect(fake.seenCookies, hasLength(1));
    });

    test(
      'text that cannot be an address fails before any tunnel work',
      () async {
        final fake = await door();
        final tunnels = await tunnelsFor(fake);
        final probe = HarnessTailcatProbe(tunnels: tunnels);

        final result = await probe.check('not-an-address');

        expect(result.failure, HarnessConnectionFailure.invalidTailcatAddress);
        expect(dialers.single.dialedPorts, isEmpty);
        expect(tunnels.localUriFor(_address), isNull);
      },
    );

    test('the stored peer port is dialed for a bare saved address', () async {
      final fake = await door();
      final probe = HarnessTailcatProbe(tunnels: await tunnelsFor(fake));

      final result = await probe.check(_address, remotePort: 14000);

      expect(result.isConnected, isTrue);
      expect(dialers.single.dialedPorts, <int>[14000]);
    });

    test(
      'a pasted pairing command contributes its port when none is stored',
      () async {
        final fake = await door();
        final probe = HarnessTailcatProbe(tunnels: await tunnelsFor(fake));

        final result = await probe.check(
          'tailcat forward $_address 18080:15000',
        );

        expect(result.isConnected, isTrue);
        expect(dialers.single.dialedPorts, <int>[15000]);
      },
    );

    test('a rejecting door reports rejected', () async {
      final fake = await door(behaviour: 'rejected');
      final probe = HarnessTailcatProbe(tunnels: await tunnelsFor(fake));

      final result = await probe.check(_address);

      expect(result.failure, HarnessConnectionFailure.rejected);
    });

    test('a broken door reports its API unavailable', () async {
      final fake = await door(behaviour: 'broken');
      final probe = HarnessTailcatProbe(tunnels: await tunnelsFor(fake));

      final result = await probe.check(_address);

      expect(result.failure, HarnessConnectionFailure.apiUnavailable);
    });

    test('a dial that fails reports the tunnel as unavailable', () async {
      final fake = await door();
      final tunnels = HarnessTailcatTunnels(
        dialer: (_) =>
            _FakeDialer(fake.port, failure: const SocketException('down')),
      );
      addTearDown(tunnels.closeAll);
      final probe = HarnessTailcatProbe(tunnels: tunnels);

      final result = await probe.check(_address);

      expect(result.failure, HarnessConnectionFailure.tailcatUnavailable);
    });

    test(
      'a build without a tailcat client reports the platform unsupported',
      () async {
        final tunnels = HarnessTailcatTunnels(
          dialer: (_) => throw const HarnessTailcatTunnelException(
            HarnessTailcatTunnelFailure.unsupportedPlatform,
          ),
        );
        addTearDown(tunnels.closeAll);
        final probe = HarnessTailcatProbe(tunnels: tunnels);

        final result = await probe.check(_address);

        expect(result.failure, HarnessConnectionFailure.tailcatUnsupported);
      },
    );

    test('a door that never answers is bounded by the probe timeout', () async {
      final fake = await door(behaviour: 'hang');
      final probe = HarnessTailcatProbe(
        tunnels: await tunnelsFor(fake),
        timeout: const Duration(milliseconds: 80),
      );

      final result = await probe.check(_address);

      expect(result.failure, HarnessConnectionFailure.tailcatUnavailable);
    });
  });
}
