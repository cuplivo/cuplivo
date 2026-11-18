import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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

    test('a Markdown title is not part of the URL', () {
      // `![](x.png "title")` is legal CommonMark. Keeping the title asked for a
      // picture at a path that does not exist, failing a reply that had one.
      expect(
        firstMarkdownImageUrl('![a](https://cdn.example/x.png "a title")'),
        'https://cdn.example/x.png',
      );
      expect(
        firstMarkdownImageUrl("![a](https://cdn.example/x.png 'a title')"),
        'https://cdn.example/x.png',
      );
      expect(
        firstMarkdownImageUrl('![a](https://cdn.example/x.png (a title))'),
        'https://cdn.example/x.png',
      );
    });
  });

  group('the images body', () {
    test('never carries a size, whatever ratio was asked for', () async {
      // The accepted size enum is per model — dall-e-3 rejects `1536x1024` with a
      // 400 — so the only safe value is none at all, which is what the app's own
      // images client sends. `aspect_ratio` still drives our skeleton and the
      // prompt; it must not pretend to know the provider's enum.
      final client = MockClient((request) async {
        expect(request.body, isNot(contains('"size"')));
        return http.Response('{"data":[{"b64_json":"${_pngBase64()}"}]}', 200);
      });
      for (final ratio in <String?>[
        '1:1',
        '3:2',
        '2:3',
        '16:9',
        'auto',
        null,
      ]) {
        final backend = ImagesApiBackend(
          baseUrl: 'https://api.test/v1',
          modelId: 'dall-e-3',
          headers: const {'Authorization': 'Bearer k'},
          client: client,
        );
        await backend.generate(
          ImageGenerationRequest(prompt: 'a cat', aspectRatio: ratio),
        );
      }
    });

    test(
      'references are refused before a request when the model takes no input '
      'images',
      () async {
        var sent = 0;
        final backend = ImagesApiBackend(
          baseUrl: 'https://api.test/v1',
          modelId: 'dall-e-3',
          headers: const {'Authorization': 'Bearer k'},
          supportsEdits: false,
          client: MockClient((_) async {
            sent += 1;
            return http.Response('{}', 200);
          }),
        );

        await expectLater(
          backend.generate(
            const ImageGenerationRequest(
              prompt: 'a cat',
              references: [ImageReference(uri: '/tmp/ref.png')],
            ),
          ),
          throwsA(
            isA<ImageBackendException>().having(
              (error) => error.failure,
              'failure',
              ImageBackendFailure.badPayload,
            ),
          ),
        );
        expect(sent, 0, reason: 'the provider would only answer 400');
      },
    );
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
