import 'dart:io';
import 'dart:typed_data';

import 'package:Cuplivo/features/chat/utils/export_document.dart';
import 'package:Cuplivo/features/chat/utils/markdown_pdf_emitter.dart';
import 'package:Cuplivo/features/chat/utils/pdf_export_fonts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:system_fonts/system_fonts.dart';

/// Prints what a conversation-sized export costs.
///
/// A bench rather than a test: it asserts nothing, and its name keeps it out of
/// the `_test.dart` glob `flutter test` walks. It exists to answer "is the IR
/// path fast enough to stand in for the WebView one" with a number instead of an
/// argument — and to keep answering it as the emitter grows.
///
///     flutter test test/perf/pdf_export_bench.dart
void main() {
  test('pdf layout and save, by conversation size', () async {
    final Uint8List? font = _cjkFont();
    if (font == null) {
      // ignore: avoid_print
      print('no single-face CJK font on this machine; nothing to measure');
      return;
    }
    for (final int count in <int>[10, 50, 100]) {
      final PdfExportRequest request = PdfExportRequest(
        title: '导出基准 $count',
        subtitle: '2026-01-02 03:04:05',
        thinkingLabel: '思考过程',
        accent: kPdfPageAccent,
        muted: kPdfPageMuted,
        userLabel: 'User',
        bodyFont: font,
        messages: <ExportMessage>[
          for (var index = 0; index < count; index++)
            ExportMessage(
              time: '2026-01-02 03:04:05',
              roleName: index.isEven ? '用户' : '助手',
              speaker: ExportSpeaker.assistant,
              blocks: <ExportBlock>[
                ExportText(_bodyFor(index)),
                if (index.isEven) ExportReasoning('第 $index 条推理内容。'),
                if (index.isEven)
                  ExportToolCall(name: 'search', content: '{"hits":1}'),
              ],
            ),
        ],
      );
      final Stopwatch watch = Stopwatch()..start();
      final Uint8List bytes = (await buildConversationPdf(request)).bytes;
      watch.stop();
      // ignore: avoid_print
      print(
        '$count messages: ${watch.elapsedMilliseconds} ms, '
        '${(bytes.length / 1024).toStringAsFixed(0)} KB',
      );
    }
  });
}

String _bodyFor(int index) =>
    '''
## 第 $index 节

这是第 $index 条消息的正文，含**加粗**、`行内代码` 与一点中文说明。

| 列 A | 列 B |
| --- | --- |
| 单元格 $index | 值 |

```dart
final value = $index;
```

> 引用第 $index 段
''';

Uint8List? _cjkFont() {
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
