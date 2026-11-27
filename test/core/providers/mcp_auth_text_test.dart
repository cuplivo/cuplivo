import 'package:Cuplivo/core/providers/mcp_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// The text heuristic behind [McpStatus.needsAuthorization].
///
/// `package:http` puts the request URI into what it throws, and the URI carries
/// the ephemeral port. A bare `contains('401')` therefore turns a dropped socket
/// into "the server wants OAuth" on whichever runs happen to draw a port
/// containing `401` - which is what made
/// `mcp_provider_remote_session_test.dart` › unknown tool result is never
/// replayed after a socket drop fail on CI while passing in isolation.
///
/// The structured half of the decision (`McpHttpError.statusCode == 401`) is
/// covered by the 401 mock cases in `mcp_provider_remote_session_test.dart`; this
/// file only pins the free-text half.
void main() {
  group('MCP unauthorized text heuristic ignores URLs', () {
    test('a dropped socket whose port contains 401 is not unauthorized', () {
      // Verbatim from the CI failure (run 37727415920), and the string a
      // throwaway probe produced against the same socket-drop construct.
      expect(
        mcpErrorTextLooksUnauthorized(
          'ClientException: Connection closed before full header was received, '
          'uri=http://127.0.0.1:34010/mcp',
        ),
        isFalse,
      );
    });

    test('401 anywhere inside a longer number is not a status code', () {
      for (final message in <String>[
        'ClientException: Connection closed before full header was received, '
            'uri=http://127.0.0.1:14012/mcp',
        'ClientException: Connection closed before full header was received, '
            'uri=http://127.0.0.1:40100/mcp',
        'ClientException: Connection closed, uri=http://127.0.0.1:34010/mcp',
        'request id 94011 failed',
      ]) {
        expect(
          mcpErrorTextLooksUnauthorized(message),
          isFalse,
          reason: message,
        );
      }
    });

    test('the port in a wrapped socket exception is not unauthorized', () {
      // The raw-socket variant of the same construct: here the *client's* local
      // port is in the text as well.
      expect(
        mcpErrorTextLooksUnauthorized(
          'ClientException with SocketException: Write failed (OS Error: the '
          'connection was aborted), address = 127.0.0.1, port = 64830, '
          'uri=http://127.0.0.1:34010/mcp',
        ),
        isFalse,
      );
    });

    test('a URL path is not evidence either', () {
      for (final message in <String>[
        'HttpException: Connection closed before full header was received, '
            'uri=https://example.test/unauthorized-endpoint',
        'Transport failure calling https://example.test/oauth/invalid_token',
      ]) {
        expect(
          mcpErrorTextLooksUnauthorized(message),
          isFalse,
          reason: message,
        );
      }
    });

    test('a real unauthorized reply is still recognized', () {
      for (final message in <String>[
        'HTTP 401 Unauthorized',
        'McpError: server replied 401',
        'the server returned: 401.',
        'invalid_token',
        'Authentication failed for this server',
      ]) {
        expect(mcpErrorTextLooksUnauthorized(message), isTrue, reason: message);
      }
    });
  });
}
