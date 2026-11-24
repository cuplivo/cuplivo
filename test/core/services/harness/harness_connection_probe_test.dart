import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/harness/harness_connection_probe.dart';

/// The wire transcript of one request the fake DSH received.
final class _SeenRequest {
  const _SeenRequest({
    required this.method,
    required this.path,
    required this.query,
    required this.cookie,
    required this.body,
  });

  final String method;
  final String path;
  final Map<String, String> query;
  final String? cookie;
  final String body;

  String get line => '$method $path';
}

enum _SessionListAnswer { ok, okFalse, wrongRpcId }

/// A stand-in for a DeepSeek Harness WebUI that speaks the same three exchanges
/// as the real one: a tokenized launch link that sets the browser cookie, the
/// `/connect` operator handshake, and one authenticated JSON-RPC call.
///
/// Every request is recorded and every protocol expectation the real server
/// would enforce is collected in [violations], so a test can assert on the wire
/// the probe produced, not only on the verdict it returned.
final class _FakeHarnessServer {
  _FakeHarnessServer._(this._server, {required this.prefix});

  static const String _token = 'launch-token';
  static const String _browserCookie = 'dsh-browser=browser-cookie';
  static const String _operatorCookie = 'dsh-operator=operator-cookie';

  static Future<_FakeHarnessServer> start({String prefix = ''}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeHarnessServer._(server, prefix: prefix);
    server.listen((request) {
      unawaited(fake._handle(request));
    });
    return fake;
  }

  final HttpServer _server;

  /// Serves the WebUI below `/<prefix>/`, like a DSH instance behind a reverse
  /// proxy path.
  final String prefix;

  final List<_SeenRequest> requests = <_SeenRequest>[];
  final List<String> violations = <String>[];
  final Completer<void> _stalled = Completer<void>();

  /// Overrides the answer of one exchange; `null` keeps the happy-path answer.
  int? launchStatus;
  int? connectStatus;
  int? sessionListStatus;
  _SessionListAnswer sessionListAnswer = _SessionListAnswer.ok;

  /// Accepts the first request and never answers it.
  bool stall = false;

  int get port => _server.port;

  String get launchUrl => 'http://127.0.0.1:$port$_rootPath?token=$_token';

  String get _rootPath => prefix.isEmpty ? '/' : '/$prefix/';

  Future<void> close() async {
    if (!_stalled.isCompleted) _stalled.complete();
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final body = request.method == 'POST'
          ? await utf8.decoder.bind(request).join()
          : '';
      final seen = _SeenRequest(
        method: request.method,
        path: request.uri.path,
        query: request.uri.queryParameters,
        cookie: request.headers.value(HttpHeaders.cookieHeader),
        body: body,
      );
      requests.add(seen);
      if (stall) {
        // The client gives up on its own timeout; only then answer the socket.
        await _stalled.future;
        await _respond(request, HttpStatus.serviceUnavailable);
        return;
      }
      final route = _routeOf(seen.path);
      if (route == '/') {
        await _launch(request, seen);
      } else if (route == '/connect') {
        await _connect(request, seen);
      } else if (route == '/api/session/list') {
        await _sessionList(request, seen);
      } else {
        violations.add('unexpected request ${seen.line}');
        await _respond(request, HttpStatus.notFound);
      }
    } catch (error) {
      violations.add('handler threw: $error');
    }
  }

  /// The request path with the prefix removed, or `null` when it is outside the
  /// served root.
  String? _routeOf(String path) {
    if (prefix.isEmpty) return path;
    final root = '/$prefix';
    return path.startsWith('$root/') ? path.substring(root.length) : null;
  }

  Future<void> _launch(HttpRequest request, _SeenRequest seen) async {
    if (seen.query['token'] != _token) {
      violations.add('launch did not redeem the link token: ${seen.query}');
    }
    final status = launchStatus;
    if (status != null) {
      await _respond(request, status);
      return;
    }
    await _respond(
      request,
      HttpStatus.seeOther,
      setCookie: '$_browserCookie; Path=/; HttpOnly',
    );
  }

  Future<void> _connect(HttpRequest request, _SeenRequest seen) async {
    if (seen.query['token'] != _token) {
      violations.add('connect did not carry the link token: ${seen.query}');
    }
    if (seen.query['interactions'] != 'answer') {
      violations.add('connect did not ask for answerable interactions');
    }
    final status = connectStatus;
    if (status != null) {
      await _respond(request, status);
      return;
    }
    await _respond(
      request,
      HttpStatus.found,
      setCookie: '$_operatorCookie; Path=/; HttpOnly',
    );
  }

  Future<void> _sessionList(HttpRequest request, _SeenRequest seen) async {
    Map<String, dynamic>? envelope;
    try {
      final decoded = jsonDecode(seen.body);
      if (decoded is Map<String, dynamic>) envelope = decoded;
    } catch (_) {
      // Reported below as a malformed envelope.
    }
    if (envelope == null) {
      violations.add('session/list body was not a JSON object: ${seen.body}');
      await _respond(request, HttpStatus.badRequest);
      return;
    }
    final payload = envelope['payload'];
    final args = payload is Map ? payload['args'] : null;
    final sessionListArgs = args is Map ? args['_request'] : null;
    if (envelope['type'] != 'client-request') {
      violations.add('session/list envelope type: ${envelope['type']}');
    }
    if (envelope['method'] != 'session/list') {
      violations.add('session/list envelope method: ${envelope['method']}');
    }
    if (envelope['rpcId'] is! String || (envelope['rpcId'] as String).isEmpty) {
      violations.add('session/list envelope carried no rpcId');
    }
    if (sessionListArgs is! Map || sessionListArgs.isNotEmpty) {
      violations.add('session/list args were not an empty _request object');
    }
    final cookie = seen.cookie ?? '';
    if (!cookie.contains(_browserCookie)) {
      violations.add('launch cookie was not forwarded: $cookie');
    }
    if (!cookie.contains(_operatorCookie)) {
      violations.add('operator cookie was not forwarded: $cookie');
    }

    final status = sessionListStatus;
    if (status != null) {
      await _respond(request, status);
      return;
    }
    final rpcId = envelope['rpcId'];
    final echoedRpcId = sessionListAnswer == _SessionListAnswer.wrongRpcId
        ? 'someone-elses-rpc-id'
        : rpcId;
    await _respond(
      request,
      HttpStatus.ok,
      body: jsonEncode(<String, Object?>{
        'type': 'server-response',
        'rpcId': echoedRpcId,
        'result': <String, Object?>{
          'ok': sessionListAnswer != _SessionListAnswer.okFalse,
        },
      }),
    );
  }

  Future<void> _respond(
    HttpRequest request,
    int status, {
    String? setCookie,
    String? body,
  }) async {
    try {
      request.response.statusCode = status;
      if (setCookie != null) {
        request.response.headers.set(HttpHeaders.setCookieHeader, setCookie);
      }
      if (body != null) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(body);
      }
      await request.response.close();
    } catch (_) {
      // A stalled exchange is answered after the client has already given up;
      // writing to that socket is expected to fail and says nothing about the
      // probe.
    }
  }
}

Future<_FakeHarnessServer> _startHarness({String prefix = ''}) async {
  final server = await _FakeHarnessServer.start(prefix: prefix);
  addTearDown(server.close);
  return server;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // The test binding stubs every HttpClient; the probe must talk to the real
    // loopback server these tests start.
    HttpOverrides.global = null;
  });

  group('HarnessConnectionProbe', () {
    test(
      'redeems the launch link, exchanges the operator cookie and lists sessions',
      () async {
        final server = await _startHarness();

        final result = await const HarnessConnectionProbe().check(
          server.launchUrl,
        );

        expect(result.isConnected, isTrue);
        expect(result.failure, isNull);
        expect(server.violations, isEmpty);
        expect(server.requests.map((request) => request.line), <String>[
          'GET /',
          'GET /connect',
          'POST /api/session/list',
        ]);
        // The operator handshake is what turns the launch token into a session.
        expect(server.requests[1].query, <String, String>{
          'token': 'launch-token',
          'interactions': 'answer',
        });
        // Both cookies the earlier steps handed out authenticate the RPC.
        expect(
          server.requests[2].cookie,
          contains('dsh-browser=browser-cookie'),
        );
        expect(
          server.requests[2].cookie,
          contains('dsh-operator=operator-cookie'),
        );
      },
    );

    test('joins a path prefix on every step of the exchange', () async {
      final server = await _startHarness(prefix: 'ui');

      final result = await const HarnessConnectionProbe().check(
        server.launchUrl,
      );

      expect(result.isConnected, isTrue);
      expect(server.violations, isEmpty);
      expect(server.requests.map((request) => request.line), <String>[
        'GET /ui/',
        'GET /ui/connect',
        'POST /ui/api/session/list',
      ]);
    });

    test(
      'invalid links and links without a token fail before any request',
      () async {
        final server = await _startHarness();
        const probe = HarnessConnectionProbe();
        final base = 'http://127.0.0.1:${server.port}';

        expect(
          (await probe.check('')).failure,
          HarnessConnectionFailure.invalidUrl,
        );
        expect(
          (await probe.check('not a url')).failure,
          HarnessConnectionFailure.invalidUrl,
        );
        expect(
          (await probe.check(
            'ftp://127.0.0.1:${server.port}/?token=x',
          )).failure,
          HarnessConnectionFailure.invalidUrl,
        );
        expect(
          (await probe.check('http://')).failure,
          HarnessConnectionFailure.invalidUrl,
        );
        expect(
          (await probe.check('$base/')).failure,
          HarnessConnectionFailure.missingToken,
        );
        expect(
          (await probe.check('$base/?token=')).failure,
          HarnessConnectionFailure.missingToken,
        );
        expect(
          (await probe.check('$base/?token=%20%20')).failure,
          HarnessConnectionFailure.missingToken,
        );
        // A link that cannot be used is rejected locally: nothing reached the host.
        expect(server.requests, isEmpty);
      },
    );

    test('a refused launch token is reported as rejected', () async {
      final server = await _startHarness();
      server.launchStatus = HttpStatus.unauthorized;

      final result = await const HarnessConnectionProbe().check(
        server.launchUrl,
      );

      expect(result.failure, HarnessConnectionFailure.rejected);
      expect(server.requests.map((request) => request.line), <String>['GET /']);
    });

    test('a refused authenticated call is reported as rejected', () async {
      final server = await _startHarness();
      server.sessionListStatus = HttpStatus.forbidden;

      final result = await const HarnessConnectionProbe().check(
        server.launchUrl,
      );

      expect(result.failure, HarnessConnectionFailure.rejected);
      expect(server.requests, hasLength(3));
    });

    test(
      'a host that refuses the connection is reported as unreachable',
      () async {
        final reserved = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final port = reserved.port;
        await reserved.close(force: true);

        final result = await const HarnessConnectionProbe().check(
          'http://127.0.0.1:$port/?token=launch-token',
        );

        expect(result.failure, HarnessConnectionFailure.unreachable);
      },
    );

    test(
      'a server error on the launch link means the API is unavailable',
      () async {
        final server = await _startHarness();
        server.launchStatus = HttpStatus.internalServerError;

        final result = await const HarnessConnectionProbe().check(
          server.launchUrl,
        );

        expect(result.failure, HarnessConnectionFailure.apiUnavailable);
        expect(server.requests.map((request) => request.line), <String>[
          'GET /',
        ]);
      },
    );

    test(
      'a server error on the operator handshake means the API is unavailable',
      () async {
        final server = await _startHarness();
        server.connectStatus = HttpStatus.serviceUnavailable;

        final result = await const HarnessConnectionProbe().check(
          server.launchUrl,
        );

        expect(result.failure, HarnessConnectionFailure.apiUnavailable);
        expect(server.requests.map((request) => request.line), <String>[
          'GET /',
          'GET /connect',
        ]);
      },
    );

    test('a non-200 session list means the API is unavailable', () async {
      final server = await _startHarness();
      server.sessionListStatus = HttpStatus.internalServerError;

      final result = await const HarnessConnectionProbe().check(
        server.launchUrl,
      );

      expect(result.failure, HarnessConnectionFailure.apiUnavailable);
      expect(server.requests, hasLength(3));
    });

    test(
      'a JSON-RPC answer that is not ok means the API is unavailable',
      () async {
        final server = await _startHarness();
        server.sessionListAnswer = _SessionListAnswer.okFalse;

        final result = await const HarnessConnectionProbe().check(
          server.launchUrl,
        );

        // DSH answers a bad request with 200 and ok:false, so the status alone
        // cannot mean "connected".
        expect(result.failure, HarnessConnectionFailure.apiUnavailable);
      },
    );

    test(
      'a JSON-RPC answer for another request means the API is unavailable',
      () async {
        final server = await _startHarness();
        server.sessionListAnswer = _SessionListAnswer.wrongRpcId;

        final result = await const HarnessConnectionProbe().check(
          server.launchUrl,
        );

        expect(result.failure, HarnessConnectionFailure.apiUnavailable);
      },
    );

    test(
      'a host that accepts the request and never answers times out as unreachable',
      () async {
        final server = await _startHarness();
        server.stall = true;

        final result = await const HarnessConnectionProbe(
          timeout: Duration(seconds: 1),
        ).check(server.launchUrl);

        expect(result.failure, HarnessConnectionFailure.unreachable);
        // The timeout bounds the whole exchange, not one request: the host was
        // contacted, it just never answered.
        expect(server.requests.map((request) => request.line), <String>[
          'GET /',
        ]);
      },
    );
  });
}
