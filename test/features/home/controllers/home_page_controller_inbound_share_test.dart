import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:Cuplivo/core/providers/mcp_provider.dart';
import 'package:Cuplivo/core/providers/quick_instruction_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/generation_engine.dart';
import 'package:Cuplivo/features/home/controllers/home_page_controller.dart';
import 'package:Cuplivo/features/home/widgets/chat_input_bar.dart';
import 'package:Cuplivo/features/home/widgets/quick_instruction_editing_controller.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => '$path/cache';

  @override
  Future<String?> getTemporaryPath() async => '$path/tmp';
}

class _ControllerHost extends StatefulWidget {
  const _ControllerHost({required this.onReady});

  final ValueChanged<HomePageController> onReady;

  @override
  State<_ControllerHost> createState() => _ControllerHostState();
}

class _ControllerHostState extends State<_ControllerHost>
    with SingleTickerProviderStateMixin {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey _inputBarKey = GlobalKey();
  final FocusNode _inputFocus = FocusNode();
  final QuickInstructionEditingController _inputController =
      QuickInstructionEditingController();
  final ChatInputBarController _mediaController = ChatInputBarController();
  final ScrollController _scrollController = ScrollController();
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
    widget.onReady(_controller);
  }

  @override
  Widget build(BuildContext context) => Scaffold(key: _scaffoldKey);

  @override
  void dispose() {
    _controller.dispose();
    _inputFocus.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

class _Harness {
  _Harness({
    required this.controller,
    required this.chatService,
    required this.settings,
    required this.assistants,
    required this.quickInstructions,
    required this.mcp,
    required this.engine,
    required this.groupChats,
    required this.tempDir,
  });

  final HomePageController controller;
  final ChatService chatService;
  final SettingsProvider settings;
  final AssistantProvider assistants;
  final QuickInstructionProvider quickInstructions;
  final McpProvider mcp;
  final GenerationEngine engine;
  final GroupChatProvider groupChats;
  final Directory tempDir;

  Future<void> dispose(WidgetTester tester) async {
    await tester.runAsync(() async {
      await chatService.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpWidget(const SizedBox.shrink());
    engine.dispose();
    mcp.dispose();
    quickInstructions.dispose();
    assistants.dispose();
    settings.dispose();
    groupChats.dispose();
  }
}

Future<_Harness> _pumpHarness(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues(const <String, Object>{});
  final preferences = BusinessPreferences.memoryForTests();

  late final Directory tempDir;
  late final ChatService chatService;
  late final SettingsProvider settings;
  late final QuickInstructionProvider quickInstructions;
  late final GroupChatProvider groupChats;
  await tester.runAsync(() async {
    tempDir = await Directory.systemTemp.createTemp('inbound_share_ctrl_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    chatService = ChatService();
    await chatService.init();
    settings = SettingsProvider(preferences: preferences);
    await settings.loaded;
    quickInstructions = QuickInstructionProvider(preferences: preferences);
    await quickInstructions.initialize();
    groupChats = GroupChatProvider(chatService: chatService);
    await groupChats.load();
  });

  final assistants = AssistantProvider(
    preferences: preferences,
    chatService: chatService,
  );

  late BuildContext providerContext;
  final mcp = McpProvider(
    preferences: preferences,
    contextProvider: () => providerContext,
  );
  final engine = GenerationEngine(chatService: chatService);

  HomePageController? controller;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MultiProvider(
        providers: [
          Provider<BusinessPreferences>.value(value: preferences),
          ChangeNotifierProvider<ChatService>.value(value: chatService),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
          ChangeNotifierProvider<QuickInstructionProvider>.value(
            value: quickInstructions,
          ),
          ChangeNotifierProvider<McpProvider>.value(value: mcp),
          ChangeNotifierProvider<GenerationEngine>.value(value: engine),
          ChangeNotifierProvider<GroupChatProvider>.value(value: groupChats),
        ],
        child: Builder(
          builder: (context) {
            providerContext = context;
            return _ControllerHost(onReady: (value) => controller = value);
          },
        ),
      ),
    ),
  );
  await tester.pump();
  return _Harness(
    controller: controller!,
    chatService: chatService,
    settings: settings,
    assistants: assistants,
    quickInstructions: quickInstructions,
    mcp: mcp,
    engine: engine,
    groupChats: groupChats,
    tempDir: tempDir,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The desktop target skips the conversation-fade animation, which would
  // otherwise block on unpumped frames inside `tester.runAsync`. The landing
  // rules and draft merge under test are platform-independent. Resets in
  // `finally`: the binding's invariant check runs before `addTearDown`.
  Future<void> withDesktopTarget(Future<void> Function() body) async {
    final original = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = original;
    }
  }

  testWidgets('typed draft in a temporary chat survives an inbound share', (
    tester,
  ) async {
    await withDesktopTarget(() async {
      final harness = await _pumpHarness(tester);
      addTearDown(() => harness.dispose(tester));

      final convo = await tester.runAsync(
        () => harness.chatService.createDraftConversation(temporary: true),
      );
      harness.controller.chatController.setCurrentConversation(convo);
      harness.controller.inputController.setBodyValue(
        const TextEditingValue(text: 'typed draft'),
      );
      expect(
        harness.chatService.isTemporaryConversation(
          harness.controller.currentConversation?.id,
        ),
        isTrue,
      );

      await tester.runAsync(
        () => harness.controller.handleInboundShare(
          const ChatInputData(text: 'shared text'),
        ),
      );

      expect(
        harness.controller.inputController.bodyText,
        contains('typed draft'),
        reason: 'unsent composer content must never be discarded',
      );
      expect(
        harness.controller.inputController.bodyText,
        contains('shared text'),
      );
      expect(
        harness.chatService.isTemporaryConversation(
          harness.controller.currentConversation?.id,
        ),
        isFalse,
        reason: 'a temporary chat must be left for a normal conversation',
      );
    });
  });

  testWidgets('inbound share fills an empty temporary chat via a new chat', (
    tester,
  ) async {
    await withDesktopTarget(() async {
      final harness = await _pumpHarness(tester);
      addTearDown(() => harness.dispose(tester));

      final convo = await tester.runAsync(
        () => harness.chatService.createDraftConversation(temporary: true),
      );
      harness.controller.chatController.setCurrentConversation(convo);

      await tester.runAsync(
        () => harness.controller.handleInboundShare(
          const ChatInputData(text: 'shared text'),
        ),
      );

      expect(harness.controller.inputController.bodyText, 'shared text');
      expect(
        harness.chatService.isTemporaryConversation(
          harness.controller.currentConversation?.id,
        ),
        isFalse,
      );
    });
  });
}
