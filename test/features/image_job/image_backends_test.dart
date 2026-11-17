import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/image_job/services/image_backends.dart';

/// Bytes for a tiny PNG header: enough to prove the decode path ran.
String _pngBase64() {
  return base64Encode(
    Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
  );
}

void main() {
  group('parseImagesGenerationResponse', () {
    test('decodes b64_json as PNG when the entry declares no format', () {
      final payload = parseImagesGenerationResponse({
        'data': [
          {'b64_json': _pngBase64()},
        ],
      });
      expect(payload, isA<InlineImagePayload>());
      final inline = payload! as InlineImagePayload;
      expect(inline.base64, _pngBase64());
      expect(inline.mime, 'image/png');
    });

    test('honours the declared output format for b64_json', () {
      final payload =
          parseImagesGenerationResponse({
                'data': [
                  {'b64_json': _pngBase64(), 'output_format': 'webp'},
                ],
              })
              as InlineImagePayload;
      expect(payload.mime, 'image/webp');
    });

    test('prefers b64_json over url in the same entry', () {
      final payload = parseImagesGenerationResponse({
        'data': [
          {'b64_json': _pngBase64(), 'url': 'https://cdn.example/a.png'},
        ],
      });
      expect(payload, isA<InlineImagePayload>());
    });

    test('takes the url entry, with the mime its extension implies', () {
      final payload =
          parseImagesGenerationResponse({
                'data': [
                  {'url': 'https://cdn.example/a.jpg'},
                ],
              })
              as RemoteImagePayload;
      expect(payload.url, 'https://cdn.example/a.jpg');
      expect(payload.mime, 'image/jpeg');
    });

    test('an entry with neither field falls through to the next one', () {
      final payload =
          parseImagesGenerationResponse({
                'data': [
                  {'revised_prompt': 'only a prompt'},
                  {'url': 'https://cdn.example/b.png'},
                ],
              })
              as RemoteImagePayload;
      expect(payload.url, 'https://cdn.example/b.png');
    });

    test('empty data, malformed body and no body all mean "no image"', () {
      expect(parseImagesGenerationResponse({'data': <Object?>[]}), isNull);
      expect(parseImagesGenerationResponse({'data': 'nope'}), isNull);
      expect(parseImagesGenerationResponse(const <String, Object?>{}), isNull);
      expect(parseImagesGenerationResponse('not a map'), isNull);
      expect(parseImagesGenerationResponse(null), isNull);
    });
  });

  group('chatReplyText', () {
    test('a string content is the prose', () {
      expect(chatReplyText('  hello  '), 'hello');
    });

    test('a parts list keeps only its text parts', () {
      expect(
        chatReplyText([
          {'type': 'text', 'text': 'one'},
          {
            'type': 'image_url',
            'image_url': {'url': 'data:x'},
          },
          {'type': 'text', 'text': 'two'},
        ]),
        'one\ntwo',
      );
    });

    test('an absent or unreadable content is empty, not a throw', () {
      expect(chatReplyText(null), '');
      expect(chatReplyText(<Object?>[]), '');
    });
  });

  group('firstMarkdownImageUrl', () {
    test('takes the first image link in the prose', () {
      expect(
        firstMarkdownImageUrl(
          'Here you go:\n\n![a sunset](https://cdn.example/sunset.png)\n\n'
          'and another ![x](https://cdn.example/x.png)',
        ),
        'https://cdn.example/sunset.png',
      );
    });

    test('accepts the angle-bracket form and a data: URL', () {
      expect(
        firstMarkdownImageUrl('![x](<https://cdn.example/x.png>)'),
        'https://cdn.example/x.png',
      );
      expect(
        firstMarkdownImageUrl('![x](data:image/png;base64,AAAA)'),
        'data:image/png;base64,AAAA',
      );
    });

    test('a plain link or a bare URL is not a picture', () {
      expect(firstMarkdownImageUrl('no picture here'), isNull);
      expect(
        firstMarkdownImageUrl('[a link](https://example.com/x.png)'),
        isNull,
      );
      expect(firstMarkdownImageUrl('![](   )'), isNull);
      expect(firstMarkdownImageUrl(null), isNull);
    });
  });

  group('imagesApiSize', () {
    test('auto and unmapped ratios are omitted so the backend decides', () {
      expect(imagesApiSize(null), isNull);
      expect(imagesApiSize('auto'), isNull);
      expect(imagesApiSize('16:9'), isNull);
    });

    test('the three ratios this shape accepts map to their sizes', () {
      expect(imagesApiSize('1:1'), '1024x1024');
      expect(imagesApiSize('3:2'), '1536x1024');
      expect(imagesApiSize('2:3'), '1024x1536');
    });
  });

  group('decodeDataUrl', () {
    test('base64 payloads decode with their declared mime', () {
      final result = decodeDataUrl('data:image/jpeg;base64,${_pngBase64()}')!;
      expect(result.mime, 'image/jpeg');
      expect(result.bytes.length, 8);
    });

    test('a non-data URL is not handled here', () {
      expect(decodeDataUrl('https://cdn.example/a.png'), isNull);
      expect(decodeDataUrl('data:'), isNull);
    });
  });
}
