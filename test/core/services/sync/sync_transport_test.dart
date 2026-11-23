import 'dart:io';

import 'package:Cuplivo/core/services/sync/sync_transport.dart';
import 'package:Cuplivo/core/services/sync/tailcat_remote_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The seam between LAN sync and the tailcat tunnel (ADR-0020, decisions 3 and
/// 7): a remote endpoint is a `tcat:<address>` token in the endpoint vocabulary
/// the LAN path already has, and only the sync client's dial path treats it
/// differently.
void main() {
  // Mixed case on purpose: a tailcat address is base64url and case-sensitive,
  // while `Uri.host` lowercases what it holds — the transport is where that
  // difference is reconciled.
  const address = 'AbCdEf0123456789AbCdEf0123456789';

  group('the tcat: endpoint marker', () {
    test('names the address and round-trips it', () {
      expect(tailcatHost('AbC'), 'tcat:AbC');
      expect(isTailcatEndpointHost('tcat:AbC'), isTrue);
      expect(tailcatAddressFromHost('tcat:AbC'), 'AbC');
      expect(tailcatAddressFromHost(tailcatHost(address)), address);
    });

    test('a network host is not a remote endpoint', () {
      for (final host in [
        '127.0.0.1',
        '192.168.1.5',
        'fd00::1',
        'localhost',
        'tcat',
        '',
        // The marker only counts as a prefix, so a LAN host that merely
        // contains it stays a LAN host.
        'host-tcat:abc',
      ]) {
        expect(isTailcatEndpointHost(host), isFalse, reason: host);
        expect(tailcatAddressFromHost(host), isNull, reason: host);
      }
    });
  });

  group('endpointPortForHost', () {
    test('a tailcat host always carries the remote port', () {
      // The tunnel is addressed by the address, not by a per-device listener
      // port: remembering the peer's LAN port here would only create a second
      // endpoint for the same address.
      expect(
        endpointPortForHost(tailcatHost(address), 41000),
        kTailcatRemotePort,
      );
      expect(endpointPortForHost(tailcatHost(address), 1), 9527);
      expect(kTailcatRemotePort, 9527);
    });

    test('a LAN host keeps the port it advertised', () {
      expect(endpointPortForHost('192.168.1.5', 41000), 41000);
      expect(endpointPortForHost('127.0.0.1', 9527), 9527);
      expect(endpointPortForHost('fd00::1', 1), 1);
    });
  });

  group('redactEndpointHost', () {
    test('a tailcat endpoint never names its address', () {
      final redacted = redactEndpointHost(tailcatHost(address));
      expect(redacted, isNot(contains(address)));
      expect(redacted, contains('remote'));
    });

    test('a LAN host is its own diagnostic name', () {
      expect(redactEndpointHost('192.168.1.5'), '192.168.1.5');
    });
  });

  group('redactEndpointText', () {
    test('scrubs the endpoint form wherever it appears in a line', () {
      final text = 'sync: dialling back tcat:$address:9527 failed';
      final redacted = redactEndpointText(text);
      expect(redacted, isNot(contains(address)));
      expect(redacted, contains('tcat:remote'));
    });

    test('scrubs the address when a URI names it as the host', () {
      // `HttpException.toString()` appends `uri = <request uri>`, and a sync
      // request over a tunnel is `https://<address>:9527/sync/...`.
      final text =
          'HttpException: Connection closed before full header was received, '
          'uri = https://$address:9527/sync/hello';
      final redacted = redactEndpointText(text);
      expect(redacted, isNot(contains(address)));
      expect(redacted, contains('https://<redacted>:9527'));
    });

    test('leaves network text and its own output unchanged', () {
      const lan = 'sync: 192.168.1.5:41000 timed out after 5s';
      expect(redactEndpointText(lan), lan);
      expect(redactEndpointText('tcat:remote'), 'tcat:remote');

      final once = redactEndpointText(
        'tcat:$address and https://$address:9527',
      );
      expect(redactEndpointText(once), once);
    });
  });

  group('looksLikeTailcatAddress', () {
    test('accepts base64url-shaped address text', () {
      expect(looksLikeTailcatAddress(address), isTrue);
      // The full base64url alphabet, padding and the URI-safe extras.
      expect(looksLikeTailcatAddress('AbC_-1234567890abcdef'), isTrue);
      expect(looksLikeTailcatAddress('a' * 16), isTrue);
      expect(looksLikeTailcatAddress('a' * 2048), isTrue);
    });

    test('rejects what cannot be a URI host or is obviously truncated', () {
      expect(looksLikeTailcatAddress(''), isFalse);
      expect(looksLikeTailcatAddress('   '), isFalse);
      expect(looksLikeTailcatAddress('short'), isFalse);
      expect(looksLikeTailcatAddress('a' * 15), isFalse);
      expect(looksLikeTailcatAddress('a' * 2049), isFalse);
      expect(looksLikeTailcatAddress('$address/any'), isFalse);
      expect(looksLikeTailcatAddress(tailcatHost(address)), isFalse);
      expect(looksLikeTailcatAddress('$address@host'), isFalse);
      expect(looksLikeTailcatAddress('$address%20'), isFalse);
    });

    test('pasted whitespace is normalised before the shape check', () {
      // Documented behaviour: phone keyboards and chat clients insert
      // whitespace mid-paste, and none of it is part of the encoding, so it is
      // stripped rather than rejected.
      expect(normalizeTailcatAddress(' $address\n'), address);
      expect(looksLikeTailcatAddress(' $address\n'), isTrue);
    });
  });

  group('TailcatClientTransport', () {
    test(
      'a tcat endpoint becomes a lowercased URI host on the remote port',
      () {
        final transport = TailcatClientTransport();
        final target = transport.uriEndpointFor(
          tailcatHost(address),
          // The stored port is not used for a tunnel: the address is the dial.
          41000,
        );
        expect(target.port, kTailcatRemotePort);
        expect(target.host, address.toLowerCase());
        // The inverse mapping is what the HTTP client's lowercased URI host is
        // resolved back to before the tunnel is dialed.
        expect(transport.remoteAddressForUriHost(target.host), address);
      },
    );

    test('the same address always maps to the same URI host', () {
      final transport = TailcatClientTransport();
      final first = transport.uriEndpointFor(tailcatHost(address), 1);
      final second = transport.uriEndpointFor(tailcatHost(address), 2);
      expect(second.host, first.host);
      expect(transport.remoteAddressForUriHost(second.host), address);
    });

    test('addresses differing only in case do not collapse into one host', () {
      final transport = TailcatClientTransport();
      const lower = 'abcdef0123456789abcdef';
      const upper = 'ABCDEF0123456789ABCDEF';
      final lowerTarget = transport.uriEndpointFor(tailcatHost(lower), 9527);
      final upperTarget = transport.uriEndpointFor(tailcatHost(upper), 9527);

      expect(lowerTarget.host, lower);
      expect(
        upperTarget.host,
        isNot(lowerTarget.host),
        reason: 'Uri.host lowercases, so the second address needs its own host',
      );
      expect(transport.remoteAddressForUriHost(lowerTarget.host), lower);
      expect(transport.remoteAddressForUriHost(upperTarget.host), upper);
    });

    test('a LAN endpoint is left exactly as it was', () {
      final transport = TailcatClientTransport();
      expect(transport.uriEndpointFor('192.168.1.5', 41000), (
        host: '192.168.1.5',
        port: 41000,
      ));
      expect(transport.uriEndpointFor('fd00::1', 9527), (
        host: 'fd00::1',
        port: 9527,
      ));
      expect(transport.remoteAddressForUriHost('192.168.1.5'), isNull);
    });

    test('the tunnelling factory is a function', () {
      // Not invoked: dialing a tunnel needs the native library, which a unit
      // test does not load. The contract under test is that the sync client can
      // install it on a remote client at all.
      final transport = TailcatClientTransport();
      expect(
        transport.connectionFactory,
        isA<Future<ConnectionTask<Socket>> Function(Uri, String?, int?)>(),
      );
    });

    test(
      'a URI this transport did not build is refused, not dialled',
      () async {
        // The only such URI reaches the factory through a redirect or a request
        // that outlived its transport. A plain-TCP fallback would dial whatever
        // host it named; the tunnel is the only route a remote client has.
        final transport = TailcatClientTransport();
        await expectLater(
          transport.connectionFactory(
            Uri.parse('https://192.168.1.5:9527/sync/ping'),
            null,
            null,
          ),
          throwsA(
            isA<SocketException>().having(
              (error) => error.message,
              'message',
              'remote endpoint is not resolved',
            ),
          ),
        );
      },
    );

    test('closing the transport forgets the URI-host mapping', () async {
      // Remote sync stopping closes every tunnel, and a later start registers
      // fresh mappings: a stale one would name a closed client.
      final transport = TailcatClientTransport();
      final target = transport.uriEndpointFor(tailcatHost(address), 9527);
      expect(transport.remoteAddressForUriHost(target.host), address);

      await transport.close();

      expect(transport.remoteAddressForUriHost(target.host), isNull);
      expect(
        transport.uriEndpointFor(tailcatHost(address), 9527).host,
        target.host,
        reason: 'the same address maps to the same URI host again',
      );
    });
  });
}
