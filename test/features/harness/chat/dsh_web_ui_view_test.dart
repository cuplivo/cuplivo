import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/harness/pages/plugins/dsh_plugin_web_page.dart';

void main() {
  group('DshWebViewCookie.parse', () {
    test('splits the name=value pair and drops attributes', () {
      final cookie = DshWebViewCookie.parse(
        'dsh-auth-abc=v1.secret; Path=/; HttpOnly; SameSite=Strict',
      );
      expect(cookie, isNotNull);
      expect(cookie!.name, 'dsh-auth-abc');
      expect(cookie.value, 'v1.secret');
    });

    test('rejects empty or malformed input', () {
      expect(DshWebViewCookie.parse(null), isNull);
      expect(DshWebViewCookie.parse(''), isNull);
      expect(DshWebViewCookie.parse('novalue'), isNull);
      expect(DshWebViewCookie.parse('=v1'), isNull);
      expect(DshWebViewCookie.parse('name='), isNull);
    });

    test('never prints the secret value', () {
      const cookie = DshWebViewCookie(name: 'dsh-auth-x', value: 'v1.secret');
      expect(cookie.toString(), isNot(contains('v1.secret')));
    });
  });
}
