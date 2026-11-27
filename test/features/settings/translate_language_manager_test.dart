import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/settings/widgets/language_select_sheet.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/snackbar.dart';

import '../../support/business_test_harness.dart';

/// What the standalone translate pages would show and translate to.
String _resolvedTarget(SettingsProvider settings, {String locale = 'en'}) {
  return effectiveTranslateLanguage(
    visible: visibleTranslateLanguages(settings.translateVisibleLanguages),
    persistedCode: settings.translateTargetLang,
    localeLanguageCode: locale,
  ).code;
}

/// The two rules the manage surface is responsible for (ADR-0014): the visible
/// set can never become empty, and hiding the active target never rewrites the
/// user's stored choice. Both are asserted through the surface the user
/// actually taps, not through the helper each one calls.
void main() {
  setUp(AppSnackBarManager().dismissAll);
  tearDown(AppSnackBarManager().dismissAll);

  Future<({SettingsProvider settings, BusinessTestHarness storage})>
  pumpManager(
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
    return (settings: settings, storage: storage);
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
    final (:settings, storage: _) = await pumpManager(
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

  testWidgets('hiding the active language keeps the stored choice', (
    tester,
  ) async {
    final (:settings, :storage) = await pumpManager(
      tester,
      initial: {
        'translate_visible_languages_v1': <String>['en', 'ja'],
        'translate_target_lang_v1': 'ja',
      },
    );
    expect(_resolvedTarget(settings), 'ja');

    // Hiding the active language changes what the pages show and use ...
    await tester.tap(find.text('Japanese'));
    await tester.pumpAndSettle();
    expect(settings.translateVisibleLanguages, {'en'});
    expect(_resolvedTarget(settings), 'en');

    // ... but never rewrites the user's choice.
    await storage.preferences.flushPendingWrites();
    expect(settings.translateTargetLang, 'ja');
    expect(storage.preferences.getString('translate_target_lang_v1'), 'ja');

    // Re-enabling it restores that choice, in this session ...
    await tester.tap(find.text('Japanese'));
    await tester.pumpAndSettle();
    expect(settings.translateVisibleLanguages, {'en', 'ja'});
    expect(_resolvedTarget(settings), 'ja');

    // ... and after a restart.
    final restarted = SettingsProvider(BusinessPreferences(storage.repository));
    addTearDown(restarted.dispose);
    await restarted.loaded;
    expect(_resolvedTarget(restarted), 'ja');
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
