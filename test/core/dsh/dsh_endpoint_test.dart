import 'package:Cuplivo/core/dsh/dsh_endpoint.dart';
import 'package:Cuplivo/core/dsh/dsh_errors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DshEndpoint.parse', () {
    test('parses the full dsh web line with a token', () {
      final endpoint = DshEndpoint.parse(
        'dsh web: http://127.0.0.1:3080/?token=abcDEF123',
      );
      expect(endpoint.baseUri.toString(), 'http://127.0.0.1:3080');
      expect(endpoint.authority, '127.0.0.1:3080');
      expect(endpoint.secure, isFalse);
      expect(endpoint.token, 'abcDEF123');
      expect(endpoint.hasToken, isTrue);
      expect(endpoint.mountPath, '');
      expect(endpoint.origin, 'http://127.0.0.1:3080');
      expect(endpoint.indexUri.toString(), 'http://127.0.0.1:3080/');
      expect(
        endpoint.loginUri.toString(),
        'http://127.0.0.1:3080/?token=abcDEF123',
      );
      expect(endpoint.muxUri.toString(), 'ws://127.0.0.1:3080/api/remote.mux');
      expect(
        endpoint.apiUri('session/list').toString(),
        'http://127.0.0.1:3080/api/session/list',
      );
    });

    test('a stored URL without a token resumes with a cookie', () {
      final endpoint = DshEndpoint.parse('http://192.168.1.20:3080');
      expect(endpoint.hasToken, isFalse);
      expect(endpoint.token, isNull);
      expect(endpoint.authority, '192.168.1.20:3080');
      expect(() => endpoint.loginUri, throwsA(isA<DshEndpointException>()));
    });

    test('keeps a mount prefix for every derived route', () {
      final endpoint = DshEndpoint.parse('https://example.test/ui/?token=t0k');
      expect(endpoint.mountPath, '/ui');
      expect(endpoint.authority, 'example.test');
      expect(endpoint.secure, isTrue);
      expect(
        endpoint.loginUri.toString(),
        'https://example.test/ui/?token=t0k',
      );
      expect(
        endpoint.apiUri('session/follow').toString(),
        'https://example.test/ui/api/session/follow',
      );
      expect(
        endpoint.muxUri.toString(),
        'wss://example.test/ui/api/remote.mux',
      );
      expect(endpoint.indexUri.toString(), 'https://example.test/ui/');
    });

    test('accepts a bare host:port and defaults to http', () {
      final endpoint = DshEndpoint.parse('127.0.0.1:3080/?token=abc');
      expect(endpoint.baseUri.toString(), 'http://127.0.0.1:3080');
      expect(endpoint.authority, '127.0.0.1:3080');
    });

    test('omits default ports so Host matches the cookie authority', () {
      expect(
        DshEndpoint.parse('http://example.test:80').authority,
        'example.test',
      );
      expect(
        DshEndpoint.parse('https://example.test:443').authority,
        'example.test',
      );
      expect(
        DshEndpoint.parse('https://example.test:8443').authority,
        'example.test:8443',
      );
    });

    test('brackets an IPv6 literal in the authority', () {
      final endpoint = DshEndpoint.parse('http://[::1]:3080/?token=x');
      expect(endpoint.authority, '[::1]:3080');
      expect(endpoint.baseUri.host, '::1');
    });

    test('strips chat punctuation around a pasted URL', () {
      final endpoint = DshEndpoint.parse('`http://127.0.0.1:3080/?token=abc`.');
      expect(endpoint.token, 'abc');
      expect(endpoint.authority, '127.0.0.1:3080');
    });

    test('rejects non-http schemes anywhere in the text', () {
      expect(
        () => DshEndpoint.parse('dsh web: ftp://example.test/x'),
        throwsA(
          isA<DshEndpointException>().having((e) => e.field, 'field', 'url'),
        ),
      );
    });

    test('rejects credentials in the URL', () {
      expect(
        () => DshEndpoint.parse('http://user:pass@example.test:3080'),
        throwsA(
          isA<DshEndpointException>().having((e) => e.field, 'field', 'url'),
        ),
      );
    });

    test('rejects an empty token with a token-field error', () {
      expect(
        () => DshEndpoint.parse('http://example.test:3080/?token='),
        throwsA(
          isA<DshEndpointException>().having((e) => e.field, 'field', 'token'),
        ),
      );
    });

    test('rejects empty input and garbage', () {
      expect(
        () => DshEndpoint.parse('   '),
        throwsA(isA<DshEndpointException>()),
      );
      expect(
        () => DshEndpoint.parse('not a url at all'),
        throwsA(isA<DshEndpointException>()),
      );
    });
  });

  group('derived URIs', () {
    final endpoint = DshEndpoint.parse('http://10.0.0.5:3080/ui/?token=abc');

    test('upload and file routes encode their query', () {
      expect(
        endpoint
            .uploadUri('session-1', name: 'notes.txt', mediaType: 'text/plain')
            .toString(),
        'http://10.0.0.5:3080/ui/api/session/uploadFileBinary'
        '?sessionId=session-1&name=notes.txt&mediaType=text%2Fplain',
      );
      expect(
        endpoint.fileUri('/workspace/demo/one.png', version: 'v1').toString(),
        'http://10.0.0.5:3080/ui/api/file?path=%2Fworkspace%2Fdemo%2Fone.png&v=v1',
      );
    });

    test('withoutToken drops the launch token but keeps the route', () {
      final clean = endpoint.withoutToken();
      expect(clean.hasToken, isFalse);
      expect(clean.authority, endpoint.authority);
      expect(clean.mountPath, '/ui');
      expect(clean.muxUri.toString(), endpoint.muxUri.toString());
    });

    test('apiUri rejects malformed endpoint names', () {
      expect(() => endpoint.apiUri(''), throwsArgumentError);
      expect(() => endpoint.apiUri('/session/list'), throwsArgumentError);
      expect(() => endpoint.apiUri('session list'), throwsArgumentError);
    });

    test('withToken rejects an empty token', () {
      expect(
        () => endpoint.withoutToken().withToken('  '),
        throwsA(
          isA<DshEndpointException>().having((e) => e.field, 'field', 'token'),
        ),
      );
    });
  });
}
