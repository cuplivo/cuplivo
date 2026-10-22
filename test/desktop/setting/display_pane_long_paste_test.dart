import '../../support/business_test_harness.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/desktop/desktop_settings_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  testWidgets(
    'desktop threshold restores the current value after a blank submit',
    (tester) async {
      final settings = SettingsProvider(createBusinessTestPreferences());
      addTearDown(settings.dispose);
      await settings.loaded;

      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ChangeNotifierProvider<SettingsProvider>.value(
          value: settings,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: DesktopSettingsPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final label = find.text('Conversion threshold');
      await tester.scrollUntilVisible(
        label,
        320,
        scrollable: find
            .descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();

      final field = find.descendant(
        of: find.ancestor(of: label, matching: find.byType(Row)).first,
        matching: find.byType(TextField),
      );
      expect(field, findsOneWidget);

      await tester.enterText(field, '8000');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(settings.longPasteAsFileThreshold, 8000);

      await tester.enterText(field, '');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(tester.widget<TextField>(field).controller?.text, '8000');
      expect(settings.longPasteAsFileThreshold, 8000);
    },
  );
}
