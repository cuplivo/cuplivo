import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_context_message.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/home/services/message_builder_service.dart';
import 'package:Cuplivo/features/home/services/message_generation_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'ordinary and policy-aware histories use the same complete preparation pipeline',
    (tester) async {
      late BuildContext buildContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              buildContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final settings = SettingsProvider();
      final assistant = Assistant(id: 'assistant-1', name: 'Alice');
      final message = ChatMessage(
        id: 'message-1',
        role: 'user',
        content: 'hello',
        conversationId: 'conversation-1',
      );

      Future<_PreparationRun> run({required bool policyAware}) async {
        final builder = _RecordingMessageBuilder(buildContext);
        final preparation = ChatGenerationPreparationService(
          messageBuilderService: builder,
          buildToolDefinitions:
              (
                actualSettings,
                actualAssistant,
                providerKey,
                modelId,
                hasBuiltInSearch,
              ) {
                builder.calls.add('tools');
                expect(actualSettings, same(settings));
                expect(actualAssistant, same(assistant));
                expect(providerKey, 'openai');
                expect(modelId, 'model-1');
                expect(hasBuiltInSearch, isTrue);
                return const <Map<String, dynamic>>[
                  <String, dynamic>{'type': 'function'},
                ];
              },
          buildToolCallHandler:
              (
                actualSettings,
                actualAssistant, {
                approvalService,
                askUserService,
              }) {
                builder.calls.add('handler');
                return (
                  String name,
                  Map<String, dynamic> arguments, {
                  String? toolCallId,
                }) async => 'ok';
              },
        );
        final result = await preparation.prepare(
          messages: <ChatMessage>[message],
          contextMessages: policyAware
              ? <ChatContextMessage>[ChatContextMessage.full(message)]
              : null,
          versionSelections: const <String, int>{},
          currentConversation: Conversation(
            id: 'conversation-1',
            title: 'Conversation',
          ),
          settings: settings,
          assistant: assistant,
          assistantId: assistant.id,
          providerKey: 'openai',
          modelId: 'model-1',
        );
        return _PreparationRun(builder.calls, result);
      }

      final ordinary = await run(policyAware: false);
      final policyAware = await run(policyAware: true);

      expect(ordinary.calls, <String>[
        'buildOrdinary',
        'processMedia',
        'system',
        'memoryAndRecent',
        'hasBuiltInSearch',
        'search',
        'instructions',
        'worldBook',
        'skills',
        'time',
        'contextLimit',
        'inlineImages',
        'tools',
        'handler',
      ]);
      expect(policyAware.calls, <String>[
        'buildPolicyAware',
        ...ordinary.calls.skip(1),
      ]);
      expect(ordinary.result.apiMessages, policyAware.result.apiMessages);
      expect(ordinary.result.toolDefs, policyAware.result.toolDefs);
      expect(ordinary.result.lastUserImagePaths, <String>['media.png']);
      expect(policyAware.result.onToolCall, isNotNull);
    },
  );
}

class _PreparationRun {
  const _PreparationRun(this.calls, this.result);

  final List<String> calls;
  final PreparedGeneration result;
}

class _RecordingMessageBuilder extends MessageBuilderService {
  _RecordingMessageBuilder(BuildContext context)
    : super(chatService: ChatService(), contextProvider: context);

  final List<String> calls = <String>[];

  List<Map<String, dynamic>> _messages() => <Map<String, dynamic>>[
    <String, dynamic>{'role': 'user', 'content': 'hello'},
  ];

  @override
  List<Map<String, dynamic>> buildApiMessages({
    required List<ChatMessage> messages,
    required Map<String, int> versionSelections,
    required Conversation? currentConversation,
    bool includeToolMessages = false,
  }) {
    calls.add('buildOrdinary');
    return _messages();
  }

  @override
  List<Map<String, dynamic>> buildApiMessagesFromContext({
    required List<ChatContextMessage> contextMessages,
    required Map<String, int> versionSelections,
    required Conversation? currentConversation,
    bool includeToolMessages = false,
  }) {
    calls.add('buildPolicyAware');
    return _messages();
  }

  @override
  Future<List<String>> processUserMessagesForApi(
    List<Map<String, dynamic>> apiMessages,
    SettingsProvider settings,
    Assistant? assistant,
  ) async {
    calls.add('processMedia');
    return <String>['media.png'];
  }

  @override
  void injectSystemPrompt(
    List<Map<String, dynamic>> apiMessages,
    Assistant? assistant,
    String modelId,
  ) {
    calls.add('system');
  }

  @override
  Future<void> injectMemoryAndRecentChats(
    List<Map<String, dynamic>> apiMessages,
    Assistant? assistant, {
    String? currentConversationId,
  }) async {
    calls.add('memoryAndRecent');
  }

  @override
  bool hasBuiltInSearch(
    SettingsProvider settings,
    String providerKey,
    String modelId,
  ) {
    calls.add('hasBuiltInSearch');
    return true;
  }

  @override
  void injectSearchPrompt(
    List<Map<String, dynamic>> apiMessages,
    SettingsProvider settings,
    Assistant? assistant,
    bool hasBuiltInSearch,
  ) {
    calls.add('search');
  }

  @override
  Future<void> injectInstructionPrompts(
    List<Map<String, dynamic>> apiMessages,
    String? assistantId,
  ) async {
    calls.add('instructions');
  }

  @override
  Future<void> injectWorldBookPrompts(
    List<Map<String, dynamic>> apiMessages,
    String? assistantId,
  ) async {
    calls.add('worldBook');
  }

  @override
  Future<void> injectSkillListPrompt(
    List<Map<String, dynamic>> apiMessages,
    String? assistantId,
  ) async {
    calls.add('skills');
  }

  @override
  void injectTimeNote(
    List<Map<String, dynamic>> apiMessages,
    Assistant? assistant,
  ) {
    calls.add('time');
  }

  @override
  void applyContextLimit(
    List<Map<String, dynamic>> apiMessages,
    Assistant? assistant,
  ) {
    calls.add('contextLimit');
  }

  @override
  Future<void> inlineLocalImages(List<Map<String, dynamic>> apiMessages) async {
    calls.add('inlineImages');
  }
}
