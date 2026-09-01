import 'package:Cuplivo/features/home/widgets/subagent_target_sheet.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpSnackbar(
    WidgetTester tester, {
    VoidCallback? onGoSetup,
  }) async {
    // Use a tall, narrow phone-like viewport so the floating snackbar and its
    // close affordance stay on-screen and hit-testable.
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () {
                  showSubagentNoTargetSnackbar(
                    context,
                    onGoSetup:
                        onGoSetup ?? () {},
                  );
                },
                child: const Text('trigger'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('trigger'));
    // Let the snackbar entrance animation settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets(
    'shows a floating snackbar with a close affordance and go-setup action',
    (tester) async {
      await pumpSnackbar(tester);

      final l10n = AppLocalizations.of(
        tester.element(find.byType(Scaffold)),
      )!;
      // The no-target hint and the go-setup action are visible.
      expect(find.text(l10n.subagentNoTargetHint), findsOneWidget);
      expect(find.text(l10n.subagentGoSetup), findsOneWidget);

      // The SnackBar is floating so it can also be swiped away.
      final snackbar = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(snackbar.behavior, SnackBarBehavior.floating);
      expect(snackbar.showCloseIcon, isTrue);

      // The built-in close affordance (Icons.close) is exposed.
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.byIcon(Icons.close),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'tapping the close icon dismisses the snackbar',
    (tester) async {
      await pumpSnackbar(tester);

      final closeIcon = find.descendant(
        of: find.byType(SnackBar),
        matching: find.byIcon(Icons.close),
      );
      expect(closeIcon, findsOneWidget);

      // Ensure the close icon is within the hit-test area before tapping.
      await tester.ensureVisible(closeIcon);
      await tester.pump();
      await tester.tap(closeIcon, warnIfMissed: false);
      // Drain the entrance and exit animations.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(SnackBar), findsNothing);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(Scaffold)),
      )!;
      expect(find.text(l10n.subagentNoTargetHint), findsNothing);
    },
  );
}
