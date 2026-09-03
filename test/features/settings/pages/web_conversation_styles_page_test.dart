import 'dart:io';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/web_conversation_style.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/settings/pages/display_settings_page.dart';
import 'package:Cuplivo/features/settings/pages/web_conversation_styles_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_switch.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

WebConversationStyle testStyle() => WebConversationStyle.fromRaw({
  'kind': webConversationStyleKind,
  'schemaVersion': 1,
  'id': 'soft-cards',
  'name': 'Soft Cards',
  'description': 'Rounded surfaces',
  'common': {
    'userBubble': {'cornerRadius': 20},
  },
  'light': <String, dynamic>{},
  'dark': <String, dynamic>{},
});

Future<SettingsProvider> pumpPage(
  WidgetTester tester,
  Widget page, {
  Size size = const Size(900, 700),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final settings = SettingsProvider(
    preferences: BusinessPreferences.memoryForTests(),
  );
  await settings.loaded;
  addTearDown(settings.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<SettingsProvider>.value(
      value: settings,
      child: MaterialApp(
        key: UniqueKey(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return settings;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'mobile rendering page shows entry under WebView only on support',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await pumpPage(tester, const RenderingSettingsPage());

      expect(find.text('Experimental: WebView rendering'), findsOneWidget);
      expect(find.text('Web conversation styles'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Experimental: WebView rendering')).dy,
        lessThan(tester.getTopLeft(find.text('Web conversation styles')).dy),
      );
      await tester.tap(find.text('Web conversation styles'));
      await tester.pumpAndSettle();
      expect(find.text('Default style'), findsOneWidget);
      expect(find.textContaining('WebView rendering is off'), findsOneWidget);

      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await pumpPage(tester, const RenderingSettingsPage());
      expect(find.text('Web conversation styles'), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('mobile styles page does not duplicate the WebView toggle', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pumpPage(tester, const WebConversationStylesPage());

    expect(find.text('Experimental: WebView rendering'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('desktop pane renders on forced Windows and macOS branches', (
    tester,
  ) async {
    for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
      debugDefaultTargetPlatformOverride = platform;
      await pumpPage(tester, const WebConversationStylesPage(desktop: true));
      expect(find.text('Web conversation styles'), findsOneWidget);
      expect(find.text('Experimental: WebView rendering'), findsOneWidget);
      expect(find.text('Default style'), findsOneWidget);
      expect(find.text('Import'), findsOneWidget);
    }
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('desktop WebView toggle controls the inactive-style notice', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final settings = await pumpPage(
      tester,
      const WebConversationStylesPage(desktop: true),
    );

    final title = find.text('Experimental: WebView rendering');
    final inactiveNotice = find.textContaining('WebView rendering is off');
    final toggle = find.byType(IosSwitch);
    expect(toggle, findsOneWidget);
    expect(
      tester.getTopLeft(title).dy,
      lessThan(tester.getTopLeft(inactiveNotice).dy),
    );

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(settings.experimentalWebViewRendering, isTrue);
    expect(inactiveNotice, findsNothing);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(settings.experimentalWebViewRendering, isFalse);
    expect(inactiveNotice, findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('imported style exposes activation, export and delete actions', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final settings = await pumpPage(
      tester,
      const WebConversationStylesPage(desktop: true),
    );
    await settings.importWebConversationStyles([testStyle()]);
    await tester.pumpAndSettle();

    expect(find.text('Soft Cards'), findsOneWidget);
    expect(find.byTooltip('Use style'), findsOneWidget);
    expect(find.byTooltip('Export'), findsOneWidget);
    expect(find.byTooltip('Delete'), findsOneWidget);

    await tester.tap(find.byTooltip('Use style'));
    await tester.pumpAndSettle();
    expect(settings.activeWebConversationStyle?.id, 'soft-cards');
    expect(find.text('Active'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete style'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(settings.activeWebConversationStyle, isNull);
    expect(find.text('Soft Cards'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  test('desktop sidebar source gates the pane through viewport support', () {
    final source = File(
      'lib/desktop/desktop_settings_page.dart',
    ).readAsStringSync();
    expect(source, contains('_SettingsMenuItem.webConversationStyles'));
    expect(source, contains('DesktopWebConversationStylesPane'));
    expect(source, contains('supportsWebConversationViewport('));
  });
}
