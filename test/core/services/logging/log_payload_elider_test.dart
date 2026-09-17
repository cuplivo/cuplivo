import 'dart:convert';

import 'package:Cuplivo/core/services/logging/log_payload_elider.dart';
import 'package:flutter_test/flutter_test.dart';

String _b64(int chars) => 'A' * chars;

void main() {
  group('elideDataUris', () {
    test('replaces an OpenAI-style data URI with a placeholder', () {
      final payload = _b64(20000);
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

      final out = LogPayloadElider.elide(body);

      expect(out, isNot(contains(payload)));
      expect(out, contains('data:image/png;base64,<omitted 20000 chars>'));
      expect(out.length, lessThan(500));
    });

    test('keeps the result decodable as JSON', () {
      final body = jsonEncode({'url': 'data:image/jpeg;base64,${_b64(9000)}'});

      expect(() => jsonDecode(LogPayloadElider.elide(body)), returnsNormally);
    });
  });

  group('elideBareBase64', () {
    test('replaces a Claude image payload', () {
      final payload = _b64(12000);
      final body = jsonEncode({
        'content': [
          {
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': 'image/png',
              'data': payload,
            },
          },
        ],
      });

      final out = LogPayloadElider.elide(body);

      expect(out, isNot(contains(payload)));
      expect(out, contains('<omitted 12000 chars>'));
      expect(() => jsonDecode(out), returnsNormally);
    });

    test('replaces a Gemini inline_data payload', () {
      final payload = _b64(8192);
      final body = jsonEncode({
        'contents': [
          {
            'parts': [
              {
                'inline_data': {'mime_type': 'image/webp', 'data': payload},
              },
            ],
          },
        ],
      });

      final out = LogPayloadElider.elide(body);

      expect(out, isNot(contains(payload)));
      expect(() => jsonDecode(out), returnsNormally);
    });

    test('leaves short base64 alone', () {
      final body = jsonEncode({'data': _b64(1024)});
      expect(LogPayloadElider.elide(body), body);
    });

    test('leaves long natural-language text alone', () {
      final prose = List.filled(2000, 'the quick brown fox').join(' ');
      final body = jsonEncode({'content': prose});

      expect(body.length, greaterThan(LogPayloadElider.bareBase64Threshold));
      expect(LogPayloadElider.elide(body), body);
    });

    test('leaves a long escaped-newline string alone', () {
      final text = List.filled(600, 'line of output').join('\n');
      final body = jsonEncode({'content': text});

      expect(body.length, greaterThan(LogPayloadElider.bareBase64Threshold));
      expect(LogPayloadElider.elide(body), body);
    });
  });

  group('describe', () {
    test('reports mime and size for a data URI', () {
      final body = 'data:image/png;base64,${_b64(4000)}';

      final refs = LogPayloadElider.describe(body);

      expect(refs, hasLength(1));
      expect(refs.single.mime, 'image/png');
      expect(refs.single.base64Chars, 4000);
      expect(refs.single.byteLength, 3000);
    });

    test('picks up the mime sibling of a bare payload', () {
      final body = jsonEncode({
        'inline_data': {'mime_type': 'image/webp', 'data': _b64(6000)},
      });

      final refs = LogPayloadElider.describe(body);

      expect(refs, hasLength(1));
      expect(refs.single.mime, 'image/webp');
      expect(refs.single.base64Chars, 6000);
    });

    test('falls back when no mime is nearby', () {
      final body = jsonEncode({'blob': _b64(5000)});

      final refs = LogPayloadElider.describe(body);

      expect(refs.single.mime, LogPayloadElider.fallbackMime);
    });

    test('reports every payload in a multi-image request', () {
      final body = jsonEncode({
        'a': 'data:image/png;base64,${_b64(4100)}',
        'b': 'data:image/gif;base64,${_b64(4200)}',
      });

      final refs = LogPayloadElider.describe(body);

      expect(refs.map((r) => r.mime), ['image/png', 'image/gif']);
    });

    test('returns nothing for a payload-free body', () {
      expect(LogPayloadElider.describe('{"model":"gpt-4o"}'), isEmpty);
    });

    test('recognises a data URI the writer already elided', () {
      final body = jsonEncode({
        'url': 'data:image/png;base64,${LogPayloadElider.placeholder(20000)}',
      });

      expect(LogPayloadElider.describe(body), [
        const LogPayloadRef(mime: 'image/png', base64Chars: 20000),
      ]);
    });

    test('recognises a bare payload the writer already elided', () {
      final body = jsonEncode({
        'inline_data': {
          'mime_type': 'image/webp',
          'data': LogPayloadElider.placeholder(6000),
        },
      });

      expect(LogPayloadElider.describe(body), [
        const LogPayloadRef(mime: 'image/webp', base64Chars: 6000),
      ]);
    });

    test('ignores prose that merely resembles a placeholder', () {
      expect(LogPayloadElider.describe('{"a":"<omitted chars>"}'), isEmpty);
      expect(LogPayloadElider.describe('{"a":"<omitted 12 bytes>"}'), isEmpty);
    });
  });

  group('process', () {
    test('reports without rewriting when rewrite is off', () {
      final payload = _b64(20000);
      final body = jsonEncode({'url': 'data:image/png;base64,$payload'});

      final result = LogPayloadElider.process(body, rewrite: false);

      expect(result.text, body);
      expect(result.refs.single.base64Chars, 20000);
    });

    test('is idempotent — a second pass finds the same payloads', () {
      final body = jsonEncode({
        'url': 'data:image/png;base64,${_b64(9000)}',
        'source': {'media_type': 'image/webp', 'data': _b64(6000)},
      });

      final first = LogPayloadElider.process(body);
      final second = LogPayloadElider.process(first.text);

      expect(second.text, first.text);
      expect(second.refs, first.refs);
    });
  });
}
