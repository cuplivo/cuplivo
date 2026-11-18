import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/features/image_job/widgets/image_job_card.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

Widget _host(Widget child) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: Scaffold(
      body: Center(child: SizedBox(width: 320, child: child)),
    ),
  );
}

ImagePart _part(ImagePartState state, {String? failureReason}) => ImagePart(
  uri: '/data/assets/asset-1.png',
  assetId: 'asset-1',
  jobId: 'job-1',
  state: state,
  failureReason: failureReason,
);

void main() {
  testWidgets('a pending job is a header line plus a fixed-ratio skeleton', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        ImageJobCard(
          part: _part(ImagePartState.pending),
          elapsed: const Duration(milliseconds: 12600),
        ),
      ),
    );

    expect(find.text('生成插图'), findsOneWidget);
    expect(find.text('(12.6s)'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);

    final skeleton = tester.getSize(find.byType(AspectRatio));
    expect(skeleton.width / skeleton.height, closeTo(1.5, 0.01));
  });

  testWidgets('the skeleton reserves the ratio the request asked for', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        ImageJobCard(
          part: _part(ImagePartState.pending),
          requestedAspect: 16 / 9,
        ),
      ),
    );

    // "I asked for a wide picture" is visible while it is being drawn, rather
    // than only after the bytes arrive and the block reflows.
    final skeleton = tester.getSize(find.byType(AspectRatio));
    expect(skeleton.width / skeleton.height, closeTo(16 / 9, 0.01));
  });

  testWidgets('a failed job explains itself and offers no action', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        ImageJobCard(
          part: _part(
            ImagePartState.failed,
            failureReason: 'The images API returned no image data.',
          ),
        ),
      ),
    );

    expect(find.text('生成失败'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // A picture is an accessory, not a product: there is nothing to press on a
    // failed one beyond reopening the panel.
    expect(find.byType(TextButton), findsNothing);
    expect(find.text('The images API returned no image data.'), findsOneWidget);
  });

  testWidgets('an interrupted job is terminal', (tester) async {
    await tester.pumpWidget(
      _host(ImageJobCard(part: _part(ImagePartState.interrupted))),
    );

    expect(find.text('已中断'), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets('the overflow affordance only exists when a panel is wired', (
    tester,
  ) async {
    var opens = 0;
    await tester.pumpWidget(
      _host(
        ImageJobCard(
          part: _part(ImagePartState.pending),
          onOpen: () => opens += 1,
        ),
      ),
    );

    await tester.tap(find.byIcon(Lucide.Ellipsis));
    expect(opens, 1);
  });
}
