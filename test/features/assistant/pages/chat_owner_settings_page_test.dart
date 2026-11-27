import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/chat_owners_provider.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/assistant/pages/assistant_settings_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_switch.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../support/business_test_harness.dart';

/// `Alpha` and `Beta` for the two-row cases, then `A02`… for a list long enough
/// to need scrolling.
String assistantName(int index) => switch (index) {
  0 => 'Alpha',
  1 => 'Beta',
  _ => 'A${index.toString().padLeft(2, '0')}',
};

/// Settings › Assistants and groups: one switch decides whether the page (and
/// the sidebar) show the two kinds as sections or as one mixed list.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SettingsProvider> pumpPage(
    WidgetTester tester, {
    required bool withGroup,
    int assistantCount = 2,
    bool separated = false,
  }) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late SettingsProvider settings;
    late AssistantProvider assistants;
    late GroupChatProvider groups;
    late ChatOwnersProvider owners;

    await tester.runAsync(() async {
      // The whole harness is built inside runAsync: a provider or preference
      // view constructed in the fake zone leaves its load and its writes
      // waiting on a zone the test never drains, which is a ten-minute timeout
      // rather than a failure.
      final business = createBusinessTestPreferencesWithDatabase();
      settings = SettingsProvider(createBusinessTestPreferences());
      assistants = AssistantProvider(preferences: business.preferences);
      await assistants.loaded;
      final ids = <String>[];
      for (var i = 0; i < assistantCount; i++) {
        ids.add(await assistants.addAssistant(name: assistantName(i)));
      }
      groups = GroupChatProvider(
        store: ExtensionEntityStore(business.database),
      );
      await groups.loaded;
      if (withGroup) {
        await groups.create(name: 'Gamma', memberIds: [ids.first, ids.last]);
      }
      owners = ChatOwnersProvider(
        assistants: assistants,
        groups: groups,
        preferences: business.preferences,
      );
      await owners.loaded;
      await settings.loaded;
      if (separated) await settings.setSeparateChatOwners(true);
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
          ChangeNotifierProvider<GroupChatProvider>.value(value: groups),
          ChangeNotifierProvider<ChatOwnersProvider>.value(value: owners),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChatOwnerSettingsPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return settings;
  }

  testWidgets('the switch appears with the first group and splits the list', (
    tester,
  ) async {
    final settings = await pumpPage(tester, withGroup: true);

    // Mixed by default: no section labels, the group sits in the shared order
    // between the two assistants it would otherwise be sorted away from.
    expect(find.byType(IosSwitch), findsOneWidget);
    expect(find.text('Assistants'), findsNothing);
    expect(find.text('Groups'), findsNothing);
    expect(
      tester.getTopLeft(find.text('Beta')).dy,
      lessThan(tester.getTopLeft(find.text('Gamma')).dy),
    );

    await tester.tap(find.byType(IosSwitch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(settings.separateChatOwners, isTrue);
    expect(find.text('Assistants'), findsOneWidget);
    expect(find.text('Groups'), findsOneWidget);
    // Assistants above the group section, and the group below its own label.
    expect(
      tester.getTopLeft(find.text('Beta')).dy,
      lessThan(tester.getTopLeft(find.text('Groups')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Groups')).dy,
      lessThan(tester.getTopLeft(find.text('Gamma')).dy),
    );
  });

  testWidgets('without a group there is nothing to separate, so no switch', (
    tester,
  ) async {
    await pumpPage(tester, withGroup: false);

    expect(find.byType(IosSwitch), findsNothing);
    expect(find.text('Assistants'), findsNothing);
    expect(find.text('Groups'), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets('a row dragged to the edge scrolls the page, not its section', (
    tester,
  ) async {
    await pumpPage(
      tester,
      withGroup: true,
      assistantCount: 25,
      separated: true,
    );

    // The page must own the only scrollable. Give each section its own
    // `ReorderableListView` and a drag auto-scrolls *that* one — and Flutter
    // refuses a scrollable whose physics reject user offsets — so a row can
    // only be dropped inside the window it started in.
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final double before = scrollable.position.pixels;
    expect(before, greaterThan(0), reason: 'the page needs to be scrolled');

    // Long-press the group — the last row — then hold it at the top edge.
    final drag = await tester.startGesture(
      tester.getCenter(find.text('Gamma')),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await drag.moveBy(const Offset(0, -20));
    await tester.pump();
    await drag.moveTo(const Offset(200, 70));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final double during = scrollable.position.pixels;
    await drag.up();
    await tester.pumpAndSettle();

    expect(
      before - during,
      greaterThan(0),
      reason: 'a drag held at the top edge must scroll the page towards it',
    );
    // The structural half of the same property: one scrollable, so a nested
    // reorderable cannot come back unnoticed.
    expect(find.byType(Scrollable), findsOneWidget);
  });
}
