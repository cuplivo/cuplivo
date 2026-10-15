import 'package:Cuplivo/shared/widgets/markdown_with_highlight.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

// Explicit benchmark; timings are observations, not regression assertions.
//
// The splitter walks the region a block is still growing in, so what an append
// costs is decided by what the region holds: a run to decide, or nothing. This
// bench prints both, per shape, with the number of walks and the median cost of
// one append, so a guard change can be judged instead of argued about.
const int _elements = int.fromEnvironment('PERF_ELEMENTS', defaultValue: 2000);
const int _appends = int.fromEnvironment('PERF_APPENDS', defaultValue: 30);

String _corpus(String separator) => [
  for (var i = 0; i < _elements; i++)
    'Paragraph $i **加粗** reasoning 中文内容。'
        ' Keep rendering Markdown while the response grows.',
].join(separator);

void main() {
  test('splitter append cost', () {
    final shapes = <String, String>{
      'single': _corpus(' '),
      'lines': _corpus('\n'),
      'paragraphs': _corpus('\n\n'),
      'list': [
        for (var i = 0; i < _elements; i++) '- item $i **加粗** 中文内容。',
      ].join('\n\n'),
    };
    final appends = <String, String>{
      // No ASCII punctuation and no newline: nothing in the region can change.
      'cjk': '新增输出。',
      // Spaces and asterisks: every match the walk makes can change.
      'punctuation': ' **新增粗体** 和 *斜体*。',
      // A blank run plus content: the walk decides a boundary.
      'boundary': '\n\n下一段。',
    };

    for (final shape in shapes.entries) {
      for (final append in appends.entries) {
        for (final pass in [0, 1, 2]) {
          final split = markdownStreamingSplit();
          var source = shape.value;
          split.update(source);
          final walksBefore = split.debugWalkedRegions;
          final samples = <int>[];
          for (var i = 0; i < _appends; i++) {
            final sw = Stopwatch()..start();
            source = '$source${append.value}';
            split.update(source);
            sw.stop();
            samples.add(sw.elapsedMicroseconds);
          }
          samples.sort();
          debugPrint(
            'SPLITCOST|shape=${shape.key}|append=${append.key}|pass=$pass|'
            'chars=${source.length}|blocks=${split.blocks.length}|'
            'walks=${split.debugWalkedRegions - walksBefore}|'
            'medianUs=${samples[samples.length ~/ 2]}|'
            'maxUs=${samples.last}',
          );
        }
      }
    }
  });
}
