import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/mcp_provider.dart';

/// Minimal MCP streamable-HTTP server. Answers `initialize`,
/// `notifications/initialized` and `tools/list` so mcp_client can complete
/// a real connect handshake. No `MCP-Session-Id` header is sent, so the
/// transport stays in pure request/response mode (no SSE GET stream).
///
/// While [authRequired] returns true every request is answered with a
/// plain HTTP 401. mcp_client treats that as a JSON-RPC error message
/// (not a transport stream error), so failed connects stay quiet — no
/// unhandled stream errors in the test zone.
Future<HttpServer> _startMcpServer(
  int port, {
  required bool Function() authRequired,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  _attachMcpHandler(server, authRequired);
  return server;
}

void _attachMcpHandler(HttpServer server, bool Function() authRequired) {
  server.listen((request) async {
    if (request.method != 'POST') {
      request.response.statusCode = 405;
      await request.response.close();
      return;
    }
    final body = await utf8.decoder.bind(request).join();
    final msg = jsonDecode(body) as Map<String, dynamic>;
    final method = msg['method'];
    final id = msg['id'];
    final response = request.response;
    response.headers.contentType = ContentType.json;
    if (authRequired()) {
      // No OAuth is configured, so the client surfaces this as an
      // McpError from initialize() and retries; it never emits an
      // unhandled transport stream error.
      response.statusCode = 401;
      await response.close();
      return;
    }
    if (method == 'initialize') {
      response.statusCode = 200;
      response.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'protocolVersion': (msg['params'] as Map)['protocolVersion'],
            'serverInfo': {'name': 'Test MCP', 'version': '1.0.0'},
            // mcp_client's ServerCapabilities.fromJson requires `tools` to
            // be an object, not the spec's boolean `true`.
            'capabilities': {'tools': <String, Object>{}},
          },
        }),
      );
    } else if (method == 'notifications/initialized') {
      response.statusCode = 202;
    } else {
      // tools/list and anything else: an empty result.
      response.statusCode = 200;
      response.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'tools': <Object>[],
          },
        }),
      );
    }
    await response.close();
  });
}

/// Polls [predicate] until it returns true or [timeout] elapses.
Future<bool> _waitUntil(
  Future<bool> Function() predicate,
  Duration timeout,
) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return predicate();
}

void main() {
  test(
    'an enabled server whose initial connect failed auto-reconnects once the '
    'server accepts connections again (network restore after app start)',
    () async {
      SharedPreferences.setMockInitialValues({});
      // The server runs for the whole test: first rejecting every request
      // (simulates the network being down / server unreachable), then
      // accepting. Binding port 0 gives a real free port — no probe race.
      var authRequired = true;
      final server = await _startMcpServer(
        0,
        authRequired: () => authRequired,
      );
      final port = server.port;

      final provider = McpProvider(
        contextProvider: () => throw UnimplementedError(),
      );
      final id = await provider.addServer(
        enabled: true,
        name: 'Auto Reconnect',
        transport: McpTransportType.http,
        url: 'http://127.0.0.1:$port/mcp',
        // 1s supervisor heartbeat so the test does not wait 12s.
        heartbeatIntervalSeconds: 1,
      );
      await pumpEventQueue();

      try {
        // Phase 1: server rejects requests — the initial connect fails and
        // the provider lands in the error state (tools unavailable to the
        // main agent).
        final reachedError = await _waitUntil(
          () async => provider.statusFor(id) == McpStatus.error,
          const Duration(seconds: 12),
        );
        expect(
          reachedError,
          isTrue,
          reason: 'a rejected connect should end in the error state',
        );
        expect(provider.isConnected(id), isFalse);

        // Phase 2: server starts accepting (e.g. the network is restored).
        // The supervisor heartbeat must reconnect automatically without any
        // user action.
        authRequired = false;
        final reconnected = await _waitUntil(
          () async => provider.isConnected(id),
          const Duration(seconds: 15),
        );
        expect(
          reconnected,
          isTrue,
          reason: 'supervisor heartbeat should auto-reconnect the server',
        );
        expect(provider.statusFor(id), McpStatus.connected);
        expect(provider.errorFor(id), isNull);
      } finally {
        // Cancel the supervisor heartbeat and the disconnect listener.
        await provider.disconnect(id);
        await server.close(force: true);
      }
    },
  );
}
