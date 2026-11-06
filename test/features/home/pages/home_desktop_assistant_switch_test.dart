import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/asr_provider.dart';
import 'package:Cuplivo/core/providers/backup_reminder_provider.dart';
import 'package:Cuplivo/core/providers/chat_owners_provider.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:Cuplivo/core/providers/instruction_injection_provider.dart';
import 'package:Cuplivo/core/providers/mcp_provider.dart';
import 'package:Cuplivo/core/providers/quick_phrase_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/tag_provider.dart';
import 'package:Cuplivo/core/providers/update_provider.dart';
import 'package:Cuplivo/core/providers/user_provider.dart';
import 'package:Cuplivo/core/providers/workspace_provider.dart';
import 'package:Cuplivo/core/providers/world_book_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/workspace/workspace_runtime.dart';
import 'package:Cuplivo/features/home/pages/home_desktop_layout.dart';
import 'package:Cuplivo/features/home/widgets/side_drawer.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the desktop sidebar passes the chosen assistant to the page '
      'that opens the chat', (tester) async {
    // #1065 reached Windows users while every drawer-level test stayed green,
    // because the link between this layout and the page behind it — the
    // closures that sit between the drawer's callback and the page's — had no
    // test at all. The assistant id is optional there, so a closure that
    // forwards the request without it compiles and passes everywhere except in
    // front of a user.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final closeTick = ValueNotifier<int>(0);
      addTearDown(closeTick.dispose);
      final settings = SettingsProvider(createBusinessTestPreferences());
      final assistants = AssistantProvider(
        preferences: createBusinessTestPreferences(),
      );
      final chat = ChatService();
      final database = createBusinessTestPreferencesWithDatabase().database;
      final groups = GroupChatProvider(store: ExtensionEntityStore(database));
      final tags = TagProvider(preferences: createBusinessTestPreferences());
      final user = UserProvider(preferences: createBusinessTestPreferences());
      final owners = ChatOwnersProvider(
        assistants: assistants,
        groups: groups,
        preferences: createBusinessTestPreferences(),
      );
      addTearDown(() {
        settings.dispose();
        assistants.dispose();
        chat.dispose();
        groups.dispose();
        tags.dispose();
        user.dispose();
        owners.dispose();
      });

      final requestedAssistantIds = <String?>[];
      final selectedConversations = <String>[];

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsProvider>.value(value: settings),
            ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
            ChangeNotifierProvider<ChatService>.value(value: chat),
            ChangeNotifierProvider<GroupChatProvider>.value(value: groups),
            ChangeNotifierProvider<TagProvider>.value(value: tags),
            ChangeNotifierProvider<UserProvider>.value(value: user),
            ChangeNotifierProvider<ChatOwnersProvider>.value(value: owners),
            ChangeNotifierProvider(create: (_) => WorkspaceRuntimeProvider()),
            ChangeNotifierProvider(
              create: (_) =>
                  WorkspaceProvider(store: ExtensionEntityStore(database)),
            ),
            ChangeNotifierProvider(create: (_) => AsrProvider()),
            ChangeNotifierProvider(
              create: (_) => BackupReminderProvider(
                preferences: createBusinessTestPreferences(),
                autoLoad: false,
              ),
            ),
            ChangeNotifierProvider(create: (_) => UpdateProvider()),
            ChangeNotifierProvider(
              create: (_) =>
                  McpProvider(preferences: createBusinessTestPreferences()),
            ),
            ChangeNotifierProvider(
              create: (_) => QuickPhraseProvider(
                preferences: createBusinessTestPreferences(),
              ),
            ),
            ChangeNotifierProvider(
              create: (_) => InstructionInjectionProvider(
                preferences: createBusinessTestPreferences(),
              ),
            ),
            ChangeNotifierProvider(
              create: (_) => WorldBookProvider(
                preferences: createBusinessTestPreferences(),
              ),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: HomeDesktopScaffold(
              scaffoldKey: GlobalKey<ScaffoldState>(),
              assistantPickerCloseTick: closeTick,
              loadingConversationIds: const <String>{},
              title: 'Chat',
              providerName: null,
              modelDisplay: null,
              tabletSidebarOpen: true,
              embeddedSidebarWidth: 300,
              sidebarMinWidth: 220,
              sidebarMaxWidth: 420,
              onToggleSidebar: () {},
              onSelectConversation: selectedConversations.add,
              onNewConversation: ({String? assistantId}) =>
                  requestedAssistantIds.add(assistantId),
              onCreateNewConversation: () async {},
              onToggleTemporaryConversation: () async {},
              onSelectModel: () {},
              canToggleTemporaryConversation: false,
              temporaryConversationEnabled: false,
              globalSearchMode: false,
              globalSearchQuery: '',
              onGlobalSearchQueryChanged: (_) {},
              onOpenGlobalSearchResult: (_, __, ___) async {},
              onSidebarWidthChanged: (_) {},
              onSidebarWidthChangeEnd: () {},
              buildAssistantBackground: (_) => const SizedBox.expand(),
              appBarOverride: AppBar(title: const Text('Chat')),
              body: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pump();

      // The scaffold builds the drawer; the callback it hands the drawer is
      // the seam. Asserting on it avoids tapping through a sidebar whose open
      // animation never settles under the test clock.
      final drawer = tester.widget<SideDrawer>(find.byType(SideDrawer));
      expect(drawer.onNewConversation, isNotNull);
      drawer.onNewConversation!(closeDrawer: true, assistantId: 'assistant-b');
      await tester.pump();

      expect(selectedConversations, isEmpty);
      expect(requestedAssistantIds, ['assistant-b']);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
