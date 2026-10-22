import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/compress_context_options.dart';
import 'package:Cuplivo/features/home/widgets/compress_context_readout.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

const _split = CompressContextSplit(
  totalTokens: 42300,
  keptTokens: 6100,
  summaryInputTokens: 36200,
);

/// Tool-heavy shape: the summarized span is mostly tool payload, so the band's
/// base (the body-only summary input) is far smaller than `total − kept`.
const _toolHeavySplit = CompressContextSplit(
  totalTokens: 40000,
  keptTokens: 9000,
  summaryInputTokens: 3000,
);

Future<void> pumpReadout(
  WidgetTester tester, {
  required CompressContextSplit split,
  required Brightness brightness,
  required String language,
  double width = 420,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 800);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      locale: Locale(language),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(18),
          child: Align(
            alignment: Alignment.topCenter,
            child: CompressContextReadout(
              split: split,
              rounds: 12,
              keptRounds: 3,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final width in [320.0, 420.0]) {
    for (final brightness in Brightness.values) {
      for (final language in ['en', 'zh']) {
        testWidgets('readout fits $width $brightness $language', (
          tester,
        ) async {
          await pumpReadout(
            tester,
            split: _split,
            brightness: brightness,
            language: language,
            width: width,
          );

          expect(tester.takeException(), isNull);
          expect(find.byType(CompressContextReadout), findsOneWidget);
          // Both sides are stacked: headline above value on each side.
          for (final headline in ['12', '3']) {
            expect(
              find.textContaining(headline),
              findsWidgets,
              reason: 'headline $headline',
            );
          }
          expect(find.textContaining('42.3k'), findsOneWidget);
          expect(find.textContaining('9.7k'), findsOneWidget);
          expect(find.textContaining('−68%'), findsOneWidget);
        });
      }
    }
  }

  testWidgets('zh renders 轮 and token wording', (tester) async {
    await pumpReadout(
      tester,
      split: _split,
      brightness: Brightness.dark,
      language: 'zh',
    );

    expect(find.text('共 12 轮'), findsOneWidget);
    expect(find.text('3 轮 + 摘要'), findsOneWidget);
    expect(find.text('~42.3k token'), findsOneWidget);
    expect(find.text('~9.7k–16.9k token'), findsOneWidget);
  });

  testWidgets('en pluralises a single round', (tester) async {
    await pumpReadout(
      tester,
      split: _split,
      brightness: Brightness.dark,
      language: 'en',
    );

    expect(find.text('12 rounds'), findsOneWidget);
    expect(find.text('3 rounds + summary'), findsOneWidget);
  });

  testWidgets('the band follows the summary input, not total − kept', (
    tester,
  ) async {
    await pumpReadout(
      tester,
      split: _toolHeavySplit,
      brightness: Brightness.dark,
      language: 'en',
    );

    expect(find.textContaining('−76%'), findsOneWidget);
    expect(find.textContaining('9.3k'), findsOneWidget);
    expect(find.textContaining('9.9k'), findsOneWidget);
  });

  testWidgets('empty split renders nothing', (tester) async {
    await pumpReadout(
      tester,
      split: const CompressContextSplit(
        totalTokens: 0,
        keptTokens: 0,
        summaryInputTokens: 0,
      ),
      brightness: Brightness.light,
      language: 'en',
    );

    expect(find.byType(CompressContextReadout), findsOneWidget);
    expect(find.byType(Text), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
