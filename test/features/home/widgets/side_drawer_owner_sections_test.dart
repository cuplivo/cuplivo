import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/backup_reminder_provider.dart';
import 'package:Cuplivo/core/providers/chat_owners_provider.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/tag_provider.dart';
import 'package:Cuplivo/core/providers/update_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/home/widgets/side_drawer.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../support/business_test_harness.dart';

/// The sidebar half of the one switch: with it on, group chats leave the
/// assistant rows and land in their own section, below the tags.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> asDesktop(Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  Future<SettingsProvider> pumpDrawer(
    WidgetTester tester, {
    required bool separate,
  }) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late SettingsProvider settings;
    late TagProvider tags;
    late AssistantProvider assistants;
    late GroupChatProvider groups;
    late ChatOwnersProvider owners;

    await tester.runAsync(() async {
      // Built inside runAsync: a provider or preference view constructed in the
      // fake zone keeps its load and its writes waiting on a zone the test
      // never drains.
      final business = createBusinessTestPreferencesWithDatabase();
      settings = SettingsProvider(createBusinessTestPreferences());
      tags = TagProvider(preferences: createBusinessTestPreferences());
      assistants = AssistantProvider(preferences: business.preferences);
      groups = GroupChatProvider(
        store: ExtensionEntityStore(business.database),
      );
      await assistants.loaded;
      final alpha = await assistants.addAssistant(name: 'Alpha');
      final beta = await assistants.addAssistant(name: 'Beta');
      await groups.loaded;
      await groups.create(name: 'Gamma', memberIds: [alpha, beta]);
      await settings.loaded;
      await settings.setSeparateChatOwners(separate);
      // The tag provider loads in its constructor; give that read a turn before
      // writing a tag through it, or the load overwrites the write.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final tagId = await tags.createTag('Work');
      await tags.assignAssistantToTag(beta, tagId);
      owners = ChatOwnersProvider(
        assistants: assistants,
        groups: groups,
        preferences: business.preferences,
      );
      await owners.loaded;
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ChatService>.value(value: ChatService()),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
          ChangeNotifierProvider<GroupChatProvider>.value(value: groups),
          ChangeNotifierProvider<ChatOwnersProvider>.value(value: owners),
          ChangeNotifierProvider<TagProvider>.value(value: tags),
          ChangeNotifierProvider(
            create: (_) => BackupReminderProvider(
              preferences: createBusinessTestPreferences(),
            ),
          ),
          ChangeNotifierProvider(create: (_) => UpdateProvider()),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: SideDrawer(
              userName: 'User',
              assistantName: 'Assistant',
              embedded: true,
              desktopAssistantsOnly: true,
              globalSearchMode: false,
              globalSearchQuery: '',
              showBottomBar: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return settings;
  }

  testWidgets('group chats get their own section below the tags', (
    tester,
  ) async {
    await asDesktop(() async {
      await pumpDrawer(tester, separate: true);

      // Two labels, and the tag sits between them: assistants (untagged, then
      // tags) above, group chats below.
      expect(find.text('Assistants'), findsOneWidget);
      expect(find.text('Groups'), findsOneWidget);
      expect(find.text('Work'), findsOneWidget);

      double top(String text) => tester.getTopLeft(find.text(text)).dy;
      expect(top('Alpha'), lessThan(top('Work')));
      expect(top('Work'), lessThan(top('Beta')));
      expect(top('Beta'), lessThan(top('Groups')));
      expect(top('Groups'), lessThan(top('Gamma')));

      // Under 「助手」 the tag is a child, and it has to look like one: drawn in
      // the same type as the section header it would read as a third section
      // rather than as the assistants it files away.
      final sectionStyle = tester.widget<Text>(find.text('Assistants')).style!;
      final tagStyle = tester.widget<Text>(find.text('Work')).style!;
      expect(tagStyle.fontSize, lessThan(sectionStyle.fontSize!));
      expect(tagStyle.color!.a, lessThan(sectionStyle.color!.a));
    });
  });

  testWidgets('with the switch off the list stays mixed', (tester) async {
    await asDesktop(() async {
      await pumpDrawer(tester, separate: false);

      expect(find.text('Assistants'), findsNothing);
      expect(find.text('Groups'), findsNothing);
      // Mixed keeps today's shape: the group sits in the untagged part, the tag
      // section comes last.
      expect(find.text('Gamma'), findsOneWidget);
      expect(find.text('Work'), findsOneWidget);
      double top(String text) => tester.getTopLeft(find.text(text)).dy;
      expect(top('Gamma'), lessThan(top('Work')));

      // With no parent section above it, a tag is a top-level section of its own
      // and keeps its own size — the subordinate style belongs to the split only.
      final tagStyle = tester.widget<Text>(find.text('Work')).style!;
      expect(tagStyle.fontSize, 13.5);
    });
  });
}
