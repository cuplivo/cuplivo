import 'dart:convert';

import 'package:Cuplivo/core/dsh/dsh_endpoint.dart';
import 'package:Cuplivo/core/dsh/dsh_errors.dart';
import 'package:Cuplivo/core/dsh/dsh_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dsh_fakes.dart';

void main() {
  group('DshCookie', () {
    test('parses Max-Age into an expiry', () {
      final cookie = DshCookie.parseSetCookie(
        'dsh-auth-hash=v1.payload.signature; Max-Age=2592000; Path=/; '
        'HttpOnly; SameSite=Strict',
        authority: '127.0.0.1:3080',
      );
      expect(cookie.name, 'dsh-auth-hash');
      expect(cookie.value, 'v1.payload.signature');
      expect(cookie.authority, '127.0.0.1:3080');
      expect(cookie.header, 'dsh-auth-hash=v1.payload.signature');
      expect(cookie.expiresAt, isNotNull);
      expect(
        cookie.expiresAt!.isAfter(
          DateTime.now().toUtc().add(const Duration(days: 29)),
        ),
        isTrue,
      );
    });

    test('parses Expires when Max-Age is absent', () {
      final cookie = DshCookie.parseSetCookie(
        'dsh-auth-x=v1; Expires=Wed, 09 Jun 2030 10:18:14 GMT; Path=/',
        authority: 'example.test',
      );
      expect(cookie.expiresAt, DateTime.utc(2030, 6, 9, 10, 18, 14));
    });

    test('round-trips through JSON', () {
      final cookie = DshCookie.parseSetCookie(
        'dsh-auth-hash=v1.abc.def; Max-Age=60',
        authority: 'example.test:8443',
      );
      final restored = DshCookie.fromJson(cookie.toJson());
      expect(restored.name, cookie.name);
      expect(restored.value, cookie.value);
      expect(restored.authority, cookie.authority);
      expect(restored.expiresAt, isNotNull);
    });

    test('rejects a malformed header', () {
      expect(
        () => DshCookie.parseSetCookie('not-a-cookie', authority: 'host'),
        throwsA(isA<DshProtocolException>()),
      );
    });

    test('picks the dsh-auth cookie out of a Set-Cookie list', () {
      final cookie = DshCookie.fromSetCookieHeaders([
        'other=1; Path=/',
        'dsh-auth-h=v1.a.b; Max-Age=30; Path=/',
      ], authority: 'host:1');
      expect(cookie, isNotNull);
      expect(cookie!.name, 'dsh-auth-h');
    });

    test('reports expiry', () {
      final expired = DshCookie.parseSetCookie(
        'dsh-auth-h=v1; Max-Age=0',
        authority: 'host',
      );
      expect(expired.isExpiredAt(DateTime.now().toUtc()), isTrue);
    });
  });

  group('httpStatusException', () {
    test('maps auth, capability and protocol statuses', () {
      expect(httpStatusException(401, 'x'), isA<DshAuthException>());
      expect(httpStatusException(403, 'x'), isA<DshAuthException>());
      expect(httpStatusException(404, 'x'), isA<DshUnsupportedException>());
      expect(httpStatusException(400, 'x'), isA<DshProtocolException>());
      expect(httpStatusException(413, 'x'), isA<DshProtocolException>());
      final retryable = httpStatusException(502, 'x');
      expect(retryable, isA<DshTransportException>());
      expect((retryable as DshTransportException).retryable, isTrue);
      final fatal = httpStatusException(418, 'x');
      expect((fatal as DshTransportException).retryable, isFalse);
    });
  });

  group('DshHttpTransport', () {
    late DshEndpoint endpoint;
    late FakeDshHttpClient http;

    setUp(() {
      endpoint = DshEndpoint.parse('http://127.0.0.1:3080/ui/?token=launch');
      http = FakeDshHttpClient();
    });

    test(
      'login sends exactly one GET /?token= with Host and no Origin',
      () async {
        http.handler = (request) async => const DshHttpResponse(
          statusCode: 303,
          headers: {'location': './'},
          setCookie: [
            'dsh-auth-hash=v1.a.b; Max-Age=2592000; Path=/; HttpOnly; SameSite=Strict',
          ],
          body: '',
        );
        final transport = DshHttpTransport(endpoint, httpClient: http);
        final cookie = await transport.login('launch');

        expect(cookie.authority, '127.0.0.1:3080');
        expect(http.requests, hasLength(1));
        final request = http.requests.single;
        expect(request.method, 'GET');
        expect(
          request.uri.toString(),
          'http://127.0.0.1:3080/ui/?token=launch',
        );
        expect(request.authority, '127.0.0.1:3080');
        expect(request.headers['origin'], isNull);
        expect(request.followRedirects, isFalse);
        expect(transport.cookie, same(cookie));
      },
    );

    test('login rejects an expired launch token with AuthException', () async {
      http.handler = (request) async => const DshHttpResponse(
        statusCode: 401,
        headers: {},
        setCookie: [],
        body: 'denied',
      );
      final transport = DshHttpTransport(endpoint, httpClient: http);
      expect(() => transport.login('launch'), throwsA(isA<DshAuthException>()));
    });

    test('login rejects a redirect without the dsh-auth cookie', () async {
      http.handler = (request) async => const DshHttpResponse(
        statusCode: 303,
        headers: {'location': './'},
        setCookie: ['other=1'],
        body: '',
      );
      final transport = DshHttpTransport(endpoint, httpClient: http);
      expect(
        () => transport.login('launch'),
        throwsA(isA<DshProtocolException>()),
      );
    });

    test('authenticated POST sends the cookie and JSON envelope', () async {
      http.handler = (request) async => const DshHttpResponse(
        statusCode: 200,
        headers: {'content-type': 'application/json'},
        setCookie: [],
        body:
            '{"type":"server-response","rpcId":"r1","result":{"ok":true,"value":7}}',
      );
      final transport = DshHttpTransport(
        endpoint,
        httpClient: http,
        cookie: const DshCookie(
          name: 'dsh-auth-h',
          value: 'v1.a.b',
          authority: '127.0.0.1:3080',
        ),
      );
      final response = await transport.post('session/list', {
        'type': 'client-request',
        'rpcId': 'r1',
      });
      expect(response.statusCode, 200);
      final request = http.requests.single;
      expect(request.method, 'POST');
      expect(
        request.uri.toString(),
        'http://127.0.0.1:3080/ui/api/session/list',
      );
      expect(request.headers['cookie'], 'dsh-auth-h=v1.a.b');
      expect(request.headers['content-type'], 'application/json');
      expect(jsonDecode(utf8.decode(request.body!)), {
        'type': 'client-request',
        'rpcId': 'r1',
      });
    });

    test('useCookie refuses a cookie minted for another authority', () {
      final transport = DshHttpTransport(endpoint, httpClient: http);
      expect(
        () => transport.useCookie(
          const DshCookie(name: 'dsh-auth-h', value: 'v1', authority: 'else:1'),
        ),
        throwsA(isA<DshEndpointException>()),
      );
    });

    test('openMux requires a cookie and sends it on the upgrade', () async {
      final transport = DshHttpTransport(endpoint, httpClient: http);
      expect(transport.openMux, throwsA(isA<DshAuthException>()));

      transport.useCookie(
        const DshCookie(
          name: 'dsh-auth-h',
          value: 'v1.a.b',
          authority: '127.0.0.1:3080',
        ),
      );
      await transport.openMux();
      final request = http.requests.single;
      expect(request.uri.toString(), 'ws://127.0.0.1:3080/ui/api/remote.mux');
      expect(request.headers['cookie'], 'dsh-auth-h=v1.a.b');
    });
  });
}
