import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/models/chat_owner.dart';
import 'package:Cuplivo/core/models/conversation.dart';
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

/// The drawer's half of the owner pipeline: one callback for both kinds, and a
/// list whose scope is the owner of the open chat — never the persisted
/// assistant as a second source.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('an assistant tap and a group tap both report one owner', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final opened = <ChatOwner>[];
      final selected = <String>[];
      final created = <bool>[];
      final rig = await _pump(
        tester,
        chat: _FakeChat(),
        onOpenOwner: (owner) async => opened.add(owner),
        onSelectConversation: (id) => selected.add(id),
        onNewConversation: () => created.add(true),
      );

      await tester.tap(find.text('Alpha'));
      await tester.pump();
      await tester.tap(find.text('Gamma'));
      await tester.pump();

      expect(opened, [
        ChatOwner.assistant(rig.alpha),
        ChatOwner.group(rig.gamma),
      ]);
      // The drawer asks the page to open an owner; it does not also pick a
      // conversation or start one behind the page's back.
      expect(selected, isEmpty);
      expect(created, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the topic list follows the chat that is open', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final chat = _FakeChat();
      final rig = await _pump(tester, chat: chat, topicsOnly: true);
      final groupTopic = Conversation(
        title: 'Group topic',
        extras: {Conversation.groupChatIdKey: rig.gamma},
      );
      final alphaChat = Conversation(
        title: 'Alpha chat',
        assistantId: rig.alpha,
      );
      chat.seed(groupTopic);
      chat.seed(alphaChat);
      await tester.pumpAndSettle();

      // No chat is open, so the list falls back to the assistant the next 1:1
      // would belong to rather than showing nothing.
      expect(find.text('Alpha chat'), findsOneWidget);
      expect(find.text('Group topic'), findsNothing);

      chat.setCurrent(groupTopic.id);
      await tester.pumpAndSettle();
      expect(find.text('Group topic'), findsOneWidget);
      expect(find.text('Alpha chat'), findsNothing);

      chat.setCurrent(alphaChat.id);
      await tester.pumpAndSettle();
      expect(find.text('Alpha chat'), findsOneWidget);
      expect(find.text('Group topic'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a generating group topic puts the dot on its group row', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final chat = _FakeChat();
      final rig = await _pump(
        tester,
        chat: chat,
        topicsOnly: false,
        loadingGroupTopic: 'Group topic',
      );

      // The busy chat is a group topic, which owns no assistant: the indicator
      // belongs to the group row. Asking the fallback assistant painted it on
      // whichever assistant happened to be selected, so the dot moved as soon as
      // the user switched away from the generating chat.
      expect(_loadingOwnerNames(tester), ['Gamma']);
      expect(_selectedOwnerNames(tester), ['Gamma']);
      expect(rig.assistants.currentAssistantId, rig.alpha);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a group topic highlights its group, not the last assistant', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final chat = _FakeChat();
      final rig = await _pump(tester, chat: chat);
      final groupTopic = Conversation(
        title: 'Group topic',
        extras: {Conversation.groupChatIdKey: rig.gamma},
      );
      chat.seed(groupTopic);
      chat.setCurrent(groupTopic.id);
      await tester.pumpAndSettle();

      // The selected row is derived from the open chat for both kinds; the
      // persisted assistant stays where it was.
      expect(_selectedOwnerNames(tester), ['Gamma']);
      expect(rig.assistants.currentAssistantId, rig.alpha);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

/// Names of the owner rows the drawer paints as generating.
List<String> _loadingOwnerNames(WidgetTester tester) {
  final names = <String>[];
  for (final element in find.byType(SideDrawer).evaluate()) {
    void visit(Element element) {
      final widget = element.widget;
      if (widget.runtimeType.toString() == '_AssistantInlineTile') {
        final dynamic tile = widget;
        if (tile.loading == true) names.add(tile.name as String);
      }
      element.visitChildElements(visit);
    }

    visit(element);
  }
  return names;
}

/// Names of the owner rows the drawer paints as selected.
List<String> _selectedOwnerNames(WidgetTester tester) {
  final names = <String>[];
  for (final element in find.byType(SideDrawer).evaluate()) {
    void visit(Element element) {
      final widget = element.widget;
      // `_AssistantInlineTile` is private to the drawer's library; the field is
      // public, so this reads the same flag the paint uses.
      if (widget.runtimeType.toString() == '_AssistantInlineTile') {
        final dynamic tile = widget;
        if (tile.selected == true) names.add(tile.name as String);
      }
      element.visitChildElements(visit);
    }

    visit(element);
  }
  return names;
}

class _Rig {
  _Rig({required this.alpha, required this.gamma, required this.assistants});

  final String alpha;
  final String gamma;
  final AssistantProvider assistants;
}

class _FakeChat extends ChatService {
  final List<Conversation> conversations = <Conversation>[];
  String? _open;

  @override
  bool get initialized => true;

  @override
  int get conversationListRevision =>
      conversations.length + (_open == null ? 0 : 1);

  @override
  String? get currentConversationId => _open;

  @override
  void setCurrentConversation(String? id) => _open = id;

  @override
  List<Conversation> getAllConversations() =>
      List<Conversation>.of(conversations);

  @override
  Conversation? getConversation(String id) =>
      conversations.where((c) => c.id == id).firstOrNull;

  void seed(Conversation conversation) {
    conversations.add(conversation);
    notifyListeners();
  }

  void setCurrent(String? id) {
    _open = id;
    notifyListeners();
  }
}

Future<_Rig> _pump(
  WidgetTester tester, {
  required ChatService chat,
  bool topicsOnly = false,
  String? loadingGroupTopic,
  Future<void> Function(ChatOwner owner)? onOpenOwner,
  void Function(String id)? onSelectConversation,
  void Function()? onNewConversation,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  late AssistantProvider assistants;
  late GroupChatProvider groups;
  late String alpha;
  late String gamma;

  await tester.runAsync(() async {
    final business = createBusinessTestPreferencesWithDatabase();
    final settings = SettingsProvider(createBusinessTestPreferences());
    final tags = TagProvider(preferences: createBusinessTestPreferences());
    final backup = BackupReminderProvider(
      preferences: createBusinessTestPreferences(),
    );
    assistants = AssistantProvider(preferences: business.preferences);
    groups = GroupChatProvider(store: ExtensionEntityStore(business.database));
    await assistants.loaded;
    alpha = await assistants.addAssistant(name: 'Alpha');
    await assistants.addAssistant(name: 'Beta');
    await groups.loaded;
    gamma = (await groups.create(name: 'Gamma', memberIds: [alpha])).id;
    await settings.loaded;
    // The backup reminder loads in its constructor; give that read a turn, or it
    // notifies a listener after this test's tree is gone.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // A chat that is generating while the tree is first built: the indicator has
    // to be derived from ownership, not from the selected assistant.
    var loadingIds = const <String>{};
    if (loadingGroupTopic != null && chat is _FakeChat) {
      final topic = Conversation(
        title: loadingGroupTopic,
        extras: {Conversation.groupChatIdKey: gamma},
      );
      chat.seed(topic);
      chat.setCurrent(topic.id);
      loadingIds = {topic.id};
    }
    final owners = ChatOwnersProvider(
      assistants: assistants,
      groups: groups,
      preferences: business.preferences,
    );
    await owners.loaded;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ChatService>.value(value: chat),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
          ChangeNotifierProvider<GroupChatProvider>.value(value: groups),
          ChangeNotifierProvider<ChatOwnersProvider>.value(value: owners),
          ChangeNotifierProvider<TagProvider>.value(value: tags),
          ChangeNotifierProvider<BackupReminderProvider>.value(value: backup),
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
              desktopAssistantsOnly: !topicsOnly,
              desktopTopicsOnly: topicsOnly,
              globalSearchMode: false,
              globalSearchQuery: '',
              loadingConversationIds: loadingIds,
              showBottomBar: false,
              onOpenOwner: onOpenOwner,
              onSelectConversation: onSelectConversation == null
                  ? null
                  : (id, {closeDrawer = true}) => onSelectConversation(id),
              onNewConversation: onNewConversation == null
                  ? null
                  : ({closeDrawer = true}) => onNewConversation(),
            ),
          ),
        ),
      ),
    );
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return _Rig(alpha: alpha, gamma: gamma, assistants: assistants);
}
