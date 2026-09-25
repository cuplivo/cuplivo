import 'dart:convert';
import 'dart:isolate';

import 'package:Cuplivo/core/services/logging/log_payload_elider.dart';
import 'package:Cuplivo/core/services/logging/log_redactor.dart';
import 'package:Cuplivo/core/services/network/request_logger.dart';
import 'package:Cuplivo/features/settings/logs/request_log_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses error response body into the viewer entry', () {
    const content = '''
[2026-08-13 20:40:00.000] [REQ 1] POST https://api.example.com/v1/chat
[2026-08-13 20:40:00.010] [RES 1] status=401
[2026-08-13 20:40:00.011] [RES 1] body={"error":{"message":"invalid api key"}}
[2026-08-13 20:40:00.012] [RES 1] done
''';

    final entries = RequestLogParser.parse(content);
    expect(entries, hasLength(1));
    expect(entries.single.statusCode, 401);
    expect(entries.single.responseBody, contains('invalid api key'));
    expect(entries.single.errors.single, contains('invalid api key'));
    expect(entries.single.hasError, isTrue);
  });

  test('parses redacted header JSON into a map', () {
    final headers = LogRedactor.redactHeaders({
      'Authorization': 'Bearer sk-abcdefghijklmnopqrstuvwxyz1234',
      'Content-Type': 'application/json',
    });
    final jsonText = const JsonEncoder.withIndent('  ').convert(headers);
    final content =
        '''
[2026-08-13 20:40:00.000] [REQ 1] POST https://api.example.com/v1/chat
[2026-08-13 20:40:00.001] [REQ 1] headers=$jsonText
[2026-08-13 20:40:00.010] [RES 1] status=200
[2026-08-13 20:40:00.011] [RES 1] done
''';

    final entries = RequestLogParser.parse(content);
    expect(entries, hasLength(1));
    expect(entries.single.requestHeaders, isNotNull);
    expect(
      entries.single.requestHeaders!['Authorization'],
      'Bearer sk-***1234(len=33)',
    );
    expect(entries.single.requestHeaders!['Content-Type'], 'application/json');
    expect(entries.single.warnings, isEmpty);
  });

  test('parses the request url lazily into a Uri', () {
    const content =
        '[2026-08-13 20:40:00.000] '
        '[REQ 1] POST https://api.example.com/v1/chat?stream=true\n';

    final entry = RequestLogParser.parse(content).single;

    expect(entry.rawUrl, 'https://api.example.com/v1/chat?stream=true');
    expect(entry.uri?.host, 'api.example.com');
    expect(entry.uri?.queryParameters['stream'], 'true');
    // Cached, not reparsed.
    expect(identical(entry.uri, entry.uri), isTrue);
  });

  group('unescape', () {
    test('reverses every escape RequestLogger.escape() writes', () {
      const raw = 'a\nb\rc\td\\e';
      expect(RequestLogParser.unescape(RequestLogger.escape(raw)), raw);
    });

    test('passes unknown escapes through untouched', () {
      expect(RequestLogParser.unescape(r'a\xb'), r'a\xb');
      expect(RequestLogParser.unescape(r'trailing\'), r'trailing\');
    });

    test('handles a backslash immediately before a known escape', () {
      // `\\` then `n`: an escaped backslash followed by a literal n.
      expect(RequestLogParser.unescape(r'\\n'), r'\n');
    });

    test('returns the empty string unchanged', () {
      expect(RequestLogParser.unescape(''), '');
    });
  });

  test('elides an inline base64 image out of the request body', () {
    final payload = 'A' * 20000;
    final body = jsonEncode({
      'messages': [
        {
          'content': [
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,$payload'},
            },
          ],
        },
      ],
    });
    final content =
        '[2026-08-13 20:40:00.000] [REQ 1] POST https://api.example.com/v1/chat\n'
        '[2026-08-13 20:40:00.001] [REQ 1] body=${RequestLogger.escape(body)}\n';

    final entry = RequestLogParser.parse(content).single;

    expect(entry.requestBody, isNot(contains(payload)));
    expect(entry.requestBody, contains('<omitted 20000 chars>'));
    expect(entry.attachments, hasLength(1));
    expect(entry.attachments.single.mime, 'image/png');
    expect(entry.attachments.single.base64Chars, 20000);
  });

  test('keeps the payload when elide is off', () {
    final payload = 'A' * 20000;
    final body = jsonEncode({'url': 'data:image/png;base64,$payload'});
    final content =
        '[2026-08-13 20:40:00.000] [REQ 1] POST https://api.example.com/v1/chat\n'
        '[2026-08-13 20:40:00.001] [REQ 1] body=${RequestLogger.escape(body)}\n';

    final entry = RequestLogParser.parse(content, elide: false).single;

    expect(entry.requestBody, contains(payload));
    // The switch controls the body text only — chips stay available.
    expect(entry.attachments.single.base64Chars, 20000);
  });

  test('reports attachments for a body the writer already elided', () {
    // The write path elides before the line hits disk, so the viewer sees the
    // placeholder rather than real base64.
    final body = jsonEncode({
      'url': 'data:image/png;base64,${LogPayloadElider.placeholder(20000)}',
      'source': {'media_type': 'image/webp', 'data': '<omitted 8000 chars>'},
    });
    final content =
        '[2026-08-13 20:40:00.000] [REQ 1] POST https://api.example.com/v1/chat\n'
        '[2026-08-13 20:40:00.001] [REQ 1] body=${RequestLogger.escape(body)}\n';

    final entry = RequestLogParser.parse(content).single;

    expect(entry.attachments, [
      const LogPayloadRef(mime: 'image/png', base64Chars: 20000),
      const LogPayloadRef(mime: 'image/webp', base64Chars: 8000),
    ]);
    // Nothing to rewrite: the body is passed through untouched.
    expect(entry.requestBody, contains('data:image/png;base64,<omitted'));
  });

  test('caps an oversized body and reports the dropped characters', () {
    final body = 'x' * 5000;
    final content =
        '[2026-08-13 20:40:00.000] [REQ 1] POST https://api.example.com/v1/chat\n'
        '[2026-08-13 20:40:00.001] [REQ 1] body=$body\n';

    final entry = RequestLogParser.parse(content, maxBodyChars: 1000).single;

    expect(entry.requestBody, hasLength(1000));
    expect(entry.requestBodyTruncated, 4000);
  });

  test('reassembles streamed chunks in order', () {
    final content = StringBuffer(
      '[2026-08-13 20:40:00.000] [REQ 1] POST https://api.example.com/v1/chat\n'
      '[2026-08-13 20:40:00.001] [RES 1] status=200\n',
    );
    for (var i = 0; i < 200; i++) {
      content.writeln('[2026-08-13 20:40:00.002] [RES 1] chunk=part$i;');
    }
    content.writeln('[2026-08-13 20:40:00.900] [RES 1] done');

    final entry = RequestLogParser.parse(content.toString()).single;

    expect(entry.responseBody, startsWith('part0;part1;'));
    expect(entry.responseBody, endsWith('part199;'));
    expect(entry.responseBodyTruncated, 0);
  });

  test('parsed entries survive an isolate hop', () async {
    // The viewer parses via compute(); a field that cannot be copied across
    // an isolate boundary would throw on every log open.
    const content =
        '[2026-08-13 20:40:00.000] [REQ 1] POST https://api.example.com/v1/chat\n'
        '[2026-08-13 20:40:00.001] [REQ 1] headers={"Accept":"application/json"}\n'
        '[2026-08-13 20:40:00.002] [REQ 1] body={"url":"data:image/png;base64,'
        'QUJDRA=="}\n'
        '[2026-08-13 20:40:00.010] [RES 1] status=500\n'
        '[2026-08-13 20:40:00.011] [RES 1] body={"error":"boom"}\n';

    final entries = await Isolate.run(() => RequestLogParser.parse(content));

    expect(entries, hasLength(1));
    final entry = entries.single;
    expect(entry.uri?.host, 'api.example.com');
    expect(entry.requestHeaders!['Accept'], 'application/json');
    expect(entry.statusCode, 500);
    expect(entry.errors.single, contains('boom'));
    expect(entry.startedAt, isNotNull);
  });

  test('elides a payload split across chunk boundaries', () {
    final payload = 'A' * 20000;
    final body = jsonEncode({'url': 'data:image/png;base64,$payload'});
    final escaped = RequestLogger.escape(body);
    final content = StringBuffer(
      '[2026-08-13 20:40:00.000] [REQ 1] POST https://api.example.com/v1/chat\n'
      '[2026-08-13 20:40:00.001] [RES 1] status=200\n',
    );
    for (var i = 0; i < escaped.length; i += 4096) {
      final end = (i + 4096).clamp(0, escaped.length);
      content.writeln(
        '[2026-08-13 20:40:00.002] [RES 1] chunk=${escaped.substring(i, end)}',
      );
    }

    final entry = RequestLogParser.parse(content.toString()).single;

    expect(entry.responseBody, isNot(contains(payload)));
    expect(entry.responseBody, contains('<omitted 20000 chars>'));
  });
}
