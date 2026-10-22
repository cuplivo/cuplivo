import 'package:Cuplivo/core/services/logging/log_redactor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('maskSecret', () {
    test('keeps first 3 and last 4 with length', () {
      expect(
        LogRedactor.maskSecret('sk-abcdefghijklmnopqrstuvwxyz1234'),
        'sk-***1234(len=33)',
      );
    });

    test('fully masks values shorter than 16', () {
      expect(LogRedactor.maskSecret('short'), '***(len=5)');
      expect(LogRedactor.maskSecret('123456789012345'), '***(len=15)');
      expect(LogRedactor.maskSecret('1234567890123456'), '123***3456(len=16)');
    });

    test('preserves Bearer, Basic, and Token prefixes', () {
      expect(
        LogRedactor.maskSecret('Bearer sk-abcdefghijklmnopqrstuvwxyz1234'),
        'Bearer sk-***1234(len=33)',
      );
      expect(
        LogRedactor.maskSecret('Basic abcdefghijklmnop'),
        'Basic abc***mnop(len=16)',
      );
      expect(
        LogRedactor.maskSecret('Token abcdefghijklmnop'),
        'Token abc***mnop(len=16)',
      );
    });
  });

  group('redactHeaders', () {
    test('masks exact and heuristic header names', () {
      final redacted = LogRedactor.redactHeaders({
        'Authorization': 'Bearer sk-abcdefghijklmnopqrstuvwxyz1234',
        'proxy-authorization': 'Basic abcdefghijklmnop',
        'x-api-key': 'sk-abcdefghijklmnopqrstuvwxyz1234',
        'api-key': 'sk-abcdefghijklmnopqrstuvwxyz1234',
        'x-goog-api-key': 'AIzaSyA-test-key-value-zzzz',
        'X-Subscription-Token': 'subtokensecret12',
        'x-auth-token': 'authtokensecret1',
        'x-goog-iam-authorization-token': 'iamtokensecret12',
        'Cookie': 'session=abcdefghijklmnop',
        'set-cookie': 'sid=abcdefghijklmnop; Path=/',
        'X-My-Secret': 'customsecretval',
        'X-Session-Id': 'sessionidvalue1',
        'Content-Type': 'application/json',
        'Accept': '*/*',
      });

      expect(redacted['Authorization'], 'Bearer sk-***1234(len=33)');
      expect(redacted['proxy-authorization'], 'Basic abc***mnop(len=16)');
      expect(redacted['x-api-key'], 'sk-***1234(len=33)');
      expect(redacted['api-key'], 'sk-***1234(len=33)');
      expect(redacted['x-goog-api-key'], 'AIz***zzzz(len=27)');
      expect(redacted['X-Subscription-Token'], 'sub***et12(len=16)');
      expect(redacted['x-auth-token'], 'aut***ret1(len=16)');
      expect(redacted['x-goog-iam-authorization-token'], 'iam***et12(len=16)');
      expect(redacted['Cookie'], 'ses***mnop(len=24)');
      expect(redacted['set-cookie'], 'sid***th=/(len=28)');
      expect(redacted['X-My-Secret'], '***(len=15)');
      expect(redacted['X-Session-Id'], '***(len=15)');
      expect(redacted['Content-Type'], 'application/json');
      expect(redacted['Accept'], '*/*');
    });

    test('is idempotent and leaves safe headers untouched', () {
      const headers = {
        'Authorization': 'Bearer sk-abcdefghijklmnopqrstuvwxyz1234',
        'Content-Type': 'application/json',
      };
      final once = LogRedactor.redactHeaders(headers);
      final twice = LogRedactor.redactHeaders(once);
      expect(twice, once);
      expect(
        LogRedactor.redactHeaders({'Accept': '*/*', 'Host': 'api.example.com'}),
        {'Accept': '*/*', 'Host': 'api.example.com'},
      );
    });
  });

  group('redactUrl', () {
    test('rewrites sensitive query keys on parseable URLs', () {
      expect(
        LogRedactor.redactUrl(
          'https://api.example.com/v1/chat?key=secretsecret12&foo=bar',
        ),
        'https://api.example.com/v1/chat?key=***(len=14)&foo=bar',
      );
    });

    test('strips userinfo without rewriting the rest of the URL', () {
      expect(
        LogRedactor.redactUrl('https://alice:s3cretpass@api.example.com/v1'),
        'https://api.example.com/v1',
      );
      expect(
        LogRedactor.redactUrl(
          'https://alice:s3cretpass@api.example.com/v1?key=secretsecret12',
        ),
        'https://api.example.com/v1?key=***(len=14)',
      );
    });

    test('does not treat @ in query or path as userinfo', () {
      const queryAt = 'https://api.example.com?to=alice@example.com&n=1';
      const pathAt = 'https://api.example.com/models/foo@bar';
      expect(LogRedactor.redactUrl(queryAt), queryAt);
      expect(LogRedactor.redactUrl(pathAt), pathAt);
    });

    test('falls back to regex when Uri.tryParse fails', () {
      const raw =
          'http://alice:s3cretpass@example.com:abc/path?key=secretsecret12&keep=ok';
      expect(Uri.tryParse(raw), isNull);
      final redacted = LogRedactor.redactUrl(raw);
      expect(redacted, isNot(contains('s3cretpass')));
      expect(redacted, isNot(contains('secretsecret12')));
      expect(redacted, contains('keep=ok'));
      expect(redacted, contains('key=***(len=14)'));
    });

    test('is idempotent and leaves safe URLs unchanged', () {
      const safe = 'https://api.example.com/v1/chat?foo=bar&n=1';
      expect(LogRedactor.redactUrl(safe), safe);

      final once = LogRedactor.redactUrl(
        'https://alice:s3cretpass@api.example.com/v1?access_token=tokensecret12',
      );
      expect(LogRedactor.redactUrl(once), once);
    });
  });

  group('redactBody', () {
    test('walks nested JSON objects and arrays', () {
      const body =
          '{"user":{"api_key":"sk-abcdefghijklmnopqrstuvwxyz1234","name":"alice"},'
          '"items":[{"access_token":"tokensecret12"}],'
          '"api_key":["abcdefghijklmnop","qrstuvwxyzabcdef"]}';
      final redacted = LogRedactor.redactBody(body);
      expect(redacted, isNot(contains('sk-abcdefghijklmnopqrstuvwxyz1234')));
      expect(redacted, isNot(contains('tokensecret12')));
      expect(redacted, isNot(contains('abcdefghijklmnop')));
      expect(redacted, isNot(contains('qrstuvwxyzabcdef')));
      expect(redacted, contains('alice'));
      expect(redacted, contains('sk-***1234(len=33)'));
      expect(redacted, contains('***(len=13)'));
      expect(redacted, contains('abc***mnop(len=16)'));
      expect(redacted, contains('qrs***cdef(len=16)'));
    });

    test('does not mask bare token, author, or lookalike field names', () {
      const body =
          '{"token":"Hello from the model","author":"bob","content":"ok",'
          '"keywords":"flutter dart tips","monkey":"banana banana banana",'
          '"stop_tokens":["<|endoftext|>","</s>"]}';
      expect(LogRedactor.redactBody(body), body);
    });

    test('masks compound auth and key names after word split', () {
      const body =
          '{"authorization_header":"Bearer abcdefghijklmnop",'
          '"authorizationCode":"abcdefghijklmnop",'
          '"apikey":"abcdefghijklmnop"}';
      final redacted = LogRedactor.redactBody(body);
      expect(redacted, isNot(contains('abcdefghijklmnop')));
      expect(redacted, contains('Bearer abc***mnop(len=16)'));
      expect(redacted, contains('abc***mnop(len=16)'));
    });

    test('uses regex for non-JSON and oversized JSON bodies', () {
      const plain = 'hello "API_KEY": "abcdefghijklmnop" world';
      expect(
        LogRedactor.redactBody(plain),
        'hello "API_KEY": "abc***mnop(len=16)" world',
      );

      const sse =
          'data: {"authorization":"plainsecretvalue","access_token":"abcdefghijklmnop"}';
      final sseRedacted = LogRedactor.redactBody(sse);
      expect(sseRedacted, isNot(contains('plainsecretvalue')));
      expect(sseRedacted, isNot(contains('abcdefghijklmnop')));

      final hugeArray =
          '{"access_token":["plainsecretvalue"],"pad":"${'x' * (256 * 1024)}"}';
      expect(hugeArray.length, greaterThanOrEqualTo(256 * 1024));
      expect(LogRedactor.redactBody(hugeArray), hugeArray);

      final hugeWithKey =
          '{"authorization":"plainsecretvalue","pad":"${'x' * (256 * 1024)}"}';
      final hugeRedacted = LogRedactor.redactBody(hugeWithKey);
      expect(hugeRedacted, isNot(contains('plainsecretvalue')));
      expect(hugeRedacted, contains('pla***alue(len=16)'));
    });

    test('masks known key prefixes in JSON string values', () {
      const body =
          '{"message":"invalid key sk-abcdefghijklmnopqrstuvwxyz1234"}';
      final redacted = LogRedactor.redactBody(body);
      expect(redacted, isNot(contains('sk-abcdefghijklmnopqrstuvwxyz1234')));
      expect(redacted, contains('sk-***1234(len=33)'));
    });

    test('does not mask known prefixes in the middle of a token', () {
      const body = '{"message":"AAAsk-xxxxxxxxxxxxBBB"}';
      expect(LogRedactor.redactBody(body), body);
    });

    test('is idempotent and leaves safe bodies unchanged', () {
      const safe = '{"message":"hello","count":1}';
      expect(LogRedactor.redactBody(safe), safe);

      const body = '{"api_key":"sk-abcdefghijklmnopqrstuvwxyz1234"}';
      final once = LogRedactor.redactBody(body);
      expect(LogRedactor.redactBody(once), once);
    });
  });

  group('redactText', () {
    test('masks query keys, userinfo, and known prefixes in free text', () {
      const text =
          'ClientException: GET https://alice:s3cretpass@generativelanguage.googleapis.com/v1?key=AIzaSyA-test-key-value-zzzz failed';
      final redacted = LogRedactor.redactText(text);
      expect(redacted, isNot(contains('s3cretpass')));
      expect(redacted, isNot(contains('AIzaSyA-test-key-value-zzzz')));
      expect(redacted, contains('***'));
    });

    test('does not rewrite URLs that only have @ in the query', () {
      const text =
          'failed GET https://api.example.com?to=alice@example.com&n=1';
      expect(LogRedactor.redactText(text), text);
    });

    test('is idempotent and leaves safe text unchanged', () {
      const safe = 'connection failed after 3 retries';
      expect(LogRedactor.redactText(safe), safe);

      const text =
          'error https://alice:s3cretpass@api.example.com/v1?key=secretsecret12 sk-abcdefghijklmnopqrstuvwxyz1234';
      final once = LogRedactor.redactText(text);
      expect(LogRedactor.redactText(once), once);
    });
  });
}
