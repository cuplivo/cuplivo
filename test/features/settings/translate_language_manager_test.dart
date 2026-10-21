import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/settings/widgets/language_select_sheet.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/snackbar.dart';

import '../../support/business_test_harness.dart';

/// The two rules the manage surface is responsible for (ADR-0014): the visible
/// set can never become empty, and hiding the active target never leaves a
/// hidden language selected. Both are asserted through the surface the user
/// actually taps, not through the helper each one calls.
void main() {
  setUp(AppSnackBarManager().dismissAll);
  tearDown(AppSnackBarManager().dismissAll);

  Future<SettingsProvider> pumpManager(
    WidgetTester tester, {
    Map<String, Object?> initial = const <String, Object?>{},
  }) async {
    final storage = await createBusinessTestHarness(initial: initial);
    final settings = SettingsProvider(storage.preferences);
    addTearDown(settings.dispose);
    await settings.loaded;

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showTranslateLanguageManager(context),
                  child: const Text('open manager'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open manager'));
    await tester.pumpAndSettle();
    return settings;
  }

  Future<void> drainSnackBars(WidgetTester tester) async {
    // The toast dismisses itself with a timer; drain it so the test ends with
    // no pending timers.
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('tapping the last visible language keeps it and warns', (
    tester,
  ) async {
    final settings = await pumpManager(
      tester,
      initial: {
        'translate_visible_languages_v1': <String>['en'],
        'translate_target_lang_v1': 'en',
      },
    );
    expect(settings.translateVisibleLanguages, {'en'});

    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();

    expect(settings.translateVisibleLanguages, {'en'});
    expect(
      AppSnackBarManager().activeToasts.map((t) => t.notification.message),
      contains('Keep at least one language visible.'),
    );
    expect(
      AppSnackBarManager().activeToasts.single.notification.type,
      NotificationType.warning,
    );

    await drainSnackBars(tester);
  });

  testWidgets('hiding the active language switches the target', (tester) async {
    final settings = await pumpManager(
      tester,
      initial: {
        'translate_visible_languages_v1': <String>['en', 'ja'],
        'translate_target_lang_v1': 'ja',
      },
    );
    expect(settings.translateTargetLang, 'ja');

    await tester.tap(find.text('Japanese'));
    await tester.pumpAndSettle();

    expect(settings.translateVisibleLanguages, {'en'});
    expect(settings.translateTargetLang, 'en');
  });

  testWidgets('desktop opens a dialog rather than a sheet', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpManager(tester);

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Manage Languages'), findsOneWidget);
    } finally {
      // Reset inside the body: the foundation-variable invariant is checked
      // before tearDown callbacks run.
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
