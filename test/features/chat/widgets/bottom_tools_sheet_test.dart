import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/world_book_provider.dart';
import 'package:Cuplivo/features/chat/widgets/bottom_tools_sheet.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('mobile tools sheet exposes the workspace action', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var taps = 0;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
          ChangeNotifierProvider(create: (_) => AssistantProvider()),
          ChangeNotifierProvider(create: (_) => WorldBookProvider()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: BottomToolsSheet(onOpenWorkspace: () => taps++)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(BottomToolsSheet)),
    )!;

    await tester.tap(find.text(l10n.workspaceEntryTitle));
    expect(taps, 1);
  });
}
