import 'dart:io';
import 'dart:typed_data';

import 'package:Cuplivo/features/chat/utils/export_document.dart';
import 'package:Cuplivo/features/chat/utils/markdown_pdf_emitter.dart';
import 'package:Cuplivo/features/chat/utils/pdf_export_fonts.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:syncfusion_flutter_pdf/pdf.dart' as syncfusion;
import 'package:system_fonts/system_fonts.dart';

/// The PDF writer and the app's `archive` pin do not agree on paper: `pdf`
/// 3.12.0 declares `archive <4.1.0`, while the app requires `archive ^4.2.0`
/// because `data_sync.dart` overrides `OutputStream.writeBackReference`, an
/// archive 4.2 API (#954). The `dependency_overrides` entry is what lets both
/// hold, and deflate is the path they share — so this builds and saves a real
/// document, then reads it back with a reader that is not the writer.
///
/// Drop the override, or move pdf past 3.13 without also moving syncfusion to
/// 33 (xml 7), and this is the test that goes red.
void main() {
  test('the pdf writer still saves through the pinned archive', () async {
    final document = pw.Document();
    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (context) => <pw.Widget>[
          pw.Header(level: 0, text: 'Cuplivo export'),
          for (var i = 0; i < 60; i++)
            pw.Paragraph(
              text:
                  'Paragraph $i - the quick brown fox jumps over the lazy dog.',
            ),
          pw.TableHelper.fromTextArray(
            headers: const <String>['Column A', 'Column B'],
            data: const <List<String>>[
              <String>['a1', 'b1'],
              <String>['a2', 'b2'],
            ],
          ),
        ],
      ),
    );

    final Uint8List bytes = await document.save();
    expect(bytes.length, greaterThan(1000));

    // A reader that is not the writer: a malformed or truncated file fails
    // here rather than in the user's PDF viewer, and the body has to survive
    // the round trip, which is what proves the compression path ran.
    final syncfusion.PdfDocument readBack = syncfusion.PdfDocument(
      inputBytes: bytes,
    );
    addTearDown(readBack.dispose);

    expect(readBack.pages.count, greaterThan(1));
    // The reader reports one line per text-showing operation, and the writer
    // emits a justified paragraph as many of them, so content assertions have
    // to compare flattened whitespace rather than the paragraph as typed.
    final String text = _flatten(
      syncfusion.PdfTextExtractor(readBack).extractText(),
    );
    expect(text, contains('quick brown fox'));
    expect(text, contains('Column A'));
  });

  // A single-face CJK font is what an export needs and what most systems do not
  // offer through a family name; without one the CJK half of the assertions
  // could not be made at all, so the case is skipped rather than weakened.
  final Uint8List? cjkFont = _findSingleFaceCjkFont();

  test(
    'a conversation keeps its structure and its CJK through writer and reader',
    () async {
      final PdfExportRequest request = PdfExportRequest(
        title: '导出回归',
        subtitle: '一条测试会话',
        thinkingLabel: '思考过程',
        accent: kPdfPageAccent,
        muted: kPdfPageMuted,
        userLabel: 'User',
        bodyFont: cjkFont,
        messages: <ExportMessage>[
          ExportMessage(
            time: '2026-01-02 03:04:05',
            roleName: '助手',
            speaker: ExportSpeaker.assistant,
            blocks: <ExportBlock>[
              const ExportText(_body),
              // Enough body to flow onto a second page, so the pagination the
              // writer does for us is exercised rather than assumed.
              for (var index = 0; index < 12; index++)
                ExportText(
                  '## 补充小节 $index\n\n第 $index 段补充正文，'
                  '它的作用是把这条会话推到第二页及以后。',
                ),
              const ExportReasoning('推理过程留在导出里'),
              const ExportToolCall(name: 'search', content: '{"hits":1}'),
              const ExportFile(name: 'report.pdf', mime: 'application/pdf'),
              const ExportImage(uri: '/nowhere/missing.png'),
            ],
          ),
        ],
      );

      final Uint8List bytes = (await buildConversationPdf(request)).bytes;
      expect(bytes.length, greaterThan(2000));

      final syncfusion.PdfDocument readBack = syncfusion.PdfDocument(
        inputBytes: bytes,
      );
      addTearDown(readBack.dispose);
      final String text = _flatten(
        syncfusion.PdfTextExtractor(readBack).extractText(),
      );

      // The fixture is longer than one page, so pagination is exercised rather
      // than assumed: a single page here would mean the flow was cut off.
      expect(readBack.pages.count, greaterThan(1));

      for (final expected in <String>[
        '导出回归',
        '一条测试会话',
        '助手',
        '小节标题',
        '加粗的中文',
        'inline code',
        '列表项',
        '表格单元格',
        'void main',
        '引用段落',
        '折叠标题',
        '折叠正文',
        '思考过程',
        '推理过程留在导出里',
        'search',
        'report.pdf',
        'missing.png',
      ]) {
        expect(text, contains(expected), reason: 'the export lost "$expected"');
      }
    },
    skip: cjkFont == null
        ? 'no single-face CJK font is installed on this machine'
        : null,
  );

  // The app builds a document through `compute`, so the request and its blocks
  // have to survive the isolate hop. A marshalling failure is invisible from the
  // UI — the export simply never reaches the save dialog — which is exactly why
  // it is worth pinning here rather than discovering it on a device.
  test(
    'the same layout survives the isolate hop the app uses',
    () async {
      final PdfExportRequest request = PdfExportRequest(
        title: 'isolate 导出',
        thinkingLabel: '思考过程',
        accent: kPdfPageAccent,
        muted: kPdfPageMuted,
        userLabel: 'User',
        bodyFont: cjkFont,
        messages: const <ExportMessage>[
          ExportMessage(
            time: '2026-01-02 03:04:05',
            roleName: '助手',
            speaker: ExportSpeaker.assistant,
            blocks: <ExportBlock>[
              ExportText(_body),
              ExportReasoning('推理过程留在导出里'),
              ExportToolCall(name: 'search', content: '{"hits":1}'),
              ExportImage(uri: '/nowhere/missing.png'),
            ],
          ),
        ],
      );

      final PdfExportResult exported = await compute(
        buildConversationPdf,
        request,
      );
      final Uint8List bytes = exported.bytes;

      final syncfusion.PdfDocument readBack = syncfusion.PdfDocument(
        inputBytes: bytes,
      );
      addTearDown(readBack.dispose);
      expect(
        _flatten(syncfusion.PdfTextExtractor(readBack).extractText()),
        contains('小节标题'),
      );
    },
    skip: cjkFont == null
        ? 'no single-face CJK font is installed on this machine'
        : null,
  );
}

/// A conversation body that carries one of every block the layout maps.
const String _body = '''
## 小节标题

这是一段**加粗的中文**与 *斜体* 正文，含 `inline code` 和 [链接](https://example.com)。

- 列表项一
- 列表项二

| 列 A | 列 B |
| --- | --- |
| 表格单元格 | 值 |

```dart
void main() {}
```

> 引用段落

\\[\\int_0^1 x^2 dx\\]

<details><summary>折叠标题</summary>

折叠正文

</details>

''';

String _flatten(String extracted) =>
    extracted.replaceAll(RegExp(r'\s+'), ' ').trim();

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
