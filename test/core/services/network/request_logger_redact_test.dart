import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/network/request_logger.dart';

void main() {
  group('RequestLogger.redactHeaders', () {
    test(
      'masks credential-bearing headers keeping first 7 chars + rest length',
      () {
        final redacted = RequestLogger.redactHeaders(<String, String>{
          'Authorization': 'Bearer sk-abcdefghijklmnopqrstuvwxyz',
        });

        expect(redacted['Authorization'], 'Bearer [29 more]');
      },
    );

    test('leaves non-credential headers untouched', () {
      final redacted = RequestLogger.redactHeaders(<String, String>{
        'Content-Type': 'application/json',
        'User-Agent': 'Kelivo',
      });

      expect(redacted['Content-Type'], 'application/json');
      expect(redacted['User-Agent'], 'Kelivo');
    });

    test('matches credential header names case-insensitively', () {
      final redacted = RequestLogger.redactHeaders(<String, String>{
        'X-Api-Key': 'secret123456789',
        'PROXY-Authorization': 'Basic dXNlcjpwYXNz',
      });

      expect(redacted['X-Api-Key'], 'secret1 [8 more]');
      expect(redacted['PROXY-Authorization'], 'Basic d [11 more]');
    });

    test('keeps short values as-is', () {
      final redacted = RequestLogger.redactHeaders(<String, String>{
        'api-key': 'abc1234',
      });

      expect(redacted['api-key'], 'abc1234');
    });

    test('returns empty map unchanged', () {
      expect(RequestLogger.redactHeaders(<String, String>{}), isEmpty);
    });
  });
}
