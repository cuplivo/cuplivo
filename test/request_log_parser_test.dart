import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/settings/logs/request_log_parser.dart';

void main() {
  group('RequestLogParser legacy LLM lines', () {
    test('parses REQ start / status / chunks into one entry', () {
      final log = '''
[2026-08-02 10:00:00.000] [REQ 1] POST https://api.example.com/chat
[2026-08-02 10:00:00.001] [REQ 1] body=hello world
[2026-08-02 10:00:00.100] [RES 1] status=200
[2026-08-02 10:00:00.200] [RES 1] chunk=first
[2026-08-02 10:00:00.300] [RES 1] chunk=second
[2026-08-02 10:00:00.400] [RES 1] done
''';
      final entries = RequestLogParser.parse(log);
      expect(entries, hasLength(1));
      final e = entries.first;
      expect(e.category, 'llm');
      expect(e.id, 1);
      expect(e.method, 'POST');
      expect(e.uri, Uri.parse('https://api.example.com/chat'));
      expect(e.requestBody, 'hello world');
      expect(e.statusCode, 200);
      expect(e.responseBody, 'firstsecond');
      expect(e.hasError, isFalse);
    });
  });

  group('RequestLogParser category prefixes', () {
    test('search lines carry category search with response body', () {
      final log = '''
[2026-08-02 10:00:00.000] [SRCH REQ 10] POST https://api.tavily.com/search
[2026-08-02 10:00:00.001] [SRCH REQ 10] body={"query":"hi"}
[2026-08-02 10:00:00.100] [SRCH RES 10] status=200
[2026-08-02 10:00:00.200] [SRCH RES 10] body={"results":[]}
''';
      final entries = RequestLogParser.parse(log);
      expect(entries, hasLength(1));
      final e = entries.first;
      expect(e.category, 'search');
      expect(e.requestBody, '{"query":"hi"}');
      expect(e.statusCode, 200);
      expect(e.responseBody, '{"results":[]}');
    });

    test('tts lines carry category tts and never a response body', () {
      final log = '''
[2026-08-02 10:00:00.000] [TTS REQ 11] POST https://api.openai.com/v1/audio/speech
[2026-08-02 10:00:00.001] [TTS REQ 11] body={"input":"hi"}
[2026-08-02 10:00:00.100] [TTS RES 11] status=200
[2026-08-02 10:00:00.200] [TTS RES 11] error=boom
''';
      final entries = RequestLogParser.parse(log);
      expect(entries, hasLength(1));
      final e = entries.first;
      expect(e.category, 'tts');
      expect(e.requestBody, '{"input":"hi"}');
      expect(e.statusCode, 200);
      expect(e.errors, ['boom']);
      expect(e.hasError, isTrue);
    });

    test('mcp request/response pair is parsed with method and bodies', () {
      final log = '''
[2026-08-02 10:00:00.000] [MCP REQ 20] method=tools/call body={"name":"fetch"}
[2026-08-02 10:00:00.100] [MCP RES 20] method=tools/call result={"ok":true}
''';
      final entries = RequestLogParser.parse(log);
      expect(entries, hasLength(1));
      final e = entries.first;
      expect(e.category, 'mcp');
      expect(e.id, 20);
      expect(e.method, 'tools/call');
      expect(e.requestBody, '{"name":"fetch"}');
      expect(e.responseBody, '{"ok":true}');
      expect(e.rawUrl, isNull);
      expect(e.uri, isNull);
      expect(e.statusCode, isNull);
      expect(e.hasError, isFalse);
    });

    test('mcp error response lands in errors and flags hasError', () {
      final log = '''
[2026-08-02 10:00:00.000] [MCP REQ 21] method=tools/list body={}
[2026-08-02 10:00:00.100] [MCP RES 21] method=tools/list error={"code":-32106,"message":"rate limit"}
''';
      final entries = RequestLogParser.parse(log);
      expect(entries, hasLength(1));
      final e = entries.first;
      expect(e.category, 'mcp');
      expect(e.errors, ['{"code":-32106,"message":"rate limit"}']);
      expect(e.hasError, isTrue);
    });

    test('mcp response without a matching request still creates an entry', () {
      final log = '''
[2026-08-02 10:00:00.100] [MCP RES 99] method=notifications/progress body={"p":0.5}
''';
      final entries = RequestLogParser.parse(log);
      expect(entries, hasLength(1));
      final e = entries.first;
      expect(e.category, 'mcp');
      expect(e.method, 'notifications/progress');
      expect(e.responseBody, '{"p":0.5}');
    });

    test('same numeric id in different categories is not merged', () {
      final log = '''
[2026-08-02 10:00:00.000] [REQ 7] POST https://api.example.com/chat
[2026-08-02 10:00:00.100] [MCP REQ 7] method=tools/list body={}
''';
      final entries = RequestLogParser.parse(log);
      expect(entries, hasLength(2));
      expect(entries.map((e) => e.category).toSet(), {'llm', 'mcp'});
    });
  });

  group('RequestLogParser unknown lines', () {
    test('lifecycle and warning lines are ignored', () {
      final log = '''
[2026-08-02 10:00:00.000] [MCP LIFE] my-server connected
[2026-08-02 10:00:00.100] [MCP WARN] my-server suppressed 3 repeated errors since 2026-08-02 09:00:00.000 [recovered]: -32106|x
[2026-08-02 10:00:00.200] [REQ 1] POST https://api.example.com/chat
''';
      final entries = RequestLogParser.parse(log);
      expect(entries, hasLength(1));
      expect(entries.first.category, 'llm');
    });
  });
}
