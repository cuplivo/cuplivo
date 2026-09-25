import '../../../support/business_test_harness.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/search/pages/search_service_editor_page.dart';
import 'package:Cuplivo/features/search/pages/search_services_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('opens a provider in the full-page editor', (tester) async {
    final settings = SettingsProvider(createBusinessTestPreferences());
    addTearDown(settings.dispose);
    await settings.loaded;

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SearchServicesPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SearchServiceEditorPage), findsNothing);
    final providerRows = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return widget is Row &&
          key is ValueKey<String> &&
          key.value.startsWith('search-service-row-');
    });
    expect(providerRows, findsWidgets);
    for (final row in tester.widgetList<Row>(providerRows)) {
      expect(row.crossAxisAlignment, CrossAxisAlignment.center);
      expect(tester.getSize(find.byKey(row.key!)).height, 22);
    }

    await tester.tap(find.text('Bing (Local)'));
    await tester.pumpAndSettle();

    expect(find.byType(SearchServiceEditorPage), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
  });
}
