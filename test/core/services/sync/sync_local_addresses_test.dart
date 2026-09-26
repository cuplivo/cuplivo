import 'package:Cuplivo/core/services/sync/sync_local_addresses.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('filterLanIpv4s', () {
    test('keeps RFC1918 addresses in input order', () {
      expect(filterLanIpv4s(['192.168.1.5', '10.0.0.3', '172.16.4.9']), [
        '192.168.1.5',
        '10.0.0.3',
        '172.16.4.9',
      ]);
    });

    test('drops loopback, link-local, public, CGNAT and IPv6', () {
      expect(
        filterLanIpv4s([
          '127.0.0.1',
          '169.254.10.1',
          '8.8.8.8',
          '100.64.0.1',
          'fe80::1',
          '::1',
        ]),
        isEmpty,
      );
    });

    test('honours the 172.16/12 boundaries', () {
      expect(filterLanIpv4s(['172.15.255.255']), isEmpty);
      expect(filterLanIpv4s(['172.16.0.0']), ['172.16.0.0']);
      expect(filterLanIpv4s(['172.31.255.255']), ['172.31.255.255']);
      expect(filterLanIpv4s(['172.32.0.1']), isEmpty);
    });

    test('deduplicates while keeping the first occurrence', () {
      expect(filterLanIpv4s(['192.168.1.5', '10.0.0.3', '192.168.1.5']), [
        '192.168.1.5',
        '10.0.0.3',
      ]);
    });

    test('ignores unparseable entries', () {
      expect(filterLanIpv4s(['', 'not-an-ip', '192.168.1.5']), ['192.168.1.5']);
    });
  });
}
