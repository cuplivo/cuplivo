import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/harness_tailcat_endpoint.dart';

/// A shape-valid address: the tests exercise parsing, not the tailcat binary's
/// checksum, so a synthetic capability is enough and cannot be confused with a
/// real one.
const String _address =
    'tcAPpXUQeEXAMPLEaddressEXAMPLEaddressEXAMPLEaddressEXAMPLE00';
const String _address2 =
    'tcZq7rM2nEXAMPLEaddress2EXAMPLEaddress2EXAMPLEaddress2EXAMPL';

void main() {
  group('looksLikeHarnessTailcatAddress', () {
    test('accepts the shape of a plugin address', () {
      expect(looksLikeHarnessTailcatAddress(_address), isTrue);
      expect(looksLikeHarnessTailcatAddress(_address2), isTrue);
      // Tailcat's encoding is base64url-ish; symbols outside it are not.
      expect(looksLikeHarnessTailcatAddress('tc${'a-b_c.d~+=' * 4}'), isTrue);
    });

    test('rejects text that cannot be an address', () {
      expect(looksLikeHarnessTailcatAddress(''), isFalse);
      expect(looksLikeHarnessTailcatAddress('tc'), isFalse);
      expect(
        looksLikeHarnessTailcatAddress('tc${'a' * 10}'),
        isFalse,
        reason: 'shorter than the floor',
      );
      expect(
        looksLikeHarnessTailcatAddress('tc${'a' * 2049}'),
        isFalse,
        reason: 'longer than any real address',
      );
      expect(looksLikeHarnessTailcatAddress('xyz${'a' * 40}'), isFalse);
      expect(looksLikeHarnessTailcatAddress('tc${'a' * 20} '), isFalse);
      expect(looksLikeHarnessTailcatAddress('tc${'a b' * 20}'), isFalse);
      expect(looksLikeHarnessTailcatAddress('tailcat:tc${'a' * 40}'), isFalse);
    });
  });

  group('parseHarnessTailcatInput', () {
    test('a bare address keeps the plugin default port', () {
      final endpoint = parseHarnessTailcatInput(_address);

      expect(endpoint, isNotNull);
      expect(endpoint!.address, _address);
      expect(endpoint.port, kHarnessTailcatDefaultPort);
      expect(endpoint.port, 13080);
    });

    test('whitespace around and inside a paste is tolerated', () {
      expect(parseHarnessTailcatInput('  $_address \n')!.address, _address);
      expect(parseHarnessTailcatInput('\n\n$_address\n\n')!.port, 13080);
      expect(
        parseHarnessTailcatInput('$_address\n$_address2')!.address,
        _address,
      );
    });

    test('the plugin pairing command yields address and peer port', () {
      final endpoint = parseHarnessTailcatInput(
        'tailcat forward $_address 18080:13080',
      );

      expect(endpoint!.address, _address);
      expect(endpoint.port, 13080);
    });

    test('a custom port mapping overrides the default', () {
      expect(
        parseHarnessTailcatInput('tailcat forward $_address 18080:15000')!.port,
        15000,
      );
      // local:host:remote is the exit-node form of the same argument.
      expect(
        parseHarnessTailcatInput(
          'tailcat forward $_address 18080:192.168.1.10:15000',
        )!.port,
        15000,
      );
      // A single port is both ends, like tailcat itself treats it.
      expect(
        parseHarnessTailcatInput('tailcat forward $_address 18080')!.port,
        18080,
      );
    });

    test('flags before and after the address do not confuse the parse', () {
      expect(
        parseHarnessTailcatInput(
          'tailcat forward --bind=0.0.0.0 $_address 18080:13080',
        )!.address,
        _address,
      );
      expect(
        parseHarnessTailcatInput(
          'tailcat forward --key=client-default $_address 18080:14000',
        )!.port,
        14000,
      );
    });

    test('quotes around the address are stripped', () {
      for (final quote in <String>['"', "'"]) {
        final endpoint = parseHarnessTailcatInput(
          'tailcat forward $quote$_address$quote 18080:13080',
        );
        expect(endpoint!.address, _address);
      }
    });

    test('a command that names no port keeps the default', () {
      final endpoint = parseHarnessTailcatInput(
        'tailcat forward --key=client-default $_address',
      );
      expect(endpoint!.port, 13080);
    });

    test('a mapping outside the TCP range falls back to the default', () {
      final endpoint = parseHarnessTailcatInput(
        'tailcat forward $_address 18080:70000',
      );
      expect(endpoint!.port, 13080);
    });

    test('text without an address is rejected instead of dialed', () {
      expect(parseHarnessTailcatInput(''), isNull);
      expect(parseHarnessTailcatInput('   '), isNull);
      expect(parseHarnessTailcatInput('tailcat forward'), isNull);
      expect(parseHarnessTailcatInput('not-an-address'), isNull);
      expect(parseHarnessTailcatInput('https://dsh.example.com'), isNull);
      expect(
        parseHarnessTailcatInput('tailcat forward tcgarbage 18080:13080'),
        isNull,
      );
    });

    test('the endpoint never prints its address', () {
      final endpoint = parseHarnessTailcatInput(_address)!;
      expect(endpoint.toString(), isNot(contains(_address)));
      expect(endpoint.toString(), contains('13080'));
      expect(endpoint, HarnessTailcatEndpoint(address: _address, port: 13080));
      expect(
        endpoint.hashCode,
        HarnessTailcatEndpoint(address: _address, port: 13080).hashCode,
      );
      expect(
        endpoint,
        isNot(HarnessTailcatEndpoint(address: _address2, port: 13080)),
      );
      expect(
        endpoint,
        isNot(HarnessTailcatEndpoint(address: _address, port: 14000)),
      );
    });
  });

  group('redactHarnessTailcatAddresses', () {
    test('hides every address-shaped token', () {
      final redacted = redactHarnessTailcatAddresses(
        'dial $_address failed, again $_address2',
      );

      expect(redacted, isNot(contains(_address)));
      expect(redacted, isNot(contains(_address2)));
      expect(redacted, contains('tc<redacted>'));
      expect(redacted, contains('dial'));
    });

    test('leaves text without an address alone', () {
      expect(redactHarnessTailcatAddresses('plain error'), 'plain error');
      expect(redactHarnessTailcatAddresses(''), '');
    });
  });
}
