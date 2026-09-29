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

  group('isVirtualInterfaceName', () {
    test('excludes virtual adapters, tunnels and cellular interfaces', () {
      expect(isVirtualInterfaceName('VMware Network Adapter VMnet1'), isTrue);
      expect(isVirtualInterfaceName('VirtualBox Host-Only Network'), isTrue);
      expect(isVirtualInterfaceName('vEthernet (Default Switch)'), isTrue);
      expect(isVirtualInterfaceName('vEthernet (WSL)'), isTrue);
      expect(isVirtualInterfaceName('docker0'), isTrue);
      expect(isVirtualInterfaceName('utun3'), isTrue);
      expect(isVirtualInterfaceName('awdl0'), isTrue);
      expect(isVirtualInterfaceName('rmnet_data0'), isTrue);
      expect(isVirtualInterfaceName('clat4'), isTrue);
      expect(isVirtualInterfaceName('pdp_ip0'), isTrue);
      expect(isVirtualInterfaceName('Tailscale'), isTrue);
      expect(isVirtualInterfaceName('ZeroTier One [7f7f]'), isTrue);
    });

    test('keeps the interfaces a peer actually dials', () {
      expect(isVirtualInterfaceName('wlan0'), isFalse);
      expect(isVirtualInterfaceName('WLAN'), isFalse);
      expect(isVirtualInterfaceName('eth0'), isFalse);
      expect(isVirtualInterfaceName('Ethernet'), isFalse);
      expect(isVirtualInterfaceName('en0'), isFalse);
      expect(isVirtualInterfaceName('Wi-Fi'), isFalse);
      expect(isVirtualInterfaceName('以太网'), isFalse);
      // A tethered peer dials these: an iPhone's personal hotspot, Windows'
      // mobile hotspot adapter and an Android soft AP.
      expect(isVirtualInterfaceName('bridge100'), isFalse);
      expect(isVirtualInterfaceName('Local Area Connection* 12'), isFalse);
      expect(isVirtualInterfaceName('swlan0'), isFalse);
    });
  });

  group('selectLanCandidates', () {
    test('drops virtual interfaces and keeps interface order', () {
      expect(
        selectLanCandidates([
          (name: 'VMware Network Adapter VMnet1', address: '192.168.56.1'),
          (name: 'wlan0', address: '192.168.1.5'),
          (name: 'rmnet_data0', address: '10.20.30.40'),
          (name: 'eth0', address: '10.0.0.3'),
        ]),
        [
          (name: 'wlan0', address: '192.168.1.5'),
          (name: 'eth0', address: '10.0.0.3'),
        ],
      );
    });

    test('caps the advertised list', () {
      expect(
        selectLanCandidates([
          for (var i = 0; i < 6; i++)
            (name: 'wlan$i', address: '192.168.1.${i + 1}'),
        ]).length,
        kMaxLanCandidates,
      );
    });
  });

  group('sameIpv4Subnet', () {
    test('matches on the first three octets', () {
      expect(sameIpv4Subnet('192.168.1.5', '192.168.1.200'), isTrue);
      expect(sameIpv4Subnet('192.168.1.5', '192.168.1.5'), isTrue);
      expect(sameIpv4Subnet('192.168.1.5', '192.168.2.5'), isFalse);
      expect(
        sameIpv4Subnet('172.16.0.1', '172.16.1.1'),
        isFalse,
        reason: 'a /24 is the unit, not a /16',
      );
    });

    test('anything that is not an IPv4 literal is never the same subnet', () {
      expect(sameIpv4Subnet('fe80::1', 'fe80::2'), isFalse);
      expect(sameIpv4Subnet('fe80::1', '192.168.1.5'), isFalse);
      expect(sameIpv4Subnet('192.168.1.5', 'fe80::1'), isFalse);
      expect(sameIpv4Subnet('', ''), isFalse);
      expect(sameIpv4Subnet('192.168.1.5', '192.168.1'), isFalse);
      expect(sameIpv4Subnet('192.168.1.5', '192.168.1.256'), isFalse);
    });

    test('a padded octet is not the literal it looks like', () {
      expect(sameIpv4Subnet('10.168.1.5', '010.168.1.5'), isFalse);
      expect(sameIpv4Subnet('10.168.1.5', '+10.168.1.5'), isFalse);
    });
  });

  group('normalizeHost', () {
    test('reduces an IPv4-mapped literal to its IPv4 form', () {
      // What a dual-stack listener reports for an IPv4 caller.
      expect(normalizeHost('::ffff:127.0.0.1'), '127.0.0.1');
      expect(normalizeHost('::ffff:192.168.1.23'), '192.168.1.23');
    });

    test('strips the brackets a URI or a label wears', () {
      expect(normalizeHost('[fd00::1]'), 'fd00::1');
      expect(normalizeHost(' [2001:db8::5] '), '2001:db8::5');
      expect(normalizeHost('192.168.1.5'), '192.168.1.5');
    });

    test('leaves anything else untouched', () {
      expect(normalizeHost('fd00::a1b2'), 'fd00::a1b2');
      expect(normalizeHost('fe80::1%eth0'), 'fe80::1%eth0');
      expect(normalizeHost('not-an-address'), 'not-an-address');
      expect(normalizeHost(''), '');
    });
  });

  group('uriHost', () {
    test('brackets an IPv6 literal and nothing else', () {
      expect(uriHost('fd00::1'), '[fd00::1]');
      expect(uriHost('2001:db8:1234::9'), '[2001:db8:1234::9]');
      expect(uriHost('192.168.1.5'), '192.168.1.5');
      expect(uriHost('127.0.0.1'), '127.0.0.1');
    });

    test('the bracketed form actually parses as a URI', () {
      final uri = Uri.parse('https://${uriHost('fd00::1')}:9527/pair');
      expect(uri.host, 'fd00::1');
      expect(uri.port, 9527);
    });
  });

  group('formatHostPort', () {
    test('is the human and QR form of an endpoint', () {
      expect(formatHostPort('192.168.1.7', 9527), '192.168.1.7:9527');
      expect(formatHostPort('fd00::1', 9527), '[fd00::1]:9527');
    });

    test('round-trips through the payload split rule', () {
      // The QR parser splits on the last colon; the bracket is what keeps an
      // IPv6 literal's own colons out of the port's way.
      final formatted = formatHostPort('2001:db8:1234:5678::9', 41000);
      final split = formatted.lastIndexOf(':');
      expect(formatted.substring(0, split), '[2001:db8:1234:5678::9]');
      expect(int.parse(formatted.substring(split + 1)), 41000);
    });
  });
}
