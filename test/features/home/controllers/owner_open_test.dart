import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../support/business_test_harness.dart';
import 'package:Cuplivo/core/database/composer_draft_store.dart';
import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/chat_owner.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/desktop/hotkeys/sidebar_tab_bus.dart';
import 'package:Cuplivo/features/home/controllers/home_page_controller.dart';
import 'package:Cuplivo/features/home/controllers/scroll_controller.dart';
import 'package:Cuplivo/features/home/widgets/chat_input_bar.dart';
import 'package:Cuplivo/features/side_panel/desktop_side_panel_controller.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

/// One tap on an owner, end to end at the controller: which conversation opens,
/// whose it is, and whether the list is revealed.
///
/// The matrix is 6 rows (a group topic, an assistant, a dead group, a 1:1, a
/// group with and without topics) × the switch's two states. The reveal half is
/// the layout table: three layouts × the setting.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> runAsDesktop(Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  /// Lets the scroll-to-bottom timer a new conversation arms fire, so a test
  /// never ends with a pending timer.
  Future<void> settle(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 250));

  Future<_Rig> pumpRig(WidgetTester tester) async {
    final preferences = createBusinessTestPreferencesWithDatabase();
    final settings = SettingsProvider(preferences.preferences);
    final assistants = AssistantProvider(
      preferences: createBusinessTestPreferences(),
    );
    final groups = GroupChatProvider(
      store: ExtensionEntityStore(preferences.database),
    );
    await assistants.loaded;
    await groups.loaded;
    await assistants.addAssistant(name: 'A');
    await assistants.addAssistant(name: 'B');
    final chat = _OwnerChatService();
    final rig = _Rig(
      chat: chat,
      assistants: assistants,
      groups: groups,
      settings: settings,
    );
    HomePageController? controller;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<ChatService>.value(value: chat),
          ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
          ChangeNotifierProvider<GroupChatProvider>.value(value: groups),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: _Harness(onCreated: (value) => controller = value),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    rig.controller = controller!;
    // Pump until the providers' own pending work settles so a test never reads a
    // half-built provider.
    await tester.pump();
    return rig;
  }

  group('openOwner resolves the conversation', () {
    // Each case: start state, tapped owner, switch state -> expected outcome.
    for (final wantsNewChat in [true, false]) {
      testWidgets(
        'a group topic + assistant with history (newChat=$wantsNewChat)',
        (tester) async {
          await runAsDesktop(() async {
            final rig = await pumpRig(tester);
            await rig.settings.setNewChatOnAssistantSwitch(wantsNewChat);
            final group = await rig.groups.create(
              name: 'G',
              memberIds: const [],
            );
            final topic = rig.chat.seed(
              title: 'topic',
              groupChatId: group.id,
              updatedAt: DateTime(2026, 1, 3),
            );
            final recent = rig.chat.seed(
              title: 'A recent',
              assistantId: rig.assistantA,
              updatedAt: DateTime(2026, 1, 2),
            );
            await rig.startIn(topic);

            await rig.controller.openOwner(ChatOwner.assistant(rig.assistantA));
            await settle(tester);

            if (wantsNewChat) {
              // The switch asks for a fresh chat, and a named owner never
              // inherits the group on screen: this is the F1 accident.
              expect(rig.chat.created, hasLength(1));
              expect(rig.chat.created.single.assistantId, rig.assistantA);
              expect(rig.chat.created.single.groupChatId, isNull);
              expect(rig.controller.currentConversation?.id, isNot(recent.id));
            } else {
              expect(rig.chat.created, isEmpty);
              expect(rig.controller.currentConversation?.id, recent.id);
            }
            expect(rig.controller.currentConversation?.groupChatId, isNull);
          });
        },
      );
    }

    testWidgets('a group topic + an assistant with no history', (tester) async {
      await runAsDesktop(() async {
        final rig = await pumpRig(tester);
        final group = await rig.groups.create(name: 'G', memberIds: const []);
        final topic = rig.chat.seed(
          title: 'topic',
          groupChatId: group.id,
          updatedAt: DateTime(2026, 1, 3),
        );
        await rig.startIn(topic);

        await rig.controller.openOwner(ChatOwner.assistant(rig.assistantA));
        await settle(tester);

        expect(rig.chat.created, hasLength(1));
        expect(rig.chat.created.single.assistantId, rig.assistantA);
        expect(rig.chat.created.single.groupChatId, isNull);
      });
    });

    testWidgets('a 1:1 + a group with topics opens its most recent topic', (
      tester,
    ) async {
      await runAsDesktop(() async {
        final rig = await pumpRig(tester);
        final group = await rig.groups.create(name: 'G', memberIds: const []);
        rig.chat.seed(
          title: 'older topic',
          groupChatId: group.id,
          updatedAt: DateTime(2026, 1, 1),
        );
        final newest = rig.chat.seed(
          title: 'newest topic',
          groupChatId: group.id,
          updatedAt: DateTime(2026, 1, 4),
        );
        final own = rig.chat.seed(
          title: 'A chat',
          assistantId: rig.assistantA,
          updatedAt: DateTime(2026, 1, 2),
        );
        await rig.startIn(own);
        await rig.settings.setNewChatOnAssistantSwitch(false);

        await rig.controller.openOwner(ChatOwner.group(group.id));
        await settle(tester);

        expect(rig.chat.created, isEmpty);
        expect(rig.controller.currentConversation?.id, newest.id);
        expect(rig.controller.currentConversation?.groupChatId, group.id);
      });
    });

    testWidgets('the switch gives a group a new topic too', (tester) async {
      await runAsDesktop(() async {
        final rig = await pumpRig(tester);
        await rig.settings.setNewChatOnAssistantSwitch(true);
        final group = await rig.groups.create(name: 'G', memberIds: const []);
        final recent = rig.chat.seed(
          title: 'recent topic',
          groupChatId: group.id,
          updatedAt: DateTime(2026, 1, 4),
        );
        final own = rig.chat.seed(
          title: 'A chat',
          assistantId: rig.assistantA,
          updatedAt: DateTime(2026, 1, 2),
        );
        await rig.startIn(own);

        await rig.controller.openOwner(ChatOwner.group(group.id));
        await settle(tester);

        // "New chat when switching" is about the tap on an owner, not about one
        // kind: a group's topic is a conversation too.
        expect(rig.chat.created, hasLength(1));
        expect(rig.chat.created.single.groupChatId, group.id);
        expect(rig.controller.currentConversation?.id, isNot(recent.id));
        expect(rig.controller.currentConversation?.groupChatId, group.id);
      });
    });

    testWidgets('a 1:1 + a group with no topics starts one of its own', (
      tester,
    ) async {
      await runAsDesktop(() async {
        final rig = await pumpRig(tester);
        final group = await rig.groups.create(name: 'G', memberIds: const []);
        final own = rig.chat.seed(
          title: 'A chat',
          assistantId: rig.assistantA,
          updatedAt: DateTime(2026, 1, 2),
        );
        await rig.startIn(own);

        await rig.controller.openOwner(ChatOwner.group(group.id));
        await settle(tester);

        expect(rig.chat.created, hasLength(1));
        expect(rig.chat.created.single.groupChatId, group.id);
        expect(rig.chat.created.single.assistantId, isNull);
        expect(rig.controller.currentConversation?.groupChatId, group.id);
      });
    });

    testWidgets('a dead group topic belongs to the default assistant', (
      tester,
    ) async {
      await runAsDesktop(() async {
        final rig = await pumpRig(tester);
        final orphan = rig.chat.seed(
          title: 'orphan topic',
          groupChatId: 'deleted-group',
          updatedAt: DateTime(2026, 1, 3),
        );
        await rig.startIn(orphan);

        // An unbound conversation follows the default assistant, so the orphan
        // is that assistant's most recent chat — opening it is the ordinary
        // conversation the topic became, not a stray.
        await rig.controller.openOwner(ChatOwner.assistant(rig.assistantA));
        await settle(tester);

        expect(rig.chat.created, isEmpty);
        expect(rig.controller.currentConversation?.id, orphan.id);
      });
    });

    testWidgets('a new chat from a dead group topic carries no group id', (
      tester,
    ) async {
      await runAsDesktop(() async {
        final rig = await pumpRig(tester);
        await rig.settings.setNewChatOnAssistantSwitch(true);
        final orphan = rig.chat.seed(
          title: 'orphan topic',
          groupChatId: 'deleted-group',
          updatedAt: DateTime(2026, 1, 3),
        );
        await rig.startIn(orphan);

        await rig.controller.openOwner(ChatOwner.assistant(rig.assistantB));
        await settle(tester);

        // A dead group id must not be carried into the new chat, or it would
        // silently rejoin the group if that came back.
        expect(rig.chat.created, hasLength(1));
        expect(rig.chat.created.single.groupChatId, isNull);
        expect(rig.chat.created.single.assistantId, rig.assistantB);
        expect(rig.controller.currentConversation?.groupChatId, isNull);
      });
    });

    testWidgets('opening a group leaves the default assistant alone', (
      tester,
    ) async {
      await runAsDesktop(() async {
        final rig = await pumpRig(tester);
        final group = await rig.groups.create(name: 'G', memberIds: const []);
        final topic = rig.chat.seed(
          title: 'topic',
          groupChatId: group.id,
          updatedAt: DateTime(2026, 1, 3),
        );
        final own = rig.chat.seed(
          title: 'A chat',
          assistantId: rig.assistantA,
          updatedAt: DateTime(2026, 1, 2),
        );
        await rig.startIn(own);
        expect(rig.assistants.currentAssistantId, rig.assistantA);

        await rig.controller.openOwner(ChatOwner.group(group.id));
        await settle(tester);

        // A group topic is nobody's fallback: it must not clear or rewrite the
        // assistant a *new* 1:1 would belong to.
        expect(rig.assistants.currentAssistantId, rig.assistantA);
        expect(rig.controller.currentConversation?.id, topic.id);
      });
    });

    testWidgets('opening a 1:1 makes that assistant the fallback', (
      tester,
    ) async {
      await runAsDesktop(() async {
        final rig = await pumpRig(tester);
        await rig.settings.setNewChatOnAssistantSwitch(false);
        final bChat = rig.chat.seed(
          title: 'B chat',
          assistantId: rig.assistantB,
          updatedAt: DateTime(2026, 1, 4),
        );
        final aChat = rig.chat.seed(
          title: 'A chat',
          assistantId: rig.assistantA,
          updatedAt: DateTime(2026, 1, 2),
        );
        await rig.startIn(aChat);
        expect(rig.assistants.currentAssistantId, rig.assistantA);

        await rig.controller.openOwner(ChatOwner.assistant(rig.assistantB));
        await settle(tester);

        expect(rig.controller.currentConversation?.id, bChat.id);
        expect(rig.assistants.currentAssistantId, rig.assistantB);
      });
    });

    testWidgets('a group that is gone opens nothing', (tester) async {
      await runAsDesktop(() async {
        final rig = await pumpRig(tester);
        final own = rig.chat.seed(
          title: 'A chat',
          assistantId: rig.assistantA,
          updatedAt: DateTime(2026, 1, 2),
        );
        await rig.startIn(own);

        await rig.controller.openOwner(const ChatOwner.group('deleted-group'));

        expect(rig.chat.created, isEmpty);
        expect(rig.controller.currentConversation?.id, own.id);
      });
    });

    for (final wantsNewChat in [true, false]) {
      testWidgets('1:1 to 1:1 (newChat=$wantsNewChat)', (tester) async {
        await runAsDesktop(() async {
          final rig = await pumpRig(tester);
          await rig.settings.setNewChatOnAssistantSwitch(wantsNewChat);
          final current = rig.chat.seed(
            title: 'A chat',
            assistantId: rig.assistantA,
            updatedAt: DateTime(2026, 1, 2),
          );
          final other = rig.chat.seed(
            title: 'B chat',
            assistantId: rig.assistantB,
            updatedAt: DateTime(2026, 1, 3),
          );
          await rig.startIn(current);

          await rig.controller.openOwner(ChatOwner.assistant(rig.assistantB));
          await settle(tester);

          // Switching to another assistant and to the one already open are the
          // same tap: with the switch on, both start a fresh chat.
          expect(rig.chat.created, hasLength(wantsNewChat ? 1 : 0));
          expect(
            rig.controller.currentConversation?.id,
            wantsNewChat ? isNot(anyOf(current.id, other.id)) : other.id,
          );
          expect(
            rig.controller.currentConversation?.assistantId,
            rig.assistantB,
          );
        });
      });
    }
  });

  group('openOwner reveals the list', () {
    late List<int> busEvents;
    StreamSubscription<int>? busSub;

    setUp(() {
      busEvents = <int>[];
      busSub = DesktopSidebarTabBus.instance.stream.listen(busEvents.add);
      final panel = DesktopSidePanelController.instance;
      panel.setContext(conversationId: 'seed', topicsOnRight: true);
    });

    tearDown(() async {
      await busSub?.cancel();
      busSub = null;
      final panel = DesktopSidePanelController.instance;
      if (panel.isOpen) panel.close();
      panel.setContext(conversationId: '', topicsOnRight: false);
    });

    testWidgets('topics on the left, setting on, sidebar open: switches tab', (
      tester,
    ) async {
      await runAsDesktop(() async {
        final rig = await pumpRig(tester);
        await rig.settings.setDesktopAutoSwitchTopics(true);
        rig.controller.revealTopics();
        // The tab bus is a broadcast stream: the event lands a microtask later.
        await tester.pump();
        expect(busEvents, [1]);
      });
    });

    testWidgets('topics on the left, setting on, sidebar closed: opens it', (
      tester,
    ) async {
      await runAsDesktop(() async {
        final rig = await pumpRig(tester);
        await rig.settings.setDesktopAutoSwitchTopics(true);
        rig.controller.toggleTabletSidebar();
        expect(rig.controller.tabletSidebarOpen, isFalse);

        rig.controller.revealTopics();
        await tester.pump();

        expect(rig.controller.tabletSidebarOpen, isTrue);
        expect(busEvents, [1]);
      });
    });

    testWidgets('topics on the left, setting off: nothing moves', (
      tester,
    ) async {
      await runAsDesktop(() async {
        final rig = await pumpRig(tester);
        await rig.settings.setDesktopAutoSwitchTopics(false);
        rig.controller.revealTopics();
        expect(busEvents, isEmpty);
      });
    });

    testWidgets('topics on the right, setting on: opens the panel on topics', (
      tester,
    ) async {
      await runAsDesktop(() async {
        final rig = await pumpRig(tester);
        await rig.settings.setDesktopAutoSwitchTopics(true);
        await rig.settings.setDesktopTopicPosition(DesktopTopicPosition.right);
        final panel = DesktopSidePanelController.instance;
        panel.setContext(conversationId: 'seed', topicsOnRight: true);

        rig.controller.revealTopics();

        expect(panel.isOpen, isTrue);
        expect(panel.activeTab.kind, SidePanelTabKind.topics);
        expect(busEvents, isEmpty);
      });
    });

    testWidgets('topics on the right, panel already open on files', (
      tester,
    ) async {
      await runAsDesktop(() async {
        final rig = await pumpRig(tester);
        await rig.settings.setDesktopAutoSwitchTopics(true);
        await rig.settings.setDesktopTopicPosition(DesktopTopicPosition.right);
        final panel = DesktopSidePanelController.instance;
        panel.setContext(conversationId: 'seed', topicsOnRight: true);
        panel.open(kind: SidePanelTabKind.files);
        expect(panel.activeTab.kind, SidePanelTabKind.files);

        rig.controller.revealTopics();

        expect(panel.isOpen, isTrue);
        expect(panel.activeTab.kind, SidePanelTabKind.topics);
      });
    });

    testWidgets('topics on the right, setting off: nothing moves', (
      tester,
    ) async {
      await runAsDesktop(() async {
        final rig = await pumpRig(tester);
        await rig.settings.setDesktopAutoSwitchTopics(false);
        await rig.settings.setDesktopTopicPosition(DesktopTopicPosition.right);
        final panel = DesktopSidePanelController.instance;

        rig.controller.revealTopics();

        expect(panel.isOpen, isFalse);
        expect(busEvents, isEmpty);
      });
    });

    testWidgets('a tap reveals the list on the next frame', (tester) async {
      await runAsDesktop(() async {
        final rig = await pumpRig(tester);
        await rig.settings.setDesktopAutoSwitchTopics(true);
        await rig.settings.setNewChatOnAssistantSwitch(false);
        final own = rig.chat.seed(
          title: 'A chat',
          assistantId: rig.assistantA,
          updatedAt: DateTime(2026, 1, 2),
        );
        final other = rig.chat.seed(
          title: 'B chat',
          assistantId: rig.assistantB,
          updatedAt: DateTime(2026, 1, 3),
        );
        await rig.startIn(own);

        await rig.controller.openOwner(ChatOwner.assistant(rig.assistantB));
        // The reveal runs after the frame that paints the new chat, so the list
        // is re-scoped before the tab flips.
        await tester.pump();
        await tester.pump();
        await settle(tester);

        expect(rig.controller.currentConversation?.id, other.id);
        expect(busEvents, [1]);
      });
    });

    testWidgets('a narrow desktop closes its sidebar overlay on a tap', (
      tester,
    ) async {
      await runAsDesktop(() async {
        final rig = await pumpRig(tester);
        await rig.settings.setNewChatOnAssistantSwitch(false);
        final own = rig.chat.seed(
          title: 'A chat',
          assistantId: rig.assistantA,
          updatedAt: DateTime(2026, 1, 2),
        );
        final other = rig.chat.seed(
          title: 'B chat',
          assistantId: rig.assistantB,
          updatedAt: DateTime(2026, 1, 3),
        );
        await rig.startIn(own);
        // A narrow window: the sidebar is a modal overlay over the chat, not a
        // route, so the drawer's PopScope dismissal cannot reach it.
        rig.controller.setCompactDesktopLayout(true);
        rig.controller.toggleTabletSidebar();
        expect(rig.controller.tabletSidebarOpen, isTrue);

        await rig.controller.openOwner(ChatOwner.assistant(rig.assistantB));
        await settle(tester);

        expect(rig.controller.currentConversation?.id, other.id);
        expect(rig.controller.tabletSidebarOpen, isFalse);
      });
    });

    testWidgets('a narrow desktop does not reopen the overlay to reveal', (
      tester,
    ) async {
      await runAsDesktop(() async {
        final rig = await pumpRig(tester);
        await rig.settings.setDesktopAutoSwitchTopics(true);
        await rig.settings.setNewChatOnAssistantSwitch(false);
        final own = rig.chat.seed(
          title: 'A chat',
          assistantId: rig.assistantA,
          updatedAt: DateTime(2026, 1, 2),
        );
        rig.chat.seed(
          title: 'B chat',
          assistantId: rig.assistantB,
          updatedAt: DateTime(2026, 1, 3),
        );
        await rig.startIn(own);
        rig.controller.setCompactDesktopLayout(true);
        rig.controller.toggleTabletSidebar();
        expect(rig.controller.tabletSidebarOpen, isTrue);

        await rig.controller.openOwner(ChatOwner.assistant(rig.assistantB));
        await tester.pump();
        await tester.pump();
        await settle(tester);

        // Revealing must not cover the chat that was just opened; the tab still
        // ends up on topics for the next time the overlay is opened.
        expect(rig.controller.tabletSidebarOpen, isFalse);
        expect(busEvents, [1]);
      });
    });

    testWidgets('a phone has no topics tab: nothing moves', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final rig = await pumpRig(tester);
        await rig.settings.setDesktopAutoSwitchTopics(true);

        rig.controller.revealTopics();

        expect(busEvents, isEmpty);
        expect(DesktopSidePanelController.instance.isOpen, isFalse);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}

class _Rig {
  _Rig({
    required this.chat,
    required this.assistants,
    required this.groups,
    required this.settings,
  });

  final _OwnerChatService chat;
  final AssistantProvider assistants;
  final GroupChatProvider groups;
  final SettingsProvider settings;
  late final HomePageController controller;

  String get assistantA => assistants.assistants[0].id;
  String get assistantB => assistants.assistants[1].id;

  /// Puts the controller on [conversation] without going through a tap.
  Future<void> startIn(Conversation conversation) async {
    chat.setCurrentConversation(conversation.id);
    await controller.chatController.setCurrentConversationAndLoad(conversation);
  }
}

class _Harness extends StatefulWidget {
  const _Harness({required this.onCreated});

  final ValueChanged<HomePageController> onCreated;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> with TickerProviderStateMixin {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _inputBarKey = GlobalKey();
  final _inputFocus = FocusNode();
  final _inputController = TextEditingController();
  final _mediaController = ChatInputBarController();
  final _scrollController = ChatAutoFollowScrollController();
  late final HomePageController _controller;

  @override
  void initState() {
    super.initState();
    _controller = HomePageController(
      context: context,
      vsync: this,
      scaffoldKey: _scaffoldKey,
      inputBarKey: _inputBarKey,
      inputFocus: _inputFocus,
      inputController: _inputController,
      mediaController: _mediaController,
      scrollController: _scrollController,
    );
    widget.onCreated(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    _inputFocus.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Scaffold(key: _scaffoldKey, body: const SizedBox.expand());
}

/// A chat store with no persistence: conversations in, drafts out, and every
/// draft it was asked for recorded so a test can ask *whose* chat was created.
class _OwnerChatService extends ChatService {
  _OwnerChatService();

  final List<Conversation> _conversations = <Conversation>[];
  final List<Conversation> created = <Conversation>[];
  String? _currentId;
  int _revision = 0;

  Conversation seed({
    required String title,
    String? groupChatId,
    String? assistantId,
    required DateTime updatedAt,
  }) {
    final conversation = Conversation(
      title: title,
      assistantId: assistantId,
      updatedAt: updatedAt,
      extras: {
        if (groupChatId != null) Conversation.groupChatIdKey: groupChatId,
      },
    );
    _conversations.add(conversation);
    _revision++;
    return conversation;
  }

  @override
  bool get initialized => true;

  @override
  int get conversationListRevision => _revision;

  @override
  ComposerDraftStore? get composerDrafts => null;

  @override
  String? get currentConversationId => _currentId;

  @override
  void setCurrentConversation(String? id) {
    _currentId = id;
  }

  @override
  List<Conversation> getAllConversations() => List<Conversation>.unmodifiable(
    [..._conversations]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
  );

  @override
  Conversation? getConversation(String id) =>
      [..._conversations, ...created].where((c) => c.id == id).firstOrNull;

  @override
  Conversation? getCompleteConversation(String id) => getConversation(id);

  @override
  Future<Conversation> createDraftConversation({
    String? title,
    String? assistantId,
    String? groupChatId,
    bool temporary = false,
    bool reuseNewEntry = false,
  }) async {
    final conversation = Conversation(
      title: title ?? 'Draft',
      assistantId: assistantId,
      extras: {
        if (groupChatId != null) Conversation.groupChatIdKey: groupChatId,
      },
    );
    created.add(conversation);
    _revision++;
    return conversation;
  }

  @override
  Future<LoadedTimelinePage?> loadTimelinePage(
    String conversationId, {
    String? beforeRevisionId,
    String? afterRevisionId,
    String? aroundRevisionId,
    bool fromStart = false,
    int limit = 40,
  }) async => LoadedTimelinePage(
    conversationId: conversationId,
    stateRevision: 0,
    contextStartRevisionId: null,
    slots: const <LoadedTimelineSlot>[],
    hasMoreBefore: false,
    hasMoreAfter: false,
    totalSlotCount: 0,
  );

  @override
  int getMessageCount(String conversationId) => 0;

  @override
  Map<String, int> getVersionSelections(String conversationId) =>
      const <String, int>{};

  @override
  List<ChatMessage> getMessagesForGroups(
    String conversationId,
    Iterable<String> groupIds,
  ) => const <ChatMessage>[];

  @override
  Future<List<ChatMessage>> loadMessagesForGroups(
    String conversationId,
    Iterable<String> groupIds,
  ) async => const <ChatMessage>[];

  @override
  Map<String, int> getFirstMessageIndicesForGroups(
    String conversationId,
    Iterable<String> groupIds,
  ) => const <String, int>{};

  @override
  Future<Map<String, int>> loadFirstMessageIndicesForGroups(
    String conversationId,
    Iterable<String> groupIds,
  ) async => const <String, int>{};

  @override
  Future<void> updateStreamingCheckpointSilent(
    ChatMessage message,
    List<Map<String, dynamic>> toolEvents, {
    String? generationRunId,
    int? checkpointSeq,
  }) async {}
}
