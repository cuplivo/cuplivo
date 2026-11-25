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

/// The drawer's remote seam: a `RemoteSidebarSource` replaces the local
/// conversation area (which describes local owners only) and receives the
/// shared search query, while the untouched drawer keeps rendering the local
/// list. This is the one branch the DeepSeek Harness home slice relies on.
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

  Future<void> pumpDrawer(
    WidgetTester tester, {
    RemoteSidebarSource? remote,
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
      final business = createBusinessTestPreferencesWithDatabase();
      settings = SettingsProvider(createBusinessTestPreferences());
      tags = TagProvider(preferences: createBusinessTestPreferences());
      assistants = AssistantProvider(preferences: business.preferences);
      groups = GroupChatProvider(
        store: ExtensionEntityStore(business.database),
      );
      await assistants.loaded;
      await assistants.addAssistant(name: 'Alpha');
      await groups.loaded;
      await settings.loaded;
      await Future<void>.delayed(const Duration(milliseconds: 100));
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
          home: Scaffold(
            body: SideDrawer(
              userName: 'User',
              assistantName: 'Assistant',
              embedded: true,
              remoteSidebarSource: remote,
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
  }

  testWidgets('local mode keeps the assistant list', (tester) async {
    await asDesktop(() async {
      await pumpDrawer(tester);
      expect(find.text('Alpha'), findsOneWidget);
    });
  });

  testWidgets('remote mode renders the injected body, not local owners', (
    tester,
  ) async {
    await asDesktop(() async {
      await pumpDrawer(
        tester,
        remote: RemoteSidebarSource(
          bodyBuilder: (context, query) => Text('remote-body:$query'),
        ),
      );
      expect(find.text('remote-body:'), findsOneWidget);
      expect(find.text('Alpha'), findsNothing);
    });
  });

  testWidgets('remote mode forwards the shared search query', (tester) async {
    await asDesktop(() async {
      await pumpDrawer(
        tester,
        remote: RemoteSidebarSource(
          bodyBuilder: (context, query) => Text('remote-body:$query'),
        ),
      );
      await tester.enterText(find.byType(TextField).first, 'plan');
      await tester.pump();
      expect(find.text('remote-body:plan'), findsOneWidget);
    });
  });
}
