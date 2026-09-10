import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/assistant/pages/assistant_settings_edit_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_switch.dart';
import 'package:Cuplivo/shared/widgets/sf_slider_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'static toggle persists and position dragging only writes on release',
    (tester) async {
      const id = 'gradient-assistant';
      SharedPreferences.setMockInitialValues({
        'assistants_v1': Assistant.encodeList([
          Assistant(id: id, name: 'Gradient', useGradientBackground: true),
        ]),
      });
      final prefs = BusinessPreferences.memoryForTests();
      final assistants = AssistantProvider(preferences: prefs);
      await assistants.loadFromPrefs();
      await assistants.setCurrentAssistant(id);
      final settings = SettingsProvider(preferences: prefs);
      await settings.loaded;
      addTearDown(assistants.dispose);
      addTearDown(settings.dispose);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
            ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SingleChildScrollView(
                child: Consumer<AssistantProvider>(
                  builder: (_, value, child) => AssistantGradientSettings(
                    assistant: value.currentAssistant!,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final initialPhase = assistants.currentAssistant!.gradientBackgroundPhase;
      expect(find.text('Static mode'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Gradient background')).dx,
        tester.getTopLeft(find.text('Static mode')).dx,
      );
      expect(
        tester.getBottomRight(find.byType(IosSwitch).first).dx,
        tester.getBottomRight(find.byType(IosSwitch).last).dx,
      );
      expect(
        tester.getCenter(find.text('Gradient background')).dy,
        tester.getCenter(find.byType(IosSwitch).first).dy,
      );
      expect(
        tester.getCenter(find.text('Static mode')).dy,
        tester.getCenter(find.byType(IosSwitch).last).dy,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.tap(find.byType(IosSwitch).last);
      await tester.pumpAndSettle();
      expect(assistants.currentAssistant!.gradientBackgroundAnimated, isFalse);
      expect(
        assistants.currentAssistant!.gradientBackgroundPhase,
        closeTo(initialPhase + 3, 0.05),
      );
      final frozen = assistants.currentAssistant!.gradientBackgroundPhase;
      await tester.tap(find.text('Another frame'));
      await tester.pumpAndSettle();
      expect(
        assistants.currentAssistant!.gradientBackgroundPhase,
        isNot(frozen),
      );
      expect(assistants.currentAssistant!.gradientBackgroundAnimated, isFalse);
      expect(find.byType(SfSliderTile), findsNWidgets(2));
      final horizontal = tester.widget<SfSliderTile>(
        find.byType(SfSliderTile).first,
      );
      expect(horizontal.semanticLabel, 'Horizontal position');
      horizontal.onChanged!(0.6);
      await tester.pump();
      expect(assistants.currentAssistant!.gradientBackgroundOffsetX, 0);
      expect(
        tester.widget<SfSliderTile>(find.byType(SfSliderTile).first).value,
        0.6,
      );
      horizontal.onChangeEnd!(0.6);
      await tester.pumpAndSettle();
      expect(assistants.currentAssistant!.gradientBackgroundOffsetX, 0.6);
      final vertical = tester.widget<SfSliderTile>(
        find.byType(SfSliderTile).last,
      );
      expect(vertical.semanticLabel, 'Vertical position');
      vertical.onChanged!(-0.4);
      await tester.pump();
      expect(assistants.currentAssistant!.gradientBackgroundOffsetY, 0);
      vertical.onChangeEnd!(-0.4);
      await tester.pumpAndSettle();
      expect(assistants.currentAssistant!.gradientBackgroundOffsetY, -0.4);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
