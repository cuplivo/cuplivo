import 'package:Cuplivo/core/services/api/chat_api_helpers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseTextAndImages', () {
    test('no ![ short-circuits without extracting images', () async {
      const raw = 'just a long conversation without markdown images';
      final parsed = await parseTextAndImages(
        raw,
        allowRemoteImages: false,
        allowLocalImages: false,
      );

      expect(parsed.text, raw);
      expect(parsed.images, isEmpty);
    });

    test('plain text is trimmed on the no-image path', () async {
      final parsed = await parseTextAndImages(
        '  hello  ',
        allowRemoteImages: false,
        allowLocalImages: false,
      );

      expect(parsed.text, 'hello');
      expect(parsed.images, isEmpty);
    });

    test('extracts a data-URL markdown image and omits it from text', () async {
      const raw = 'hello ![alt](data:image/png;base64,abc) world';
      final parsed = await parseTextAndImages(
        raw,
        allowRemoteImages: false,
        allowLocalImages: false,
      );

      expect(parsed.text, 'hello  world');
      expect(parsed.images, hasLength(1));
      expect(parsed.images.single.kind, 'data');
      expect(parsed.images.single.src, 'data:image/png;base64,abc');
    });

    test(
      'keeps disallowed remote markdown when remote images are off',
      () async {
        const raw = 'see ![cat](https://example.com/cat.png)';
        final parsed = await parseTextAndImages(
          raw,
          allowRemoteImages: false,
          allowLocalImages: false,
        );

        expect(parsed.text, raw);
        expect(parsed.images, isEmpty);
      },
    );

    test('does not extract images inside a fenced code block', () async {
      const raw = '```\n![alt](data:image/png;base64,abc)\n```';
      final parsed = await parseTextAndImages(
        raw,
        allowRemoteImages: false,
        allowLocalImages: false,
      );

      expect(parsed.images, isEmpty);
      expect(parsed.text, contains('!['));
    });

    test('does not extract images inside inline code', () async {
      const raw = 'use `![alt](data:image/png;base64,abc)` here';
      final parsed = await parseTextAndImages(
        raw,
        allowRemoteImages: false,
        allowLocalImages: false,
      );

      expect(parsed.images, isEmpty);
      expect(parsed.text, contains('!['));
    });

    test('skipImageParsing keeps markdown images as literal text', () async {
      const raw = 'hello ![x](data:image/png;base64,abc) world';
      final parsed = await parseTextAndImages(
        raw,
        allowRemoteImages: false,
        allowLocalImages: false,
        skipImageParsing: true,
      );

      expect(parsed.text, raw);
      expect(parsed.images, isEmpty);
    });

    test(
      'long document with a trailing markdown image parses correctly',
      () async {
        final raw =
            '${'plain line of text\n' * 11000}![x](data:image/png;base64,abc)';
        expect(raw.length, greaterThan(200000));

        final parsed = await parseTextAndImages(
          raw,
          allowRemoteImages: false,
          allowLocalImages: false,
        );

        expect(parsed.images, hasLength(1));
        expect(parsed.images.single.kind, 'data');
        expect(parsed.images.single.src, 'data:image/png;base64,abc');
        expect(parsed.text, startsWith('plain line of text'));
        expect(parsed.text, isNot(contains('![')));
      },
    );
  });

  group('shouldParseMarkdownImages', () {
    test('is false when skipImageParsing is set', () {
      expect(
        shouldParseMarkdownImages(
          'see ![x](data:image/png;base64,abc)',
          skipImageParsing: true,
        ),
        isFalse,
      );
    });

    test('detects markdown images when parsing is enabled', () {
      expect(
        shouldParseMarkdownImages(
          'see ![x](data:image/png;base64,abc)',
          skipImageParsing: false,
        ),
        isTrue,
      );
      expect(
        shouldParseMarkdownImages('no images here', skipImageParsing: false),
        isFalse,
      );
    });
  });
}
