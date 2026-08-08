import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/settings/pages/new/log_settings_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_switch.dart';
import 'package:Cuplivo/features/settings/widgets/ios_settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _buildHarness(SettingsProvider settings, Widget home) {
  return ChangeNotifierProvider<SettingsProvider>.value(
    value: settings,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: home,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  testWidgets('renders all five logging switches', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final settings = SettingsProvider();
    addTearDown(settings.dispose);
    await tester.pumpWidget(_buildHarness(settings, const LogSettingsPage()));
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(LogSettingsPage)),
    )!;
    expect(find.text(l10n.requestLogSettingTitle), findsOneWidget);
    expect(find.text(l10n.logSettingsMcpEnabled), findsOneWidget);
    expect(find.text(l10n.logSettingsTtsEnabled), findsOneWidget);
    expect(find.text(l10n.logSettingsSearchEnabled), findsOneWidget);
    expect(find.text(l10n.flutterLogSettingTitle), findsOneWidget);
    expect(find.byType(IosSwitch), findsNWidgets(5));
  });

  testWidgets('toggling the request log switch persists', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final settings = SettingsProvider();
    addTearDown(settings.dispose);
    await tester.pumpWidget(_buildHarness(settings, const LogSettingsPage()));
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(LogSettingsPage)),
    )!;
    expect(settings.requestLogEnabled, isFalse);

    final row = find.ancestor(
      of: find.text(l10n.requestLogSettingTitle),
      matching: find.byType(IosSettingsSwitchRow),
    );
    await tester.tap(
      find.descendant(of: row, matching: find.byType(IosSwitch)),
    );
    await tester.pumpAndSettle();

    expect(settings.requestLogEnabled, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('request_log_enabled_v1'), isTrue);
  });

  testWidgets('each logging switch flips its provider getter', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final settings = SettingsProvider();
    addTearDown(settings.dispose);
    await tester.pumpWidget(_buildHarness(settings, const LogSettingsPage()));
    await tester.pumpAndSettle();

    final rows = <String, bool Function(SettingsProvider)>{
      'request_log_enabled_v1': (s) => s.requestLogEnabled,
      'mcp_log_enabled_v1': (s) => s.mcpLogEnabled,
      'tts_log_enabled_v1': (s) => s.ttsLogEnabled,
      'search_log_enabled_v1': (s) => s.searchLogEnabled,
      'flutter_log_enabled_v1': (s) => s.flutterLogEnabled,
    };

    for (var i = 0; i < rows.length; i++) {
      final key = rows.keys.elementAt(i);
      final getter = rows[key]!;
      expect(getter(settings), isFalse, reason: 'initial state for $key');

      final switches = find.byType(IosSwitch);
      expect(switches, findsNWidgets(5));
      await tester.tap(switches.at(i));
      await tester.pumpAndSettle();

      expect(getter(settings), isTrue, reason: 'after toggle for $key');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(key), isTrue, reason: 'persisted for $key');

      await tester.tap(find.byType(IosSwitch).at(i));
      await tester.pumpAndSettle();

      expect(getter(settings), isFalse, reason: 'after untoggle for $key');
    }
  });
}
