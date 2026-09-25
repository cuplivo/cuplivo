import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/core/services/migration/legacy_message_content_decoder.dart';
import 'package:Cuplivo/utils/sandbox_path_resolver.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('legacy_decoder_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<File> writeTemp(String name, List<int> bytes) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  test(
    'normal image and file markers convert with surrounding text merged',
    () async {
      final image = await writeTemp('a.png', <int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
      ]);
      final pdf = await writeTemp('spec.pdf', <int>[
        0x25,
        0x50,
        0x44,
        0x46,
        0x2D,
      ]); // %PDF-
      final content = [
        '帮我看看',
        '[image:${image.path}]',
        '[file:${pdf.path}|spec.pdf|application/pdf]',
        '谢谢',
      ].join('\n');

      final result = await decodeLegacyContent(content);

      expect(result.converted, 2);
      expect(result.malformed, 0);
      expect(result.missingFiles, 0);
      expect(result.parts, hasLength(4));
      expect(result.parts[0], isA<TextPart>());
      expect((result.parts[0] as TextPart).text, '帮我看看');
      expect(result.parts[1], isA<ImagePart>());
      final imagePart = result.parts[1] as ImagePart;
      expect(imagePart.uri, image.path);
      expect(imagePart.mime, 'image/png');
      expect(imagePart.unavailable, isFalse);
      expect(result.parts[2], isA<FilePart>());
      final filePart = result.parts[2] as FilePart;
      expect(filePart.uri, pdf.path);
      expect(filePart.name, 'spec.pdf');
      expect(filePart.mime, 'application/pdf');
      expect(filePart.unavailable, isFalse);
      expect(result.parts[3], isA<TextPart>());
      expect((result.parts[3] as TextPart).text, '\n谢谢');
      expect(
        result.parts.whereType<TextPart>().map((part) => part.text).join(),
        '帮我看看\n谢谢',
      );
    },
  );

  test(
    'filename containing ] or | stays as text and counts malformed',
    () async {
      final content = [
        '[file:/tmp/a|name].pdf|application/pdf]',
        '[file:/tmp/a|na|me|application/pdf]',
      ].join('\n');

      final result = await decodeLegacyContent(content);

      expect(result.converted, 0);
      expect(result.malformed, 2);
      expect(result.parts, hasLength(1));
      expect(result.parts.single, isA<TextPart>());
      expect((result.parts.single as TextPart).text, content);
    },
  );

  test('inline markers remain plain text', () async {
    const content = 'see [image:/tmp/a.png] please';
    final result = await decodeLegacyContent(content);

    expect(result.converted, 0);
    expect(result.malformed, 0);
    expect(result.parts, hasLength(1));
    expect((result.parts.single as TextPart).text, content);
  });

  test('data URL image marker converts using declared mime', () async {
    const content = '[image:data:image/gif;base64,R0lGODlhAQABAAAAACw=]';
    final result = await decodeLegacyContent(content);

    expect(result.converted, 1);
    expect(result.missingFiles, 0);
    final image = result.parts.single as ImagePart;
    expect(image.uri.startsWith('data:image/gif;base64,'), isTrue);
    expect(image.mime, 'image/gif');
    expect(image.unavailable, isFalse);
  });

  test('missing local file still creates unavailable part', () async {
    final missing = '${tempDir.path}/gone.png';
    final content = '[image:$missing]';
    final result = await decodeLegacyContent(content);

    expect(result.converted, 1);
    expect(result.missingFiles, 1);
    final image = result.parts.single as ImagePart;
    expect(image.uri, missing);
    expect(image.unavailable, isTrue);
    expect(image.mime, 'image/png'); // extension fallback
  });

  test('empty content yields empty parts and zero stats', () async {
    final result = await decodeLegacyContent('');
    expect(result.parts, isEmpty);
    expect(result.converted, 0);
    expect(result.malformed, 0);
    expect(result.missingFiles, 0);
  });

  test('pure markers with no text', () async {
    final image = await writeTemp('only.png', <int>[0x89, 0x50, 0x4E, 0x47]);
    final content = '[image:${image.path}]';
    final result = await decodeLegacyContent(content);

    expect(result.parts, hasLength(1));
    expect(result.parts.single, isA<ImagePart>());
    expect(result.converted, 1);
  });

  test('markers inside fenced code blocks remain text', () async {
    final content = [
      'before',
      '```',
      '[image:/tmp/in-code.png]',
      '```',
      'after',
    ].join('\n');

    final result = await decodeLegacyContent(content);

    expect(result.converted, 0);
    expect(result.malformed, 0);
    expect(result.parts, hasLength(1));
    expect((result.parts.single as TextPart).text, content);
  });

  test('http(s) image marker converts without missingFiles', () async {
    const content = '[image:https://example.com/a.png]';
    final result = await decodeLegacyContent(content);

    expect(result.converted, 1);
    expect(result.missingFiles, 0);
    final image = result.parts.single as ImagePart;
    expect(image.uri, 'https://example.com/a.png');
    expect(image.unavailable, isFalse);
    expect(image.mime, 'image/png');
  });

  test('file marker with wrong segment count stays text', () async {
    const content = '[file:/tmp/a.pdf|only-name]';
    final result = await decodeLegacyContent(content);

    expect(result.converted, 0);
    expect(result.malformed, 1);
    expect((result.parts.single as TextPart).text, content);
  });

  test('decode is idempotent for the same input', () async {
    final image = await writeTemp('idem.png', <int>[0x89, 0x50, 0x4E, 0x47]);
    final content = 'x\n[image:${image.path}]\ny';
    final first = await decodeLegacyContent(content);
    final second = await decodeLegacyContent(content);

    expect(second.converted, first.converted);
    expect(second.malformed, first.malformed);
    expect(second.missingFiles, first.missingFiles);
    expect(second.parts.length, first.parts.length);
    for (var i = 0; i < first.parts.length; i++) {
      expect(second.parts[i].kind, first.parts[i].kind);
      expect(second.parts[i].encodePayload(), first.parts[i].encodePayload());
    }
  });

  test(
    'existing image/file parts skip re-parse (message-level idempotency)',
    () async {
      const existing = [
        TextPart('already structured'),
        ImagePart(uri: '/tmp/a.png', mime: 'image/png'),
      ];
      final result = await decodeLegacyContent(
        'ignored\n[image:/tmp/other.png]',
        existingParts: existing,
      );

      expect(result.converted, 0);
      expect(result.malformed, 0);
      expect(result.missingFiles, 0);
      expect(result.parts, same(existing));
    },
  );

  test(
    'content sniff overrides misleading extension for local image',
    () async {
      // JPEG magic bytes saved as .bin
      final file = await writeTemp('weird.bin', <int>[0xFF, 0xD8, 0xFF, 0xE0]);
      final content = '[image:${file.path}]';
      final result = await decodeLegacyContent(content);

      final image = result.parts.single as ImagePart;
      expect(image.mime, 'image/jpeg');
    },
  );

  test('unrecognized marker-like lines are preserved, never dropped', () async {
    const content = '[image:]\n[file:]\nnot a marker';
    final result = await decodeLegacyContent(content);

    expect(result.converted, 0);
    expect(result.malformed, 2);
    final text = (result.parts.single as TextPart).text;
    expect(text, content);
  });

  test(
    'newlines across converted markers are preserved in joined content',
    () async {
      const content = 'a\n[image:https://example.com/x.png]\nb';
      final result = await decodeLegacyContent(content);

      expect(result.converted, 1);
      expect(result.parts, hasLength(3));
      expect((result.parts[0] as TextPart).text, 'a');
      expect(result.parts[1], isA<ImagePart>());
      expect((result.parts[2] as TextPart).text, '\nb');
      expect(
        result.parts.whereType<TextPart>().map((part) => part.text).join(),
        'a\nb',
      );
      expect(stripLegacyContentTextSegments(content).join(), 'a\nb');
    },
  );

  test('CRLF-only legacy content round-trips CRLF in TextPart', () async {
    const content = 'a\r\n[image:https://example.com/x.png]\r\nb';
    final result = await decodeLegacyContent(content);

    expect(result.converted, 1);
    expect(result.parts, hasLength(3));
    expect((result.parts[0] as TextPart).text, 'a');
    expect(result.parts[1], isA<ImagePart>());
    expect((result.parts[2] as TextPart).text, '\r\nb');
    expect(
      result.parts.whereType<TextPart>().map((part) => part.text).join(),
      'a\r\nb',
    );
    expect(stripLegacyContentTextSegments(content).join(), 'a\r\nb');
  });

  test('LF legacy content still joins with LF', () async {
    const content = 'a\n[image:https://example.com/x.png]\nb';
    final result = await decodeLegacyContent(content);
    expect((result.parts[2] as TextPart).text, '\nb');
    expect(
      result.parts.whereType<TextPart>().map((part) => part.text).join(),
      'a\nb',
    );
    expect(stripLegacyContentTextSegments(content).join(), 'a\nb');
  });

  test('indented fence (1-3 spaces) opens and keeps markers as text', () async {
    final content = [
      'before',
      '  ```',
      '[image:/tmp/in-indented-fence.png]',
      '  ```',
      'after',
    ].join('\n');

    final result = await decodeLegacyContent(content);

    expect(result.converted, 0);
    expect(result.malformed, 0);
    expect(result.parts, hasLength(1));
    expect((result.parts.single as TextPart).text, content);
    expect(stripLegacyContentTextSegments(content).join(), content);
  });

  test('longer opening fence is not closed by a shorter fence', () async {
    final content = [
      'before',
      '````',
      '```',
      '[image:/tmp/inside-longer-fence.png]',
      '````',
      'after',
    ].join('\n');

    final result = await decodeLegacyContent(content);

    expect(result.converted, 0);
    expect(result.malformed, 0);
    expect(result.parts, hasLength(1));
    expect((result.parts.single as TextPart).text, content);
    expect(stripLegacyContentTextSegments(content).join(), content);
  });

  test('mixed CRLF/LF round-trips without rewriting all to CRLF', () async {
    const content = 'a\n[image:https://example.com/x.png]\r\nb\nc';
    final result = await decodeLegacyContent(content);

    expect(result.converted, 1);
    expect(result.parts, hasLength(3));
    expect((result.parts[0] as TextPart).text, 'a');
    expect(result.parts[1], isA<ImagePart>());
    // Bridging newline uses the original ending after the preceding text line.
    expect((result.parts[2] as TextPart).text, '\nb\nc');
    expect(
      result.parts.whereType<TextPart>().map((part) => part.text).join(),
      'a\nb\nc',
    );
    expect(stripLegacyContentTextSegments(content).join(), 'a\nb\nc');
    // Must not normalize the whole body to CRLF.
    expect(
      result.parts
          .whereType<TextPart>()
          .map((part) => part.text)
          .join()
          .contains('\r\n'),
      isFalse,
    );
  });

  test('mixed endings in text-only content are preserved verbatim', () async {
    const content = 'a\r\nb\nc';
    final result = await decodeLegacyContent(content);
    expect(result.parts, hasLength(1));
    expect((result.parts.single as TextPart).text, content);
    expect(stripLegacyContentTextSegments(content).join(), content);
  });

  test('attachment-only content strips to zero segments', () async {
    // Joined strings hide the segment count ([''] and [] both join to ''),
    // and the migration digest hashes per segment, so these cases must
    // assert segment lists, not joined text.
    const attachmentOnlyContents = <String>[
      '[image:/tmp/a.png]',
      '[file:/tmp/a.pdf|a.pdf|application/pdf]',
      '[image:/tmp/a.png]\n[image:/tmp/b.png]',
      '[image:data:image/png;base64,iVBORw0KGgo=]',
    ];
    for (final content in attachmentOnlyContents) {
      final segments = stripLegacyContentTextSegments(content);
      expect(segments, isEmpty, reason: content);

      final result = await decodeLegacyContent(content);
      expect(result.parts.whereType<TextPart>(), isEmpty, reason: content);
    }
  });

  test('strip segments match decoded TextParts one-to-one', () async {
    // The migration validator mixes one digest per stripped segment and the
    // repository persists one digest per TextPart; any count or content
    // divergence fails the whole migration.
    const contents = <String>[
      '',
      '[image:/tmp/a.png]',
      '[image:/tmp/a.png]\n',
      'hi\n[image:/tmp/a.png]',
      '[image:/tmp/a.png]\nhi',
      'a\n[image:/tmp/a.png]\nb',
    ];
    for (final content in contents) {
      final result = await decodeLegacyContent(content);
      var parts = result.parts;
      if (parts.isEmpty) {
        // Mirror the migration service: an entirely empty body is persisted
        // as one empty text part.
        parts = const [TextPart('')];
      }
      final persistedTexts = parts
          .whereType<TextPart>()
          .map((part) => part.text)
          .toList();
      expect(
        stripLegacyContentTextSegments(content),
        persistedTexts,
        reason: content,
      );
    }
  });

  test('managed Documents absolute path becomes kelivo-file URI', () async {
    final docs = Directory('${tempDir.path}/Documents')..createSync();
    SandboxPathResolver.debugSetDirs(docsDir: docs.path);
    addTearDown(() => SandboxPathResolver.debugSetDirs());
    final uploadDir = Directory('${docs.path}/upload')..createSync();
    final image = File('${uploadDir.path}/shot.png')
      ..writeAsBytesSync(const <int>[0x89, 0x50, 0x4E, 0x47]);
    final content = '[image:${image.path}]';

    final result = await decodeLegacyContent(content);

    expect(result.converted, 1);
    expect(result.missingFiles, 0);
    final part = result.parts.single as ImagePart;
    expect(part.uri, 'kelivo-file:///upload/shot.png');
    expect(part.unavailable, isFalse);

    final again = await decodeLegacyContent(
      content,
      existingParts: result.parts,
    );
    expect(again.converted, 0);
    expect(
      (again.parts.single as ImagePart).uri,
      'kelivo-file:///upload/shot.png',
    );
  });

  test(
    'missing managed file still yields unavailable kelivo-file part',
    () async {
      final docs = Directory('${tempDir.path}/Documents')..createSync();
      SandboxPathResolver.debugSetDirs(docsDir: docs.path);
      addTearDown(() => SandboxPathResolver.debugSetDirs());
      final missing = '${docs.path}/upload/gone.png';
      final result = await decodeLegacyContent('[image:$missing]');
      expect(result.converted, 1);
      expect(result.missingFiles, 1);
      final part = result.parts.single as ImagePart;
      expect(part.uri, 'kelivo-file:///upload/gone.png');
      expect(part.unavailable, isTrue);
    },
  );

  test('ordinary user Documents path is not claimed as kelivo-file', () async {
    SandboxPathResolver.debugSetDirs(docsDir: '${tempDir.path}/app_docs');
    addTearDown(() => SandboxPathResolver.debugSetDirs());
    const external = '/Users/alice/Documents/images/report.png';
    final result = await decodeLegacyContent('[image:$external]');
    expect(result.converted, 1);
    final part = result.parts.single as ImagePart;
    expect(part.uri, external);
  });
}
