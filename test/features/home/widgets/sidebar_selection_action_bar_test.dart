import 'package:Cuplivo/features/home/widgets/sidebar_selection_bars.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The bulk bar only offers what it can do: a selection made entirely of a
/// group's topics cannot move to an assistant, so the action is not there.
void main() {
  Future<AppLocalizations> pumpBar(
    WidgetTester tester, {
    required bool canMove,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SidebarSelectionActionBar(
            selectedCount: 2,
            allSelectedPinned: false,
            canMove: canMove,
            onPin: () {},
            onMove: () {},
            onDelete: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return AppLocalizations.of(tester.element(find.byType(Scaffold)))!;
  }

  testWidgets('offers move when the selection holds a movable conversation', (
    tester,
  ) async {
    final l10n = await pumpBar(tester, canMove: true);
    expect(find.text(l10n.sideDrawerSelectionMove), findsOneWidget);
    expect(find.text(l10n.sideDrawerSelectionPin), findsOneWidget);
    expect(find.text(l10n.sideDrawerSelectionDelete), findsOneWidget);
  });

  testWidgets('drops move when every selected row belongs to a group', (
    tester,
  ) async {
    final l10n = await pumpBar(tester, canMove: false);
    expect(find.text(l10n.sideDrawerSelectionMove), findsNothing);
    expect(find.text(l10n.sideDrawerSelectionPin), findsOneWidget);
    expect(find.text(l10n.sideDrawerSelectionDelete), findsOneWidget);
  });
}
