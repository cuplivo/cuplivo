import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';

import '../../../support/business_test_harness.dart';

import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/mcp_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/mcp/mcp_tool_service.dart';
import 'package:Cuplivo/features/home/controllers/home_page_controller.dart';
import 'package:Cuplivo/features/home/controllers/scroll_controller.dart';
import 'package:Cuplivo/features/home/widgets/chat_input_bar.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

import '../../../support/temp_directory_cleanup.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory directory;
  late PathProviderPlatform previousPathProvider;
  late ChatDatabaseRepository repository;
  late ChatService chatService;
  late HttpServer server;
  late SettingsProvider settings;
  late AssistantProvider assistantProvider;
  var generateTextRequestCount = 0;

  /// When set, the fake server counts the request and parks its response, so a
  /// test can act while a suggestion request is genuinely in flight. A gate is
  /// completed per phase; a completed gate no longer blocks.
  Completer<void>? responseGate;

  Future<void> handleApiRequest(HttpRequest request) async {
    final body =
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
    if (body['stream'] != true) {
      generateTextRequestCount++;
    }
    final gate = responseGate;
    if (gate != null) {
      await gate.future;
    }
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'choices': [
          {
            'message': {
              'content': jsonEncode({
                'suggestions': ['Yes', 'Tell me more'],
              }),
            },
          },
        ],
      }),
    );
    await request.response.close();
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('kelivo_suggestions_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(directory.path);
    HttpOverrides.global = null;
    repository = ChatDatabaseRepository.open(
      file: File('${directory.path}/kelivo.db'),
    );
    await repository.ensureReady();
    chatService = ChatService(existingRepository: repository);
    await chatService.init();
    generateTextRequestCount = 0;
    responseGate = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(handleApiRequest);
  });

  tearDown(() async {
    PathProviderPlatform.instance = previousPathProvider;
    try {
      await server.close(force: true);
    } catch (_) {}
    try {
      await chatService.close().timeout(const Duration(seconds: 10));
    } catch (_) {}
    try {
      await repository.close().timeout(const Duration(seconds: 10));
    } catch (_) {}
    await deleteDirectoryWhenReleased(directory, keepLockedLeftovers: true);
  });

  Future<HomePageController> pumpHarness(WidgetTester tester) async {
    HomePageController? controller;
    final baseUrl = 'http://${server.address.address}:${server.port}/v1';
    await tester.runAsync(() async {
      final settingsPrefs = createBusinessTestPreferences();
      await settingsPrefs.load();
      settings = SettingsProvider(settingsPrefs);
      await settings.loaded;
      await settings.setProviderConfig(
        'SiliconFlow',
        ProviderConfig(
          id: 'SiliconFlow',
          enabled: true,
          name: 'SiliconFlow',
          apiKey: 'suggestion-test-key',
          baseUrl: baseUrl,
          providerType: ProviderKind.openai,
        ),
      );
      await settings.setCurrentModel('SiliconFlow', 'test-model');

      final assistantPrefs = createBusinessTestPreferences();
      await assistantPrefs.load();
      assistantProvider = AssistantProvider(preferences: assistantPrefs);
      await assistantProvider.loaded;
      final assistantId = await assistantProvider.addAssistant(
        name: 'Suggestion Assistant',
      );
      await assistantProvider.setCurrentAssistant(assistantId);
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<ChatService>.value(value: chatService),
          ChangeNotifierProvider<AssistantProvider>.value(
            value: assistantProvider,
          ),
          ChangeNotifierProvider<McpProvider>(
            create: (_) =>
                McpProvider(preferences: createBusinessTestPreferences()),
          ),
          ChangeNotifierProvider<McpToolService>(
            create: (_) => McpToolService(),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: _ControllerHarness(onCreated: (value) => controller = value),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    return controller!;
  }

  Future<void> setAssistantSuggestionsEnabled(
    bool enabled, {
    String? assistantId,
  }) async {
    final assistant = assistantId == null
        ? assistantProvider.currentAssistant!
        : assistantProvider.getById(assistantId)!;
    await assistantProvider.updateAssistant(
      assistant.copyWith(suggestionsEnabled: enabled),
    );
  }

  /// Waits until the server has counted [target] non-streaming requests, i.e.
  /// the parked response for the latest one is already waiting on its gate.
  Future<void> waitForSuggestionRequests(int target) async {
    for (var i = 0; i < 400 && generateTextRequestCount < target; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      generateTextRequestCount,
      target,
      reason: 'the suggestion request never reached the server',
    );
  }

  Future<String> seedSettledReply() async {
    final convo = await chatService.createConversation(
      title: 'Suggestion Chat',
      assistantId: assistantProvider.currentAssistantId,
    );
    await chatService.addMessage(
      conversationId: convo.id,
      role: 'user',
      content: 'Help me pick a metronome app.',
    );
    await chatService.addMessage(
      conversationId: convo.id,
      role: 'assistant',
      content: 'What platform are you on?',
    );
    return convo.id;
  }

  testWidgets(
    'an enabled assistant spends one request and stores suggestions',
    (tester) async {
      final controller = await pumpHarness(tester);
      await tester.runAsync(() async {
        await settings.resetSuggestionModel();
        await setAssistantSuggestionsEnabled(true);
        final conversationId = await seedSettledReply();

        await controller.debugViewModel.debugMaybeGenerateSuggestionsFor(
          conversationId,
        );

        expect(generateTextRequestCount, 1);
        expect(chatService.getConversation(conversationId)!.chatSuggestions, [
          'Yes',
          'Tell me more',
        ]);
      });
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an assistant that opts out spends no request', (tester) async {
    final controller = await pumpHarness(tester);
    await tester.runAsync(() async {
      await settings.resetSuggestionModel();
      await setAssistantSuggestionsEnabled(false);
      final conversationId = await seedSettledReply();

      await controller.debugViewModel.debugMaybeGenerateSuggestionsFor(
        conversationId,
      );

      expect(
        generateTextRequestCount,
        0,
        reason: 'a per-assistant opt-out must not pay for a suggestion call',
      );
      expect(
        chatService.getConversation(conversationId)!.chatSuggestions,
        isEmpty,
      );
    });
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('the global switch still wins over an enabled assistant', (
    tester,
  ) async {
    final controller = await pumpHarness(tester);
    await tester.runAsync(() async {
      await settings.disableSuggestionGeneration();
      await setAssistantSuggestionsEnabled(true);
      final conversationId = await seedSettledReply();

      await controller.debugViewModel.debugMaybeGenerateSuggestionsFor(
        conversationId,
      );

      expect(generateTextRequestCount, 0);
      expect(
        chatService.getConversation(conversationId)!.chatSuggestions,
        isEmpty,
      );
    });
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('stored suggestions follow the owning assistant', (tester) async {
    final controller = await pumpHarness(tester);
    await tester.runAsync(() async {
      await settings.resetSuggestionModel();
      await setAssistantSuggestionsEnabled(true);
      final conversationId = await seedSettledReply();
      await chatService.updateConversationSuggestions(conversationId, const [
        'Yes',
        'Tell me more',
      ]);
      await controller.debugViewModel.switchConversation(conversationId);

      expect(controller.debugViewModel.visibleChatSuggestions, const [
        'Yes',
        'Tell me more',
      ]);

      await setAssistantSuggestionsEnabled(false);
      expect(
        controller.debugViewModel.visibleChatSuggestions,
        isEmpty,
        reason:
            'an opted-out assistant must not show chips it would not pay for',
      );

      await setAssistantSuggestionsEnabled(true);
      expect(controller.debugViewModel.visibleChatSuggestions, const [
        'Yes',
        'Tell me more',
      ]);
    });
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('the global switch hides stored suggestions', (tester) async {
    final controller = await pumpHarness(tester);
    await tester.runAsync(() async {
      await settings.resetSuggestionModel();
      await setAssistantSuggestionsEnabled(true);
      final conversationId = await seedSettledReply();
      await chatService.updateConversationSuggestions(conversationId, const [
        'Yes',
      ]);
      await controller.debugViewModel.switchConversation(conversationId);
      expect(controller.debugViewModel.visibleChatSuggestions, const ['Yes']);

      await settings.disableSuggestionGeneration();
      expect(
        controller.debugViewModel.visibleChatSuggestions,
        isEmpty,
        reason: 'the global switch stays the master over a stored list',
      );
    });
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('the conversation owner decides, not the selected assistant', (
    tester,
  ) async {
    final controller = await pumpHarness(tester);
    await tester.runAsync(() async {
      await settings.resetSuggestionModel();
      final workAssistantId = await assistantProvider.addAssistant(
        name: 'Work Assistant',
      );
      await setAssistantSuggestionsEnabled(false, assistantId: workAssistantId);

      final convo = await chatService.createConversation(
        title: 'Work Chat',
        assistantId: workAssistantId,
      );
      await chatService.updateConversationSuggestions(convo.id, const [
        'Ship it',
      ]);
      // Switching selects the owner, so the selection is then moved away from
      // the conversation's owner by hand: this is the cell a selection-based
      // gate gets wrong.
      await controller.debugViewModel.switchConversation(convo.id);
      final personalAssistantId = assistantProvider.assistants
          .firstWhere((a) => a.id != workAssistantId)
          .id;
      await assistantProvider.setCurrentAssistant(personalAssistantId);

      expect(assistantProvider.currentAssistant!.suggestionsEnabled, isTrue);
      expect(
        controller.debugViewModel.currentConversation!.assistantId,
        workAssistantId,
      );
      expect(
        controller.debugViewModel.visibleChatSuggestions,
        isEmpty,
        reason: 'the chips belong to the conversation, not to the selection',
      );

      await setAssistantSuggestionsEnabled(true, assistantId: workAssistantId);
      expect(controller.debugViewModel.visibleChatSuggestions, const [
        'Ship it',
      ]);
    });
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('an opt-out while the request is in flight discards the reply', (
    tester,
  ) async {
    final controller = await pumpHarness(tester);
    await tester.runAsync(() async {
      await settings.resetSuggestionModel();
      await setAssistantSuggestionsEnabled(true);
      final viewModel = controller.debugViewModel;

      // Control: with the same parked-response harness and no opt-out the
      // reply is stored, so the discard below is the opt-out's doing.
      final controlConversationId = await seedSettledReply();
      var gate = Completer<void>();
      responseGate = gate;
      final controlRun = viewModel.debugMaybeGenerateSuggestionsFor(
        controlConversationId,
      );
      await waitForSuggestionRequests(1);
      gate.complete();
      await controlRun;
      expect(
        chatService.getConversation(controlConversationId)!.chatSuggestions,
        const ['Yes', 'Tell me more'],
      );

      final optedOutConversationId = await seedSettledReply();
      gate = Completer<void>();
      responseGate = gate;
      final droppedRun = viewModel.debugMaybeGenerateSuggestionsFor(
        optedOutConversationId,
      );
      await waitForSuggestionRequests(2);
      // The reply is already on its way; the assistant opts out while it is.
      await setAssistantSuggestionsEnabled(false);
      gate.complete();
      await droppedRun;

      expect(
        chatService.getConversation(optedOutConversationId)!.chatSuggestions,
        isEmpty,
        reason: 'a reply must not land after an opt-out that beat it',
      );
    });
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}

class _ControllerHarness extends StatefulWidget {
  const _ControllerHarness({required this.onCreated});

  final ValueChanged<HomePageController> onCreated;

  @override
  State<_ControllerHarness> createState() => _ControllerHarnessState();
}

class _ControllerHarnessState extends State<_ControllerHarness>
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
