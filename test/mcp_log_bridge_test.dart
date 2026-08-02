import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart' as mcp;

import 'package:Cuplivo/core/services/network/mcp_log_bridge.dart';
import 'package:Cuplivo/core/services/network/request_logger.dart';

void main() {
  final lines = <String>[];

  void send(mcp.McpLogEvent e) => McpLogBridge.onEvent(e);

  mcp.McpLogEvent request(
    String label,
    int rpcId,
    String method, {
    Map<String, String>? tags,
    Object? payload,
  }) => mcp.McpLogEvent(
    server: label,
    direction: 'send',
    kind: 'request',
    id: rpcId,
    method: method,
    payload: payload ?? const <String, dynamic>{},
    tags: tags,
  );

  mcp.McpLogEvent response(
    String label,
    int rpcId,
    String method, {
    Map<String, String>? tags,
    Object? payload,
  }) => mcp.McpLogEvent(
    server: label,
    direction: 'receive',
    kind: 'response',
    id: rpcId,
    method: method,
    payload: payload ?? const <String, dynamic>{},
    tags: tags,
  );

  mcp.McpLogEvent error(
    String label,
    int rpcId,
    String method, {
    Map<String, String>? tags,
    int code = -32004,
    String message = 'tool failed',
  }) => mcp.McpLogEvent(
    server: label,
    direction: 'receive',
    kind: 'error-response',
    id: rpcId,
    method: method,
    payload: {'code': code, 'message': message},
    tags: tags,
  );

  mcp.McpLogEvent lifecycle(String label, String payload) => mcp.McpLogEvent(
    server: label,
    direction: 'receive',
    kind: 'lifecycle',
    payload: payload,
  );

  setUp(() {
    lines.clear();
    McpLogBridge.logSinkOverride = lines.add;
    // Synchronous map write before the awaited sink sync.
    RequestLogger.setCategoryEnabled(RequestLogger.catMcp, true);
  });

  tearDown(() async {
    McpLogBridge.logSinkOverride = null;
    McpLogBridge.resetForTesting();
    await RequestLogger.setCategoryEnabled(RequestLogger.catMcp, false);
  });

  group('McpLogBridge pairing', () {
    test('request/response pair emits two lines with one shared log id', () {
      final before = RequestLogger.nextRequestId();
      send(request('srv', 1, 'tools/call', payload: {'name': 'fetch'}));
      send(response('srv', 1, 'tools/call', payload: {'ok': true}));
      expect(lines, hasLength(2));
      final reqLine = lines[0];
      final resLine = lines[1];
      expect(reqLine, contains('[MCP REQ '));
      expect(reqLine, contains('method=tools/call'));
      expect(resLine, contains('[MCP RES '));
      expect(resLine, contains('method=tools/call'));
      final reqId = RegExp(r'\[MCP REQ (\d+)\]').firstMatch(reqLine)!.group(1)!;
      final resId = RegExp(r'\[MCP RES (\d+)\]').firstMatch(resLine)!.group(1)!;
      expect(reqId, resId);
      expect(int.parse(reqId), greaterThan(before));
    });

    test('request without response still emits the request line', () {
      send(request('srv', 1, 'tools/list'));
      expect(lines, hasLength(1));
      expect(lines.single, contains('[MCP REQ '));
      expect(lines.single, contains('method=tools/list'));
    });

    test('server-initiated request pairs with our response', () {
      final incoming = mcp.McpLogEvent(
        server: 'srv',
        direction: 'receive',
        kind: 'request',
        id: 'abc',
        method: 'sampling/createMessage',
        payload: const <String, dynamic>{},
      );
      final reply = mcp.McpLogEvent(
        server: 'srv',
        direction: 'send',
        kind: 'response',
        id: 'abc',
        method: 'sampling/createMessage',
        payload: const <String, dynamic>{'role': 'assistant'},
      );
      send(incoming);
      send(reply);
      expect(lines, hasLength(2));
      expect(lines[0], contains('[MCP REQ '));
      expect(lines[0], contains('method=sampling/createMessage'));
      expect(lines[1], contains('[MCP RES '));
      expect(lines[1], contains('method=sampling/createMessage'));
    });

    test('notifications emit direction-shaped lines', () {
      final sent = mcp.McpLogEvent(
        server: 'srv',
        direction: 'send',
        kind: 'notification',
        method: 'notifications/initialized',
        payload: const <String, dynamic>{},
      );
      final received = mcp.McpLogEvent(
        server: 'srv',
        direction: 'receive',
        kind: 'notification',
        method: 'notifications/progress',
        payload: const <String, dynamic>{'p': 0.5},
      );
      send(sent);
      send(received);
      expect(lines, hasLength(2));
      expect(lines[0], contains('[MCP REQ '));
      expect(lines[0], contains('method=notifications/initialized'));
      expect(lines[1], contains('[MCP RES '));
      expect(lines[1], contains('method=notifications/progress'));
    });
  });

  group('McpLogBridge heartbeat semantics', () {
    mcp.McpLogEvent heartbeat(String label, int rpcId) => request(
      label,
      rpcId,
      'tools/list',
      tags: const {'reason': 'heartbeat'},
      payload: const <String, dynamic>{},
    );

    test('successful heartbeat is fully suppressed', () {
      send(heartbeat('srv', 1));
      send(
        response('srv', 1, 'tools/list', tags: const {'reason': 'heartbeat'}),
      );
      expect(lines, isEmpty);
    });

    test('failed heartbeat logs the buffered request plus the error', () {
      send(heartbeat('srv', 1));
      send(error('srv', 1, 'tools/list', tags: const {'reason': 'heartbeat'}));
      expect(lines, hasLength(2));
      expect(lines[0], contains('[MCP REQ '));
      expect(lines[0], contains('method=tools/list'));
      expect(lines[1], contains('[MCP RES '));
      expect(lines[1], contains('error='));
    });

    test('rate-limit heartbeat failure is suppressed (code)', () {
      send(heartbeat('srv', 1));
      send(
        error(
          'srv',
          1,
          'tools/list',
          tags: const {'reason': 'heartbeat'},
          code: -32106,
          message: 'rate limited',
        ),
      );
      expect(lines, isEmpty);
    });

    test('rate-limit heartbeat failure is suppressed (429 message)', () {
      send(heartbeat('srv', 1));
      send(
        error(
          'srv',
          1,
          'tools/list',
          tags: const {'reason': 'heartbeat'},
          code: -32000,
          message: 'HTTP 429 Too Many Requests',
        ),
      );
      expect(lines, isEmpty);
    });

    test('a later buffered heartbeat failure is not stale', () {
      send(heartbeat('srv', 1));
      send(heartbeat('srv', 2));
      send(
        response('srv', 1, 'tools/list', tags: const {'reason': 'heartbeat'}),
      );
      expect(lines, isEmpty, reason: 'first heartbeat succeeded');
      send(error('srv', 2, 'tools/list', tags: const {'reason': 'heartbeat'}));
      expect(lines, hasLength(2), reason: 'second heartbeat failed');
    });
  });

  group('McpLogBridge write-time suppression', () {
    test('identical error repeats are suppressed after the first', () {
      send(request('srv', 1, 'tools/call'));
      send(error('srv', 1, 'tools/call'));
      send(request('srv', 2, 'tools/call'));
      send(error('srv', 2, 'tools/call'));
      // REQ1, error1, REQ2 — the repeated error is suppressed.
      expect(lines, hasLength(3));
      expect(lines.where((l) => l.contains('error=')), hasLength(1));
    });

    test('distinct errors are all logged', () {
      for (var i = 1; i <= 3; i++) {
        send(request('srv', i, 'tools/call'));
        send(error('srv', i, 'tools/call', message: 'err$i'));
      }
      expect(lines, hasLength(6));
      expect(lines.where((l) => l.contains('error=')), hasLength(3));
    });

    test('cap overflow flushes a summary and dedupe restarts cleanly', () {
      // 20 distinct errors fill the cap.
      for (var i = 1; i <= 20; i++) {
        send(request('srv', i, 'tools/call'));
        send(error('srv', i, 'tools/call', message: 'err$i'));
      }
      // 21st distinct error triggers the cap flush: WARN + error line.
      send(request('srv', 21, 'tools/call'));
      send(error('srv', 21, 'tools/call', message: 'err21'));
      expect(lines, hasLength(43));
      final warn = lines[41];
      expect(warn, contains('[MCP WARN]'));
      expect(warn, contains('[cap]'));
      expect(warn, contains('err1'));
      expect(lines[42], contains('error='));
      // Repeating error #21 after the flush must NOT produce a new line
      // (regression: the cap flush must not leave a stale map behind).
      send(request('srv', 22, 'tools/call'));
      send(error('srv', 22, 'tools/call', message: 'err21'));
      expect(lines, hasLength(44), reason: 'repeat suppressed after cap');
    });

    test('recovery flushes a summary on the next successful response', () {
      send(request('srv', 1, 'tools/call'));
      send(error('srv', 1, 'tools/call'));
      send(request('srv', 2, 'tools/call'));
      send(response('srv', 2, 'tools/call', payload: const {'ok': true}));
      // REQ1, error1, REQ2, WARN[recovered], RES.
      expect(lines, hasLength(5));
      expect(lines[3], contains('[MCP WARN]'));
      expect(lines[3], contains('[recovered]'));
      expect(lines[4], contains('result='));
    });

    test('disconnect flushes and clears state for that server', () {
      send(request('srv', 1, 'tools/call'));
      send(error('srv', 1, 'tools/call'));
      send(lifecycle('srv', 'disconnected'));
      // REQ1, error1, LIFE, WARN[disconnect].
      expect(lines, hasLength(4));
      expect(lines[2], contains('[MCP LIFE]'));
      expect(lines[3], contains('[MCP WARN]'));
      expect(lines[3], contains('[disconnect]'));
      // State cleared: the same error logs again instead of being
      // suppressed.
      send(request('srv', 2, 'tools/call'));
      send(error('srv', 2, 'tools/call'));
      expect(lines, hasLength(6));
      expect(lines[5], contains('error='));
    });

    test('suppression state is isolated per server label', () {
      send(request('a', 1, 'tools/call'));
      send(error('a', 1, 'tools/call'));
      send(request('a', 2, 'tools/call'));
      send(error('a', 2, 'tools/call'));
      send(request('b', 1, 'tools/call'));
      send(error('b', 1, 'tools/call'));
      // a: REQ1, err1, REQ2 (repeat suppressed); b: REQ1, err1.
      expect(lines, hasLength(5));
      expect(lines.where((l) => l.contains('error=')), hasLength(2));
    });
  });

  group('McpLogBridge saveOutput gating', () {
    tearDown(() {
      RequestLogger.saveOutput = true;
    });

    test('list-method results are omitted when saveOutput is off', () {
      RequestLogger.saveOutput = false;
      send(request('srv', 1, 'tools/list'));
      send(
        response('srv', 1, 'tools/list', payload: const {'tools': <dynamic>[]}),
      );
      expect(lines, hasLength(2));
      expect(lines[1], contains('result=<omitted (saveOutput off)>'));
    });

    test('tools/call results are always logged even with saveOutput off', () {
      RequestLogger.saveOutput = false;
      send(request('srv', 1, 'tools/call'));
      send(response('srv', 1, 'tools/call', payload: const {'ok': true}));
      expect(lines, hasLength(2));
      expect(lines[1], contains('result='));
      expect(lines[1], isNot(contains('omitted')));
    });

    test('list-method results are logged when saveOutput is on', () {
      RequestLogger.saveOutput = true;
      send(request('srv', 1, 'tools/list'));
      send(
        response('srv', 1, 'tools/list', payload: const {'tools': <dynamic>[]}),
      );
      expect(lines, hasLength(2));
      expect(lines[1], contains('result='));
      expect(lines[1], isNot(contains('omitted')));
    });
  });
}
