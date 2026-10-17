import 'dart:typed_data';

import 'package:Cuplivo/features/chat/utils/export_document.dart';
import 'package:Cuplivo/features/chat/utils/markdown_pdf_emitter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as syncfusion;

import '../../../support/test_png.dart';

/// What the writer does with content that is taller than a page.
///
/// The writer can only break text at the page level, so a block that cannot be
/// broken is a block that fails the whole export — and it fails quietly: the
/// writer's page guard is an `assert`, so a release build would re-lay-out the
/// same block for ever instead of throwing. Every case here is one shape of that
/// problem, and each is asserted by its *tail*, because a body that was cut short
/// still answers the first line.
///
/// The two shapes a page cannot carry are pinned by construction rather than by
/// measurement: text is emitted so the writer may paginate it, and anything it
/// cannot paginate — a picture, a diagram, a table row — is bounded to
/// [_maxUnbreakableHeight] and cut off there.
void main() {
  test('a fence taller than a page is paged, not refused', () async {
    final code = <String>[
      for (var index = 0; index < 4000; index++) 'line $index of the fence',
      'FENCE-TAIL-MARKER',
    ].join('\n');

    final exported = await _export('```\n$code\n```\n');

    expect(exported.pages, greaterThan(2));
    expect(exported.text, contains('line 0 of the fence'));
    expect(exported.text, contains('FENCE-TAIL-MARKER'));
  });

  test('one paragraph taller than a page is paged, not refused', () async {
    final paragraph = <String>[
      for (var index = 0; index < 6000; index++) 'word$index',
      'PARAGRAPH-TAIL-MARKER',
    ].join(' ');

    final exported = await _export('$paragraph\n');

    expect(exported.pages, greaterThan(2));
    expect(exported.text, contains('word0 '));
    expect(exported.text, contains('PARAGRAPH-TAIL-MARKER'));
  });

  test('a quote, a card, a tool answer and a list item all page', () async {
    final quote = <String>[
      for (var index = 0; index < 400; index++) '> quoted line $index',
      '> QUOTE-TAIL-MARKER',
    ].join('\n');
    final card = <String>[
      for (var index = 0; index < 400; index++) 'reasoning line $index',
      'CARD-TAIL-MARKER',
    ].join('\n\n');
    final tool = <String>[
      for (var index = 0; index < 400; index++) '{"row":$index}',
      'TOOL-TAIL-MARKER',
    ].join('\n');
    final item = <String>[
      'LIST-TAIL-MARKER',
      for (var index = 0; index < 400; index++) 'item word $index',
    ].join(' ');

    final exported = await _export(
      'text before\n\n$quote\n\n- $item\n',
      extraBlocks: <ExportBlock>[
        ExportReasoning(card),
        ExportToolCall(name: 'search', content: tool),
      ],
    );

    expect(exported.pages, greaterThan(2));
    for (final expected in <String>[
      'quoted line 0',
      'QUOTE-TAIL-MARKER',
      'reasoning line 0',
      'CARD-TAIL-MARKER',
      'search',
      '{"row":0}',
      'TOOL-TAIL-MARKER',
      'LIST-TAIL-MARKER',
      'item word 399',
    ]) {
      expect(
        exported.text,
        contains(expected),
        reason: 'the export lost "$expected"',
      );
    }
  });

  test('a picture taller than the page is scaled onto it', () async {
    // A phone screenshot's shape: far taller than a page, far narrower than one.
    // The writer cannot break a picture, so this one has to be scaled down.
    final tall = pngForTest(width: 100, height: 4000);

    final exported = await _export(
      'before the picture\n\nafter the picture\n',
      images: <String, Uint8List>{'tall://screenshot': tall},
      wrapImages: true,
    );

    expect(exported.pages, lessThan(3));
    expect(exported.text, contains('before the picture'));
    expect(exported.text, contains('after the picture'));
  });

  test('a table cell taller than a page is cut off, not looped over', () async {
    // A table breaks between rows and never inside one, and it hands each cell an
    // unbounded height: without the cap this export never finishes (a debug build
    // raises TooManyPagesException, a release one repeats the row for ever).
    // The cell is one long line — a newline in a table row would end the row.
    final cell = <String>[
      'CELL-HEAD-MARKER',
      for (var index = 0; index < 5000; index++) 'cellword$index',
    ].join(' ');

    final exported = await _export(
      '| long | short |\n| --- | --- |\n| $cell | ok |\n',
    );

    expect(exported.pages, lessThan(4));
    expect(exported.text, contains('CELL-HEAD-MARKER'));
    // The short cell is drawn a character at a time, so it reads back spaced.
    expect(exported.text.replaceAll(' ', ''), contains('ok'));
  });

  test('a table whose cells fit keeps every cell', () async {
    final exported = await _export(
      '| head A | head B |\n| --- | --- |\n| a1 | b1 |\n| a2 | b2 |\n',
    );

    expect(exported.pages, 1);
    for (final expected in <String>[
      'head A',
      'head B',
      'a1',
      'b1',
      'a2',
      'b2',
    ]) {
      expect(exported.text, contains(expected));
    }
  });
}

/// One export, read back with a reader that is not the writer.
class _Exported {
  _Exported(this.bytes, this.pages, this.text);

  final Uint8List bytes;
  final int pages;
  final String text;
}

Future<_Exported> _export(
  String markdown, {
  List<ExportBlock> extraBlocks = const <ExportBlock>[],
  Map<String, Uint8List> images = const <String, Uint8List>{},
  bool wrapImages = false,
}) async {
  final body = wrapImages
      ? '${markdown.trimRight()}\n\n![tall](tall://screenshot)\n'
      : markdown;
  final bytes = (await buildConversationPdf(
    PdfExportRequest(
      title: 'pagination probe',
      thinkingLabel: 'Thinking',
      accent: kPdfPageAccent,
      muted: kPdfPageMuted,
      userLabel: 'User',
      messages: <ExportMessage>[
        ExportMessage(
          time: '2026-01-02 03:04:05',
          roleName: 'Assistant',
          speaker: ExportSpeaker.assistant,
          blocks: <ExportBlock>[ExportText(body), ...extraBlocks],
        ),
      ],
      images: images,
    ),
  )).bytes;

  final readBack = syncfusion.PdfDocument(inputBytes: bytes);
  addTearDown(readBack.dispose);
  return _Exported(
    bytes,
    readBack.pages.count,
    // The reader reports one line per text-showing operation, so assertions
    // compare flattened whitespace rather than the text as it was typed.
    syncfusion.PdfTextExtractor(
      readBack,
    ).extractText().replaceAll(RegExp(r'\s+'), ' ').trim(),
  );
}
