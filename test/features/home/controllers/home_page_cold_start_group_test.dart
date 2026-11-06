import 'dart:async';
import 'dart:io';

import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/home/controllers/home_page_controller.dart';
import 'package:Cuplivo/features/home/controllers/scroll_controller.dart';
import 'package:Cuplivo/features/home/widgets/chat_input_bar.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';

import '../../../support/business_test_harness.dart';

/// The group list held open until the test says so, so the window between "the
/// chat restored" and "the groups arrived" can be inspected instead of raced.
class _GatedStore extends ExtensionEntityStore {
  _GatedStore(super.database);

  final Completer<void> _gate = Completer<void>();

  bool get released => _gate.isCompleted;

  void release() => _gate.complete();

  @override
  Future<List<ExtensionEntity>> listByKind(String kind) async {
    await _gate.future;
    return super.listByKind(kind);
  }
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';
  @override
  Future<String?> getTemporaryPath() async => '$root/tmp';
}

class _ColdStartHarness extends StatefulWidget {
  const _ColdStartHarness({required this.onCreated});

  final ValueChanged<HomePageController> onCreated;

  @override
  State<_ColdStartHarness> createState() => _ColdStartHarnessState();
}

class _ColdStartHarnessState extends State<_ColdStartHarness>
    with TickerProviderStateMixin {
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
  Widget build(BuildContext context) => Scaffold(key: _scaffoldKey);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a cold start opens a group topic only once its groups have '
      'loaded', (tester) async {
    // The mobile layout is where the gradient/wallpaper sits behind the chat;
    // the platform only decides which startup path runs initChat.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final oldPaths = PathProviderPlatform.instance;
    try {
      late BusinessTestHarness harness;
      late Directory root;
      late ChatService chat;
      late SettingsProvider settings;
      late AssistantProvider assistants;
      late GroupChatProvider seeding;
      late _GatedStore store;
      late GroupChatProvider groups;
      late String groupId;
      late String topicId;

      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('cold-start-group-');
        PathProviderPlatform.instance = _Paths(root.path);
        harness = await BusinessTestHarness.create();
        settings = SettingsProvider(harness.preferences);
        assistants = AssistantProvider(preferences: harness.preferences);
        await Future.wait([settings.loaded, assistants.loaded]);
        await settings.setNewChatOnLaunch(false);
        chat = ChatService(
          existingRepository: ChatDatabaseRepository(harness.database),
        );
        seeding = GroupChatProvider(
          store: ExtensionEntityStore(harness.database),
        );
        await seeding.loaded;
        final group = await seeding.create(
          name: 'Reading',
          memberIds: const ['assistant-a'],
        );
        groupId = group.id;
        final topic = await chat.createConversation(
          title: 'Group topic',
          groupChatId: group.id,
          activate: false,
        );
        topicId = topic.id;
        // Everything above is on disk; the provider this test mounts is the
        // same table, read through a gate that stays shut.
        store = _GatedStore(harness.database);
        groups = GroupChatProvider(store: store);
      });

      HomePageController? controller;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsProvider>.value(value: settings),
            ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
            ChangeNotifierProvider<ChatService>.value(value: chat),
            ChangeNotifierProvider<GroupChatProvider>.value(value: groups),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: _ColdStartHarness(onCreated: (value) => controller = value),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final page = controller!;

      final startup = page.initChat();
      var startupDone = false;
      startup.then(
        (_) => startupDone = true,
        onError: (_) => startupDone = true,
      );

      // A real turn of the event loop plus a frame: the startup work spans real
      // SQLite I/O, so neither alone lets initChat make progress.
      Future<void> turn() async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }

      // Let the chat store really initialize. `getConversation` answers null
      // until it has, so this is also the witness that initChat got that far.
      for (var i = 0; i < 100 && chat.getConversation(topicId) == null; i++) {
        await turn();
      }
      expect(
        chat.getConversation(topicId),
        isNotNull,
        reason: 'the chat service never finished initializing',
      );

      // Give the startup continuation the turns it would need, without
      // releasing the group list.
      for (var i = 0; i < 40; i++) {
        await turn();
      }
      expect(store.released, isFalse);
      expect(groups.byId(groupId), isNull);

      // The topic must not become current while the app cannot yet tell it is a
      // group topic. `ChatService.currentConversationId` is what the chat's
      // backdrop resolves the open conversation from, so setting it here is the
      // frame that paints the selected assistant's wallpaper and gradient over
      // a group topic, one frame before the group list takes them away.
      expect(
        chat.currentConversationId,
        isNull,
        reason: 'the chat opened a topic before its group was known',
      );
      expect(
        page.currentConversation,
        isNull,
        reason: 'the chat opened a topic before its group was known',
      );
      expect(startupDone, isFalse);

      store.release();
      for (var i = 0; i < 100 && !startupDone; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(startupDone, isTrue, reason: 'initChat never finished');
      expect(groups.byId(groupId), isNotNull);
      expect(chat.currentConversationId, topicId);
      expect(page.currentConversation?.id, topicId);
      expect(page.currentConversation?.groupChatId, groupId);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await chat.close();
        settings.dispose();
        assistants.dispose();
        await harness.close();
        await root.delete(recursive: true);
      });
      PathProviderPlatform.instance = oldPaths;
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      PathProviderPlatform.instance = oldPaths;
    }
  });
}
