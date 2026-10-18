import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:Cuplivo/features/chat/utils/export_document.dart';
import 'package:Cuplivo/features/chat/utils/markdown_pdf_emitter.dart';
import 'package:Cuplivo/features/chat/utils/pdf_export_fonts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as syncfusion;
import 'package:system_fonts/system_fonts.dart';

/// How the page fills a line, which is the one thing the writer will not do for
/// Chinese.
///
/// The writer's tokenizer breaks on whitespace alone (`pdf`'s `text.dart`,
/// `_buildLines`), so a Chinese sentence — which has no spaces in it — reaches it
/// as one word, and a word that does not fit the room left on a line is moved to
/// the next one *whole*. The line before it then ends where that word began: the
/// short line a review of a first export found, and always in the same place,
/// after a Latin word and a space. `markdown_pdf_emitter.dart`'s `_filled` hands
/// the writer the break opportunities it does not compute, and these are the
/// claims that holds down.
///
/// Everything here is read back with an independent reader
/// (`syncfusion_flutter_pdf`), lines and all: the content-stream fixture beside
/// this test reads the page's own operators and says outright that it only works
/// while no face is embedded — an embedded face writes its glyph *numbering* into
/// the stream, which is not the text.
void main() {
  final cjkFont = _findSingleFaceCjkFont();

  // A paragraph written the way a model writes Chinese: sentences with Latin
  // words and numbers in them, and no spaces inside the Chinese itself.
  const mixed =
      '先厘清语义：Closes #1007 是给 GitHub 的承诺，PR 合并那一刻 issue 自动关闭，'
      '等于说「你报告的事，我全解决了。」Refs #1007 只是关联，把改动挂到 issue 上留痕，'
      '关不关由人决定。两者不是写法的差别，是责任边界的差别。'
      '那为什么这里选 Refs？看这份描述自己的信号就够了：主动陪伴的修复还没闭环，'
      '定位写得再扎实，也是静态推理加单测加 Robolectric，Kotlin 侧没本地编译过，'
      '真机复现验证更是没有。触发链路这种偶发丢包问题，最怕「逻辑上修好了」但现场还在丢。';

  // The same kind of prose with nothing but Chinese in it. The writer fills this
  // one itself — a run with no space in it is split by its own `_splitWord` — so
  // it is the measure of the column, counted by the same reader.
  const plain =
      '这是一段没有任何西文单词的中文段落它只用来量出一行到底能放多少个汉字'
      '排版上的每一行都应该被填满而这一段由writer自己断行所以它是尺子'
      '先厘清语义是给承诺合并那一刻就自动关闭等于说你报告的事我全解决了'
      '只是关联把改动挂上去留痕关不关由人决定两者不是写法的差别是责任边界的差别'
      '那为什么这里选它看这份描述自己的信号就够了主动陪伴的修复还没闭环'
      '定位写得再扎实也是静态推理加单测加真机验证更是没有触发链路最怕现场还在丢';

  // What a line may not begin with, and what it may not end with: the two rules
  // a Chinese typesetter applies and the writer has none of.
  const noBreakBefore = <int>{0x3002, 0x3001, 0x300d, 0xff0c, 0xff1f, 0x201d};
  const noBreakAfter = <int>{0x300c, 0xff08, 0x201c};

  group(
    'the page\'s line filling',
    () {
      test('fills every line of a mixed paragraph but the last', () async {
        final column = _lineWidths(await _lines(cjkFont, plain));
        final full = column.reduce(math.max);
        expect(
          full,
          greaterThan(20),
          reason: 'the reference paragraph did not wrap',
        );

        final lines = await _lines(cjkFont, mixed);
        expect(lines.length, greaterThan(2));
        final widths = _lineWidths(lines);
        for (var index = 0; index + 1 < widths.length; index++) {
          expect(
            widths[index],
            greaterThanOrEqualTo(full - 2),
            reason:
                'line $index holds ${widths[index]} of $full characters: '
                '${lines.join(' | ')}',
          );
        }
      });

      test('draws a Chinese run as the run it was given', () async {
        // A fill that put a break opportunity after every character reads back as
        // `小 节 标 题`, and a search for the phrase finds nothing.
        final text = _flatten(await _text(cjkFont, mixed));
        for (final run in <String>[
          '先厘清语义',
          '把改动挂到',
          '责任边界的差别',
          '主动陪伴的修复还没闭环',
        ]) {
          expect(text, contains(run));
        }
      });

      test('never opens a line with closing punctuation', () async {
        final lines = await _lines(cjkFont, mixed);
        expect(lines.length, greaterThan(3));
        for (final line in lines) {
          final first = line.runes.first.toInt();
          final last = line.runes.last.toInt();
          expect(
            noBreakBefore.contains(first),
            isFalse,
            reason:
                'a line opens with ${String.fromCharCode(first)}: '
                '${lines.join(' | ')}',
          );
          expect(
            noBreakAfter.contains(last),
            isFalse,
            reason:
                'a line ends with ${String.fromCharCode(last)}: '
                '${lines.join(' | ')}',
          );
        }
      });
    },
    skip: cjkFont == null
        ? 'no single-face CJK font is installed on this machine'
        : null,
  );
}

String _flatten(String extracted) =>
    extracted.replaceAll(RegExp(r'\s+'), ' ').trim();

/// The lines one message's body was set on, in reading order.
///
/// The reader reports lines for the whole page — the header, the speaker line and
/// the number under it as well — so the body is what holds a Chinese character.
Future<List<String>> _lines(Uint8List? font, String markdown) async {
  final readBack = syncfusion.PdfDocument(
    inputBytes: await _bytes(font, markdown),
  );
  addTearDown(readBack.dispose);
  return <String>[
    for (final line in syncfusion.PdfTextExtractor(readBack).extractTextLines())
      if (line.text.trim().isNotEmpty && line.text.runes.any(_isWide))
        line.text.trim(),
  ];
}

Future<String> _text(Uint8List? font, String markdown) async {
  final readBack = syncfusion.PdfDocument(
    inputBytes: await _bytes(font, markdown),
  );
  addTearDown(readBack.dispose);
  return syncfusion.PdfTextExtractor(readBack).extractText();
}

bool _isWide(int rune) =>
    (rune >= 0x2e80 && rune <= 0x9fff) ||
    (rune >= 0xf900 && rune <= 0xfaff) ||
    (rune >= 0x20000 && rune <= 0x3ffff);

/// How many characters each line holds, spaces aside.
List<int> _lineWidths(List<String> lines) => <int>[
  for (final line in lines) line.replaceAll(RegExp(r'\s+'), '').runes.length,
];

Future<Uint8List> _bytes(Uint8List? font, String markdown) async =>
    (await buildConversationPdf(
      PdfExportRequest(
        title: 'Title',
        thinkingLabel: 'Thinking',
        accent: kPdfPageAccent,
        muted: kPdfPageMuted,
        userLabel: 'User',
        bodyFont: font,
        messages: <ExportMessage>[
          ExportMessage(
            time: '2026-01-02 03:04:05',
            roleName: 'Assistant',
            speaker: ExportSpeaker.assistant,
            blocks: <ExportBlock>[ExportText(markdown)],
          ),
        ],
      ),
    )).bytes;

/// The first installed font the writer can actually embed, preferring the
/// single-face CJK faces Windows ships.
Uint8List? _findSingleFaceCjkFont() {
  const List<String> hints = <String>[
    'deng',
    'simhei',
    'simkai',
    'simfang',
    'arialuni',
    'notosanssc',
    'notosanscjk',
    'sourcehansans',
    'droidsansfallback',
  ];
  final List<String> paths = SystemFonts().getFontPaths();
  for (final hint in hints) {
    for (final path in paths) {
      if (!path.toLowerCase().contains(hint)) continue;
      try {
        final bytes = File(path).readAsBytesSync();
        if (isPdfEmbeddableFont(bytes)) return bytes;
      } catch (_) {
        continue;
      }
    }
  }
  return null;
}
