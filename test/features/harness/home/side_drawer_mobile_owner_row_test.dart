import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/backup_reminder_provider.dart';
import 'package:Cuplivo/core/providers/chat_owners_provider.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/tag_provider.dart';
import 'package:Cuplivo/core/providers/update_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/harness/models/dsh_web_ui_link.dart';
import 'package:Cuplivo/features/harness/services/dsh_credential_store.dart';
import 'package:Cuplivo/features/harness/services/dsh_remote_store.dart';
import 'package:Cuplivo/features/harness/state/dsh_connections_provider.dart';
import 'package:Cuplivo/features/home/widgets/side_drawer.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../support/business_test_harness.dart';

class _MemoryCredentials implements DshCredentialStore {
  @override
  Future<void> deleteCookie(String remoteId) async {}

  @override
  Future<String?> readCookie(String remoteId) async => null;

  @override
  Future<void> writeCookie(String remoteId, String cookie) async {}
}

/// The phone's only path from the local drawer into a remote's harness home.
///
/// The mobile drawer body is the local conversation list; the owner rows
/// (assistants, groups and DeepSeek Harness remotes) live in the inline picker
/// that the current-assistant header expands. The E2E scenario taps that header
/// before `dsh-owner-row`, so this test pins the same gesture: collapsed, no
/// owner row exists; expanded, the remote row is reachable.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpPhoneDrawer(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late SettingsProvider settings;
    late TagProvider tags;
    late AssistantProvider assistants;
    late GroupChatProvider groups;
    late ChatOwnersProvider owners;
    late DshConnectionsProvider connections;

    await tester.runAsync(() async {
      final business = createBusinessTestPreferencesWithDatabase();
      settings = SettingsProvider(createBusinessTestPreferences());
      tags = TagProvider(preferences: createBusinessTestPreferences());
      assistants = AssistantProvider(preferences: business.preferences);
      groups = GroupChatProvider(
        store: ExtensionEntityStore(business.database),
      );
      connections = DshConnectionsProvider(
        store: DshRemoteStore(createBusinessTestPreferences()),
        credentials: _MemoryCredentials(),
      );
      await assistants.loaded;
      await assistants.addAssistant(name: 'Alpha');
      await groups.loaded;
      await settings.loaded;
      await connections.loaded;
      final link = DshWebUiLink.tryParse('http://127.0.0.1:3080/?token=fake');
      expect(link, isNotNull);
      await connections.createRemote(name: 'DeepSeek Harness', link: link!);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      owners = ChatOwnersProvider(
        assistants: assistants,
        groups: groups,
        preferences: business.preferences,
        harnesses: connections,
      );
      await owners.loaded;
    });
    addTearDown(connections.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ChatService>.value(value: ChatService()),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
          ChangeNotifierProvider<GroupChatProvider>.value(value: groups),
          ChangeNotifierProvider<ChatOwnersProvider>.value(value: owners),
          ChangeNotifierProvider<TagProvider>.value(value: tags),
          ChangeNotifierProvider<DshConnectionsProvider>.value(
            value: connections,
          ),
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

  testWidgets('the remote owner row is hidden until the picker expands', (
    tester,
  ) async {
    await pumpPhoneDrawer(tester);

    final ownerRow = find.byKey(const Key('dsh-owner-row'));
    expect(
      ownerRow,
      findsNothing,
      reason: 'the collapsed conversation-list drawer has no owner rows',
    );

    final toggle = find.byKey(const Key('dsh-assistant-picker-toggle'));
    expect(toggle, findsOneWidget, reason: 'the current-assistant header tile');
    await tester.tap(toggle);
    await tester.pump();
    // The header schedules its scroll animation on a 10 ms timer, and the inline
    // list is revealed through AnimatedSize (260 ms) + AnimatedSwitcher
    // (220 ms); flush them before asserting so no timer outlives the test.
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(ownerRow, findsOneWidget, reason: 'the expanded owner list');
    expect(find.text('DeepSeek Harness'), findsWidgets);
  });
}
