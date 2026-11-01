import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/group_chat/widgets/group_member_list.dart';
import 'package:Cuplivo/features/group_chat/widgets/group_settings_view.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/emoji_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/business_test_harness.dart';

/// The group's avatar is its own edit button: tapping it opens the same menu an
/// assistant avatar opens, and the choice lands on the group.
void main() {
  testWidgets('the avatar opens the shared menu and stores the choice', (
    tester,
  ) async {
    final database = createBusinessTestPreferencesWithDatabase();
    final groups = GroupChatProvider(
      store: ExtensionEntityStore(database.database),
    );
    await groups.loaded;
    final group = await groups.create(
      name: 'Reading club',
      memberIds: const [],
    );

    final assistants = AssistantProvider(
      preferences: createBusinessTestPreferences(),
    );
    await assistants.loaded;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<GroupChatProvider>.value(value: groups),
          ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
          ChangeNotifierProvider<SettingsProvider>(
            create: (_) => SettingsProvider(createBusinessTestPreferences()),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: GroupSettingsView(groupId: group.id)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // No avatar yet: the identity block shows the member cluster placeholder.
    expect(find.byType(GroupAvatar), findsOneWidget);

    await tester.tap(find.byType(GroupAvatar));
    await tester.pumpAndSettle();
    expect(find.text('Enter Link'), findsOneWidget);

    await tester.tap(find.text('Enter Link'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      'https://example.com/group.png',
    );
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(groups.byId(group.id)!.avatar, 'https://example.com/group.png');
  });

  testWidgets('an emoji avatar replaces the cluster in the identity block', (
    tester,
  ) async {
    final database = createBusinessTestPreferencesWithDatabase();
    final groups = GroupChatProvider(
      store: ExtensionEntityStore(database.database),
    );
    await groups.loaded;
    final group = await groups.create(
      name: 'Reading club',
      memberIds: const [],
    );
    await groups.update(group.id, (current) => current.copyWith(avatar: '📚'));

    final assistants = AssistantProvider(
      preferences: createBusinessTestPreferences(),
    );
    await assistants.loaded;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<GroupChatProvider>.value(value: groups),
          ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
          ChangeNotifierProvider<SettingsProvider>(
            create: (_) => SettingsProvider(createBusinessTestPreferences()),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: GroupSettingsView(groupId: group.id)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(EmojiText), findsWidgets);
    expect(find.byType(GroupAvatar), findsOneWidget);
  });

  testWidgets('the last member cannot be removed', (tester) async {
    final database = createBusinessTestPreferencesWithDatabase();
    final groups = GroupChatProvider(
      store: ExtensionEntityStore(database.database),
    );
    await groups.loaded;
    final assistants = AssistantProvider(
      preferences: createBusinessTestPreferences(),
    );
    await assistants.loaded;
    final solo = await assistants.addAssistant(name: 'Solo');
    final second = await assistants.addAssistant(name: 'Second');
    final group = await groups.create(name: 'Reading club', memberIds: [solo]);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<GroupChatProvider>.value(value: groups),
          ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
          ChangeNotifierProvider<SettingsProvider>(
            create: (_) => SettingsProvider(createBusinessTestPreferences()),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: GroupSettingsView(groupId: group.id)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Solo'), findsOneWidget);
    // No removal affordance while one member is keeping the group alive.
    expect(find.byIcon(Lucide.X), findsNothing);

    await groups.update(
      group.id,
      (current) => current.copyWith(memberIds: [solo, second]),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Lucide.X), findsNWidgets(2));
  });

  testWidgets('a turn-cap tap inside the rename debounce keeps both', (
    tester,
  ) async {
    final database = createBusinessTestPreferencesWithDatabase();
    final groups = GroupChatProvider(
      store: ExtensionEntityStore(database.database),
    );
    await groups.loaded;
    final assistants = AssistantProvider(
      preferences: createBusinessTestPreferences(),
    );
    await assistants.loaded;
    final first = await assistants.addAssistant(name: 'First');
    final second = await assistants.addAssistant(name: 'Second');
    final group = await groups.create(
      name: 'Reading club',
      memberIds: [first, second],
    );
    expect(groups.byId(group.id)!.speakerTurnLimit, 3);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<GroupChatProvider>.value(value: groups),
          ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
          ChangeNotifierProvider<SettingsProvider>(
            create: (_) => SettingsProvider(createBusinessTestPreferences()),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: GroupSettingsView(groupId: group.id)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Rename (debounced 400 ms), then lower the cap before that fires.
    await tester.enterText(find.byType(TextField), 'Renamed club');
    await tester.tap(find.byIcon(Lucide.Minus));
    await tester.pump();
    expect(groups.byId(group.id)!.speakerTurnLimit, 2);

    // The pending name write now lands.
    await tester.pump(const Duration(milliseconds: 500));

    expect(groups.byId(group.id)!.name, 'Renamed club');
    expect(
      groups.byId(group.id)!.speakerTurnLimit,
      2,
      reason: 'the cap the user just set must survive the rename',
    );
  });
}
