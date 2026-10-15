// Phase C's instrument for the question the widget-level benchmark cannot
// answer: does rendering an inline element from its IR node (phase B) cost
// measurably more than parsing that element inline (phase A)?
//
// `long_streaming_bench.dart` measures appends through a pumped widget, where
// two runs of the *same* revision can differ by ±40% on one shape. This
// benchmark takes the pump out of the loop: it pumps once for a real
// `BuildContext`, then calls the walk directly, thousands of times. What is
// left is a few percent of noise, which is what makes the comparison decidable.
//
// A benchmark, not a test: it prints timings, contains no expect(), and is
// named out of the default `_test.dart` glob. Run it explicitly, labelling the
// revision it is measuring — the A/B method is to interleave labelled runs:
//
//   flutter test test/perf/inline_walk_bench.dart --dart-define=BENCH_REV=after
//
// It has to compile against both the pre-phase-B and the post-phase-B tree, so
// it touches only `MarkdownComponent.generate`, `walkNodes` and
// `markdownComponentsFor` — never the emitter or `nodeOfElement`.
import 'dart:math' as math;

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/markdown_with_highlight.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:provider/provider.dart';

import '../support/business_test_harness.dart';

const String _revision = String.fromEnvironment(
  'BENCH_REV',
  defaultValue: 'unlabelled',
);

/// Optional comma-separated filters, so a targeted A/B (the shapes that carry
/// inline elements, and one drift control) costs a third of a full sweep.
/// Empty means every shape and size.
const String _shapeFilter = String.fromEnvironment('BENCH_SHAPES');
const String _sizeFilter = String.fromEnvironment('BENCH_SIZES');

void main() {
  testWidgets('inline walk cost', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => SettingsProvider(createBusinessTestPreferences()),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    final context = tester.element(find.byType(Scaffold));
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final set = markdownComponentsFor(settings: settings, streaming: false);
    final config = GptMarkdownConfig(
      components: set.global,
      inlineComponents: set.inline,
      streaming: true,
      style: const TextStyle(fontSize: 15.5, height: 1.55),
    );

    final wanted = _shapeFilter.isEmpty
        ? null
        : _shapeFilter.split(',').toSet();
    final sizes = _sizeFilter.isEmpty
        ? const [100, 1000]
        : [for (final size in _sizeFilter.split(',')) int.parse(size)];
    for (final n in sizes) {
      final shapes = <String, String>{
        'plain': List.generate(
          n,
          (i) => 'Paragraph $i reasoning 中文内容 and plain words.',
        ).join(' '),
        'emphasis': List.generate(n, (i) => '**加粗$i** 和 *斜体* 继续推导。').join(' '),
        'mixed': List.generate(
          n,
          (i) => '**加粗$i** 和 *斜体* 与 `code` 见 [label](https://e.com)。',
        ).join(' '),
      };
      final iterations = _iterationsFor(n);
      for (final entry in shapes.entries) {
        if (wanted != null && !wanted.contains(entry.key)) continue;
        final source = entry.value;
        _measure('generate', entry.key, n, source, iterations, () {
          return MarkdownComponent.generate(
            context,
            source,
            config,
            true,
          ).length;
        });
        _measure('walkNodes', entry.key, n, source, iterations, () {
          return MarkdownComponent.walkNodes(source, config: config).length;
        });
      }
    }
  });
}

int _iterationsFor(int n) => math.max(50, math.min(500, 200000 ~/ n));

/// Runs [body] after a warmup and prints the per-call cost for one shape.
///
/// The statistic is the median of the per-iteration times, not the mean of one
/// long run: a single GC pause or frequency step inside a run would otherwise
/// move the mean by ten percent, which is the size of the effect being hunted.
void _measure(
  String method,
  String shape,
  int n,
  String source,
  int iterations,
  int Function() body,
) {
  for (var i = 0; i < math.max(5, iterations ~/ 20); i++) {
    body();
  }
  var checksum = 0;
  final samples = <int>[];
  for (var i = 0; i < iterations; i++) {
    final sw = Stopwatch()..start();
    checksum += body();
    sw.stop();
    samples.add(sw.elapsedMicroseconds);
  }
  samples.sort();
  final median = samples[samples.length ~/ 2];
  final fastest = samples.first;
  // ignore: avoid_print
  print(
    'INLINE_WALK|rev=$_revision|$method|shape=$shape|elements=$n|'
    'chars=${source.length}|iterations=$iterations|'
    'medianUs=$median|minUs=$fastest|'
    'nsPerElement=${(median * 1000 / n).toStringAsFixed(1)}|sum=$checksum',
  );
}
