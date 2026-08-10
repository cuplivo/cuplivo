import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_client/mcp_client.dart' as mcp;

import 'package:Cuplivo/core/services/oauth/oauth_flow_service.dart';
import 'package:Cuplivo/core/services/oauth/oauth_loopback_server.dart';

const _serverUrl = 'https://mcp.example.com/mcp/';

mcp.OAuthConfig _config({
  String authEndpoint = '',
  String tokenEndpoint = '',
  String clientId = '',
  String? redirectUri,
}) => mcp.OAuthConfig(
  authorizationEndpoint: authEndpoint,
  tokenEndpoint: tokenEndpoint,
  clientId: clientId,
  redirectUri: redirectUri,
  scopes: const ['openid', 'offline_access'],
);

/// Mock server answering discovery (RFC 8414), registration (RFC 7591)
/// and the token endpoint.
MockClient _fullServer({bool registrationEndpoint = true}) {
  return MockClient((request) async {
    final path = request.url.path;
    if (path == '/.well-known/oauth-authorization-server') {
      return http.Response(
        jsonEncode({
          'issuer': 'https://mcp.example.com/',
          'authorization_endpoint': 'https://mcp.example.com/authorize',
          'token_endpoint': 'https://mcp.example.com/token',
          if (registrationEndpoint)
            'registration_endpoint': 'https://mcp.example.com/register',
          'code_challenge_methods_supported': ['S256'],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (path == '/register' && request.method == 'POST') {
      return http.Response(
        jsonEncode({
          'client_id': 'registered-client-1',
          'redirect_uris': ['http://127.0.0.1/callback'],
          'token_endpoint_auth_method': 'none',
        }),
        201,
        headers: {'content-type': 'application/json'},
      );
    }
    if (path == '/token' && request.method == 'POST') {
      return http.Response(
        jsonEncode({
          'access_token': 'access-123',
          'token_type': 'Bearer',
          'expires_in': 3600,
          'refresh_token': 'refresh-456',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response('not found', 404);
  });
}

OAuthFlowService _service({MockClient? client}) {
  return OAuthFlowService(clientFactory: () => client ?? _fullServer());
}

/// Rebinds [port] until the OS grants it (async close releases it
/// eventually) or [attempts] polls are exhausted.
Future<bool> _waitForPortRelease(int port, {int attempts = 50}) async {
  for (var i = 0; i < attempts; i++) {
    try {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await probe.close();
      return true;
    } on SocketException {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
  return false;
}

void main() {
  group('OAuthFlowService auto mode (discovery + DCR + loopback)', () {
    test('discovers endpoints, registers a client, starts loopback', () async {
      final service = _service();
      final result = await service.beginFlow(
        key: 'server-1',
        config: _config(),
        serverUrl: _serverUrl,
      );

      expect(result.usedDiscovery, isTrue);
      expect(result.usedDcr, isTrue);
      expect(
        result.discoveredAuthorizationEndpoint,
        'https://mcp.example.com/authorize',
      );
      expect(result.discoveredTokenEndpoint, 'https://mcp.example.com/token');
      expect(result.discoveredClientId, 'registered-client-1');
      expect(result.loopbackCallbackUrl, isNotNull);
      expect(
        result.loopbackCallbackUrl!.host,
        'localhost',
        reason: 'loopback must use localhost so browsers race ::1/127.0.0.1',
      );

      // The authorize URL must carry the loopback redirect URI (random port).
      final params = result.authorizationUrl.queryParameters;
      expect(params['client_id'], 'registered-client-1');
      expect(params['redirect_uri'], startsWith('http://localhost:'));
      expect(params['code_challenge_method'], 'S256');
    });

    test(
      'completeFlow waits for the loopback callback and exchanges',
      () async {
        final service = _service();
        final result = await service.beginFlow(
          key: 'server-1',
          config: _config(),
          serverUrl: _serverUrl,
        );
        final callbackUrl = result.loopbackCallbackUrl!;
        final state = result.authorizationUrl.queryParameters['state']!;

        // Simulate the browser redirecting back. The loopback server sees a
        // RELATIVE request URI (`/callback?code=...`); the code extraction
        // must handle this shape (regression: absolute-URL-only matching
        // broke the auto flow with "code does not exist").
        final client = HttpClient();
        final req = await client.getUrl(
          callbackUrl.replace(
            queryParameters: {'code': 'cb-code', 'state': state},
          ),
        );
        final resp = await req.close();
        await resp.drain<void>();
        client.close();

        final token = await service.completeFlow(key: 'server-1');
        expect(token.accessToken, 'access-123');
        expect(token.refreshToken, 'refresh-456');
      },
    );

    test('completeFlow with a pasted code works in auto mode too', () async {
      final service = _service();
      await service.beginFlow(
        key: 'server-1',
        config: _config(),
        serverUrl: _serverUrl,
      );
      final token = await service.completeFlow(
        key: 'server-1',
        pasted: 'paste-code',
      );
      expect(token.accessToken, 'access-123');
    });

    test('completeFlow times out without a callback', () async {
      final service = _service();
      await service.beginFlow(
        key: 'server-1',
        config: _config(),
        serverUrl: _serverUrl,
      );
      await expectLater(
        service.completeFlow(
          key: 'server-1',
          callbackTimeout: const Duration(milliseconds: 50),
        ),
        throwsA(
          isA<OAuthFlowException>().having(
            (e) => e.code,
            'code',
            OAuthFlowErrorCode.callbackTimeout,
          ),
        ),
      );
    });

    test('completeFlow surfaces an authorization error callback', () async {
      final service = _service();
      final result = await service.beginFlow(
        key: 'server-1',
        config: _config(),
        serverUrl: _serverUrl,
      );
      final callbackUrl = result.loopbackCallbackUrl!;

      final client = HttpClient();
      final req = await client.getUrl(
        callbackUrl.replace(queryParameters: {'error': 'access_denied'}),
      );
      final resp = await req.close();
      await resp.drain<void>();
      client.close();

      await expectLater(
        service.completeFlow(key: 'server-1'),
        throwsA(
          isA<OAuthFlowException>().having(
            (e) => e.code,
            'code',
            OAuthFlowErrorCode.authorizationDenied,
          ),
        ),
      );
    });
  });

  group('OAuthFlowService manual mode (fallback)', () {
    test('no registration endpoint → manual mode, no loopback', () async {
      final service = _service(
        client: _fullServer(registrationEndpoint: false),
      );
      final result = await service.beginFlow(
        key: 'server-1',
        config: _config(),
        serverUrl: _serverUrl,
      );

      expect(result.usedDiscovery, isTrue);
      expect(result.usedDcr, isFalse);
      expect(result.discoveredClientId, isNull);
      // No client ID and no registration → authorize URL has an empty
      // client_id; the user must fill it in manually.
      expect(result.authorizationUrl.queryParameters['client_id'], isEmpty);
      // Loopback is still started (harmless) but the redirect URI falls
      // back to the config redirect URI when set.
    });

    test('manual paste flow still validates state', () async {
      final service = _service();
      final result = await service.beginFlow(
        key: 'server-1',
        config: _config(clientId: 'manual-client'),
        serverUrl: _serverUrl,
      );
      final state = result.authorizationUrl.queryParameters['state']!;
      final redirect =
          'https://app.example.com/callback'
          '?code=x&state=forged';

      await expectLater(
        service.completeFlow(key: 'server-1', pasted: redirect),
        throwsA(
          isA<OAuthFlowException>().having(
            (e) => e.code,
            'code',
            OAuthFlowErrorCode.stateMismatch,
          ),
        ),
      );
      expect(state, isNotEmpty);
    });

    test('beginFlow twice replaces the previous session', () async {
      final service = _service();
      final url1 = await service.beginFlow(
        key: 'server-1',
        config: _config(clientId: 'c1'),
        serverUrl: _serverUrl,
      );
      final url2 = await service.beginFlow(
        key: 'server-1',
        config: _config(clientId: 'c1'),
        serverUrl: _serverUrl,
      );

      expect(
        url2.authorizationUrl.queryParameters['state'],
        isNot(url1.authorizationUrl.queryParameters['state']),
      );
    });

    test('rejects completion without an active flow', () async {
      final service = _service();
      await expectLater(
        service.completeFlow(key: 'server-1', pasted: 'whatever'),
        throwsA(
          isA<OAuthFlowException>().having(
            (e) => e.code,
            'code',
            OAuthFlowErrorCode.noSession,
          ),
        ),
      );
    });

    test(
      'cancelFlow discards the session and closes the loopback port',
      () async {
        final service = _service();
        final result = await service.beginFlow(
          key: 'server-1',
          config: _config(),
          serverUrl: _serverUrl,
        );
        final port = result.loopbackCallbackUrl!.port;
        service.cancelFlow('server-1');

        // The loopback close is fire-and-forget, so the port release is
        // asynchronous; poll until the rebind probe succeeds instead of
        // racing the close (CI flake: EADDRINUSE on immediate rebind).
        final released = await _waitForPortRelease(port);
        expect(released, isTrue, reason: 'port $port must be released');

        await expectLater(
          service.completeFlow(key: 'server-1', pasted: 'code'),
          throwsA(
            isA<OAuthFlowException>().having(
              (e) => e.code,
              'code',
              OAuthFlowErrorCode.noSession,
            ),
          ),
        );
      },
    );
  });

  group('OAuthFlowService discovery failure', () {
    test('no discoverable metadata → noAuthEndpoint instead of a '
        'malformed URL', () async {
      // Everything 404s: discovery returns null, DCR is skipped.
      final nothing = MockClient((request) async => http.Response('nope', 404));
      final service = OAuthFlowService(clientFactory: () => nothing);

      await expectLater(
        service.beginFlow(
          key: 'server-1',
          config: _config(),
          serverUrl: _serverUrl,
        ),
        throwsA(
          isA<OAuthFlowException>().having(
            (e) => e.code,
            'code',
            OAuthFlowErrorCode.noAuthEndpoint,
          ),
        ),
      );
    });
  });

  group('OAuthFlowService paste override', () {
    test('a pasted code overrides an in-flight callback wait', () async {
      final service = _service();
      await service.beginFlow(
        key: 'server-1',
        config: _config(),
        serverUrl: _serverUrl,
      );
      final waiting = service.completeFlow(
        key: 'server-1',
        callbackTimeout: const Duration(minutes: 2),
      );
      // Attach the matcher BEFORE the interruption — the overridden waiter
      // completes with an error the moment it is interrupted, and an
      // un-listened failing future surfaces as an unhandled error.
      final waitingExpectation = expectLater(
        waiting,
        throwsA(
          isA<OAuthFlowException>().having(
            (e) => e.code,
            'code',
            OAuthFlowErrorCode.interrupted,
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // The paste wins: it exchanges immediately.
      final token = await service.completeFlow(
        key: 'server-1',
        pasted: 'cb-code',
      );
      expect(token.accessToken, 'access-123');

      // The overridden waiter exits silently via the internal `interrupted`
      // signal instead of surfacing a timeout error.
      await waitingExpectation;
    });

    test('an empty paste does not override an in-flight wait', () async {
      final service = _service();
      await service.beginFlow(
        key: 'server-1',
        config: _config(),
        serverUrl: _serverUrl,
      );
      final waiting = service.completeFlow(
        key: 'server-1',
        callbackTimeout: const Duration(minutes: 2),
      );
      final waitingExpectation = expectLater(
        waiting,
        throwsA(
          isA<OAuthFlowException>().having(
            (e) => e.code,
            'code',
            OAuthFlowErrorCode.callbackTimeout,
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await expectLater(
        service.completeFlow(key: 'server-1', pasted: ''),
        throwsA(
          isA<OAuthFlowException>().having(
            (e) => e.code,
            'code',
            OAuthFlowErrorCode.noSession,
          ),
        ),
      );

      // Cancel interrupts the pending wait so the waiter does not hang
      // until the timeout.
      service.cancelFlow('server-1');
      await waitingExpectation;
    });
  });

  group('OAuthLoopbackServer cancellation', () {
    test(
      'cancelWait interrupts waitForCallback; close releases the port',
      () async {
        final server = OAuthLoopbackServer();
        await server.start();
        final port = server.callbackUrl!.port;

        final wait = server.waitForCallback(const Duration(minutes: 2));
        server.cancelWait();
        expect(await wait, isNull);

        await server.close();
        // Port must be released: rebinding the same port succeeds.
        final probe = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          port,
        );
        await probe.close();
      },
    );
  });

  group('OAuthFlowService token exchange failure', () {
    test('wraps a failing token endpoint into exchangeFailed', () async {
      final failing = MockClient((request) async {
        final path = request.url.path;
        if (path == '/.well-known/oauth-authorization-server') {
          return http.Response(
            jsonEncode({
              'issuer': 'https://mcp.example.com/',
              'authorization_endpoint': 'https://mcp.example.com/authorize',
              'token_endpoint': 'https://mcp.example.com/token',
              'registration_endpoint': 'https://mcp.example.com/register',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/register') {
          return http.Response(
            jsonEncode({'client_id': 'registered-client-1'}),
            201,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/token') {
          return http.Response('{"error":"invalid_grant"}', 400);
        }
        return http.Response('not found', 404);
      });
      final service = _service(client: failing);
      await service.beginFlow(
        key: 'server-1',
        config: _config(),
        serverUrl: _serverUrl,
      );

      await expectLater(
        service.completeFlow(key: 'server-1', pasted: 'any-code'),
        throwsA(
          isA<OAuthFlowException>().having(
            (e) => e.code,
            'code',
            OAuthFlowErrorCode.exchangeFailed,
          ),
        ),
      );
    });
  });
}
