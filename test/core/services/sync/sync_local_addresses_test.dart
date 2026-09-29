import 'package:Cuplivo/core/services/sync/sync_local_addresses.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('filterLanAddresses', () {
    test('keeps unicast IPv4 in input order, public addresses included', () {
      expect(
        filterLanAddresses([
          (name: 'wlan0', address: '183.173.213.34'),
          (name: 'wlan0', address: '192.168.1.5'),
          (name: 'eth0', address: '10.0.0.3'),
        ]),
        [
          (name: 'wlan0', address: '183.173.213.34'),
          (name: 'wlan0', address: '192.168.1.5'),
          (name: 'eth0', address: '10.0.0.3'),
        ],
      );
    });

    test('keeps a campus network public address (the v4 regression)', () {
      // A campus network hands out globally routable IPv4 directly, with no NAT
      // in between: filtering to RFC1918 alone left such a device advertising
      // no address at all, while its peer on the same segment could reach it.
      expect(filterLanAddresses([(name: 'wlan0', address: '183.173.213.34')]), [
        (name: 'wlan0', address: '183.173.213.34'),
      ]);
    });

    test('drops loopback, link-local, multicast, reserved and IPv6', () {
      expect(
        filterLanAddresses([
          (name: 'lo', address: '127.0.0.1'),
          (name: 'en0', address: '169.254.10.1'),
          (name: 'en0', address: '224.0.0.5'),
          (name: 'en0', address: '255.255.255.255'),
          (name: 'en0', address: '0.0.0.0'),
          (name: 'en0', address: 'fe80::1'),
          (name: 'en0', address: '::1'),
          (name: 'en0', address: '2001:da8::1'),
        ]),
        isEmpty,
      );
    });

    test('deduplicates by address, keeping the first interface', () {
      expect(
        filterLanAddresses([
          (name: 'wlan0', address: '192.168.1.5'),
          (name: 'eth0', address: '192.168.1.5'),
          (name: 'eth0', address: '10.0.0.3'),
        ]),
        [
          (name: 'wlan0', address: '192.168.1.5'),
          (name: 'eth0', address: '10.0.0.3'),
        ],
      );
    });

    test('ignores unparseable entries', () {
      expect(
        filterLanAddresses([
          (name: 'en0', address: ''),
          (name: 'en0', address: 'not-an-ip'),
          (name: 'en0', address: '192.168.1.5'),
        ]),
        [(name: 'en0', address: '192.168.1.5')],
      );
    });
  });
}
