import 'dart:convert';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/home/controllers/chat_controller.dart';
import 'package:Cuplivo/features/home/controllers/generation_controller.dart';
import 'package:Cuplivo/features/home/controllers/home_view_model.dart';
import 'package:Cuplivo/features/home/controllers/stream_controller.dart';
import 'package:Cuplivo/features/home/services/message_builder_service.dart';
import 'package:Cuplivo/features/home/services/message_generation_service.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../support/business_test_harness.dart';

/// The resume re-arm only reads the conversation snapshot, so the service does
/// not need to be initialized to reach it.
class _SnapshotChatService extends ChatService {
  _SnapshotChatService(this.conversations);

  final List<Conversation> conversations;

  @override
  List<Conversation> getAllConversations() => conversations;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const alarmChannel = MethodChannel('app.proactive_care_alarms');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(alarmChannel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(alarmChannel, null);
  });

  Future<HomeViewModel> pumpViewModel(
    WidgetTester tester, {
    required List<Assistant> assistants,
    required List<Conversation> conversations,
  }) async {
    final preferences = createBusinessTestPreferences();
    if (assistants.isNotEmpty) {
      await preferences.setString(
        'assistants_v1',
        jsonEncode([for (final assistant in assistants) assistant.toJson()]),
      );
    }
    final assistantProvider = AssistantProvider(preferences: preferences);
    await assistantProvider.loaded;
    final settings = SettingsProvider(preferences);
    addTearDown(settings.dispose);
    final service = _SnapshotChatService(conversations);
    late HomeViewModel viewModel;
    late StreamController streamController;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AssistantProvider>.value(
            value: assistantProvider,
          ),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              final chatController = ChatController(chatService: service);
              streamController = StreamController(
                onStateChanged: () {},
                getSettingsProvider: () => settings,
                getCurrentConversationId: () => null,
              );
              final messageBuilder = MessageBuilderService(
                chatService: service,
                contextProvider: context,
              );
              final generationController = GenerationController(
                chatService: service,
                chatController: chatController,
                streamController: streamController,
                messageBuilderService: messageBuilder,
                contextProvider: context,
                onStateChanged: () {},
                getTitleForLocale: (_) => 'title',
              );
              final messageGeneration = MessageGenerationService(
                chatService: service,
                messageBuilderService: messageBuilder,
                generationController: generationController,
                streamController: streamController,
                contextProvider: context,
              );
              viewModel = HomeViewModel(
                chatService: service,
                messageBuilderService: messageBuilder,
                messageGenerationService: messageGeneration,
                generationController: generationController,
                streamController: streamController,
                chatController: chatController,
                contextProvider: context,
                getTitleForLocale: (_) => 'title',
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    addTearDown(streamController.dispose);
    return viewModel;
  }

  List<Object?> rearmPayload() =>
      (calls.singleWhere((call) => call.method == 'rescheduleAll').arguments
              as Map)['alarms']
          as List;

  testWidgets('the resume re-arm arms the healthy letters and drops a gone '
      'owner', (tester) async {
    // Widget tests check this foundation variable at the end of the body, so it
    // is reset here rather than in tearDown.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final dueAt = DateTime.now().add(const Duration(hours: 2));
      final viewModel = await pumpViewModel(
        tester,
        assistants: [Assistant(id: 'a1', name: 'A', enableProactiveCare: true)],
        conversations: [
          Conversation(
            id: 'c1',
            title: 'T',
            assistantId: 'a1',
          ).setProactiveCareNextMessageAt(dueAt),
          Conversation(
            id: 'dangling',
            title: 'T',
            assistantId: 'deleted',
          ).setProactiveCareNextMessageAt(dueAt),
        ],
      );

      await viewModel.reschedulePendingProactiveCare();

      expect(rearmPayload(), [
        {'conversationId': 'c1', 'dueAt': dueAt.millisecondsSinceEpoch},
      ]);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a loaded, empty assistant store is not skipped', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final dueAt = DateTime.now().add(const Duration(hours: 2));
      final viewModel = await pumpViewModel(
        tester,
        assistants: const [],
        conversations: [
          Conversation(
            id: 'c1',
            title: 'T',
            assistantId: 'a1',
          ).setProactiveCareNextMessageAt(dueAt),
        ],
      );

      await viewModel.reschedulePendingProactiveCare();

      // No owner can be armed, so the replace-all sends nothing and clears the
      // registry; the removed `assistants.isEmpty` early return is what this
      // pins.
      expect(rearmPayload(), isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
