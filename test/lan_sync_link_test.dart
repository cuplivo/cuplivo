import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/sync/lan_sync_link.dart';

void main() {
  group('buildLanSyncLink / parseLanSyncLink', () {
    test('round-trips a single host, port and pin', () {
      final link = buildLanSyncLink(
        hosts: const ['192.168.1.5'],
        port: 9527,
        pin: '1234',
      );
      final parsed = parseLanSyncLink(link);
      expect(parsed, isNotNull);
      expect(parsed!.hosts, ['192.168.1.5']);
      expect(parsed.port, 9527);
      expect(parsed.pin, '1234');
    });

    test('preserves multiple hosts in order and dedupes repeats', () {
      final link = buildLanSyncLink(
        hosts: const ['192.168.1.5', '10.0.0.3', '192.168.1.5'],
        port: 9527,
        pin: '0001',
      );
      final parsed = parseLanSyncLink(link);
      expect(parsed!.hosts, ['192.168.1.5', '10.0.0.3']);
    });

    test('supports IPv6 hosts', () {
      final link = buildLanSyncLink(
        hosts: const ['fe80::1', '2001:db8::2'],
        port: 9527,
        pin: '9999',
      );
      final parsed = parseLanSyncLink(link);
      expect(parsed!.hosts, ['fe80::1', '2001:db8::2']);
    });

    test('trims surrounding whitespace', () {
      final link = buildLanSyncLink(
        hosts: const ['192.168.1.5'],
        port: 9527,
        pin: '1234',
      );
      expect(parseLanSyncLink('  $link\n'), isNotNull);
    });

    test('rejects foreign or malformed payloads', () {
      expect(parseLanSyncLink(''), isNull);
      expect(parseLanSyncLink('https://example.com'), isNull);
      expect(parseLanSyncLink('ai-provider:v1:{}'), isNull);
      expect(parseLanSyncLink('${lanSyncLinkPrefix}not json'), isNull);
      expect(parseLanSyncLink('$lanSyncLinkPrefix[1,2,3]'), isNull);
      expect(parseLanSyncLink('$lanSyncLinkPrefix{"hosts":[]}'), isNull);
      expect(
        parseLanSyncLink(
          '$lanSyncLinkPrefix{"hosts":[1,2],"port":9527,"pin":"1234"}',
        ),
        isNull,
      );
      expect(
        parseLanSyncLink(
          buildLanSyncLink(hosts: const ['1.2.3.4'], port: 0, pin: '1234'),
        ),
        isNull,
      );
      expect(
        parseLanSyncLink(
          buildLanSyncLink(hosts: const ['1.2.3.4'], port: 70000, pin: '1234'),
        ),
        isNull,
      );
      expect(
        parseLanSyncLink(
          buildLanSyncLink(hosts: const ['1.2.3.4'], port: 9527, pin: ''),
        ),
        isNull,
      );
    });
  });
}
