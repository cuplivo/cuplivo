import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/harness/models/dsh_web_ui_link.dart';

/// The creation form validates the pasted WebUI link before it creates a
/// record: the same parser backs the inline error, so a wrong paste must fail
/// here and never reach the (later) protocol client.
void main() {
  group('DshWebUiLink.tryParse', () {
    test('a full printed line keeps the origin and the launch token apart', () {
      final link = DshWebUiLink.tryParse(
        'dsh web: http://192.168.1.20:3080/?token=abc123',
      );
      expect(link, isNotNull);
      expect(link!.baseUrl, 'http://192.168.1.20:3080');
      expect(link.authority, '192.168.1.20:3080');
      expect(link.secure, isFalse);
      expect(link.launchToken, 'abc123');
    });

    test('a bare host:port form is accepted', () {
      final link = DshWebUiLink.tryParse('127.0.0.1:3080/?token=xyz');
      expect(link!.baseUrl, 'http://127.0.0.1:3080');
      expect(link.authority, '127.0.0.1:3080');
      expect(link.launchToken, 'xyz');
    });

    test(
      'a link without a token parses (reconnect with the stored cookie)',
      () {
        final link = DshWebUiLink.tryParse('https://harness.example.dev');
        expect(link!.secure, isTrue);
        expect(link.authority, 'harness.example.dev');
        expect(link.hasLaunchToken, isFalse);
      },
    );

    test('a root path is accepted', () {
      final link = DshWebUiLink.tryParse('http://host:3080/');
      expect(link!.baseUrl, 'http://host:3080');
      expect(link.authority, 'host:3080');
    });

    test('a path prefix is rejected instead of silently dropped', () {
      expect(DshWebUiLink.tryParse('http://host:3080/proxy'), isNull);
    });

    test('userinfo is rejected', () {
      expect(DshWebUiLink.tryParse('http://user:pass@host:3080'), isNull);
    });

    test('a non-http scheme is rejected', () {
      expect(DshWebUiLink.tryParse('ftp://host:3080'), isNull);
    });

    test('an empty or whitespace paste is rejected', () {
      expect(DshWebUiLink.tryParse('   '), isNull);
      expect(DshWebUiLink.tryParse(''), isNull);
    });

    test('the token never appears in toString', () {
      final link = DshWebUiLink.tryParse('http://host:3080/?token=secret');
      expect(link!.toString(), isNot(contains('secret')));
    });
  });
}
