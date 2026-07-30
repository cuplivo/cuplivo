import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/group_chat_message.dart';
import 'package:Cuplivo/core/models/token_usage.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/chat/group_chat_service.dart';
import 'package:Cuplivo/core/services/group_chat/group_chat_orchestrator.dart';
import 'package:Cuplivo/features/group_chat/services/group_member_stream_service.dart';

void main() {
  group('GroupMemberStreamService', () {
    late _MemoryGroupChatService groupService;
    late _StreamSettings settings;
    late GroupMemberStreamService service;
    late Assistant assistant;
    late GroupChatMessage placeholder;

    setUp(() {
      groupService = _MemoryGroupChatService();
      settings = _StreamSettings();
      service = GroupMemberStreamService(
        chatService: ChatService(),
        groupChatService: groupService,
        getSettings: () => settings,
      );
      assistant = Assistant(
        id: 'a1',
        name: 'Alice',
        chatModelProvider: 'P',
        chatModelId: 'reasoning-model',
      );
      placeholder = GroupChatMessage(
        id: 'member-message',
        groupId: 'g1',
        role: 'assistant',
        speakerAssistantId: assistant.id,
        content: '',
        isStreaming: true,
      );
      groupService.messages[placeholder.id] = placeholder;
    });

    tearDown(() => service.dispose());

    test(
      'persists reasoning, tools, signatures, usage and final content',
      () async {
        final result = await service.run(
          placeholder: placeholder,
          assistant: assistant,
          settings: settings,
          providerKey: 'P',
          modelId: 'reasoning-model',
          prepared: GroupMemberGenerationPreparation(
            apiMessages: const [
              {'role': 'user', 'content': 'question'},
            ],
            toolDefs: const [
              {
                'type': 'function',
                'function': {'name': 'search'},
              },
            ],
            onToolCall: null,
            userMediaPaths: const [],
          ),
          sendMessageStream: (_) async* {
            yield ChatStreamChunk(
              content: '',
              reasoning: 'thinking',
              reasoningDetails: const [
                {'type': 'reasoning.text', 'signature': 'openrouter-sig'},
              ],
              isDone: false,
              totalTokens: 0,
            );
            yield ChatStreamChunk(
              content: '',
              isDone: false,
              totalTokens: 0,
              toolCalls: [
                ToolCallInfo(
                  id: 'tool-1',
                  name: 'search',
                  arguments: const {'q': 'Cuplivo'},
                ),
              ],
            );
            yield ChatStreamChunk(
              content: '',
              isDone: false,
              totalTokens: 0,
              toolResults: [
                ToolResultInfo(
                  id: 'tool-1',
                  name: 'search',
                  arguments: const {'q': 'Cuplivo'},
                  content: 'result',
                ),
              ],
            );
            yield ChatStreamChunk(
              content: 'answer<!-- gemini_thought_signatures:gemini-sig -->',
              isDone: true,
              totalTokens: 5,
              usage: const TokenUsage(
                promptTokens: 2,
                completionTokens: 3,
                cachedTokens: 1,
                totalTokens: 5,
              ),
            );
          },
          isCancelled: () => false,
        );
        await Future<void>.delayed(Duration.zero);

        expect(result.content, 'answer');
        expect(result.isStreaming, isFalse);
        expect(result.reasoningText, 'thinking');
        expect(result.reasoningFinishedAt, isNotNull);
        expect(result.reasoningSegmentsJson, contains('openrouter-sig'));
        expect(result.totalTokens, 5);
        expect(result.promptTokens, 2);
        expect(result.completionTokens, 3);
        expect(result.cachedTokens, 1);
        expect(groupService.signatures[result.id], contains('gemini-sig'));
        expect(groupService.toolEvents[result.id], hasLength(1));
        expect(groupService.toolEvents[result.id]!.single['content'], 'result');
      },
    );

    test('cancellation persists a non-streaming interrupted message', () async {
      await expectLater(
        service.run(
          placeholder: placeholder,
          assistant: assistant,
          settings: settings,
          providerKey: 'P',
          modelId: 'reasoning-model',
          prepared: const GroupMemberGenerationPreparation(
            apiMessages: [],
            toolDefs: [],
            onToolCall: null,
            userMediaPaths: [],
          ),
          sendMessageStream: (_) async* {
            yield ChatStreamChunk(
              content: 'partial',
              isDone: false,
              totalTokens: 1,
            );
          },
          isCancelled: () => true,
        ),
        throwsA(anything),
      );

      expect(groupService.messages[placeholder.id]?.isStreaming, isFalse);
    });

    test('API failure persists a non-streaming message and rethrows', () async {
      await expectLater(
        service.run(
          placeholder: placeholder,
          assistant: assistant,
          settings: settings,
          providerKey: 'P',
          modelId: 'reasoning-model',
          prepared: const GroupMemberGenerationPreparation(
            apiMessages: [],
            toolDefs: [],
            onToolCall: null,
            userMediaPaths: [],
          ),
          sendMessageStream: (_) => Stream.error(StateError('api failed')),
          isCancelled: () => false,
        ),
        throwsStateError,
      );

      expect(groupService.messages[placeholder.id]?.isStreaming, isFalse);
    });
  });
}

class _MemoryGroupChatService extends GroupChatService {
  final Map<String, GroupChatMessage> messages = {};
  final Map<String, List<Map<String, dynamic>>> toolEvents = {};
  final Map<String, String> signatures = {};

  @override
  String? get currentGroupId => 'g1';

  @override
  Future<void> updateMessage(
    GroupChatMessage message, {
    bool notify = true,
  }) async {
    messages[message.id] = message;
  }

  @override
  List<Map<String, dynamic>> getToolEvents(String messageId) =>
      List<Map<String, dynamic>>.of(toolEvents[messageId] ?? const []);

  @override
  Future<void> setToolEvents(
    String messageId,
    List<Map<String, dynamic>> events,
  ) async {
    toolEvents[messageId] = List<Map<String, dynamic>>.of(events);
  }

  @override
  Future<void> upsertToolEvent(
    String messageId, {
    required String id,
    required String name,
    required Map<String, dynamic> arguments,
    String? content,
    Map<String, dynamic>? metadata,
  }) async {
    final events = toolEvents.putIfAbsent(messageId, () => []);
    final index = events.indexWhere((event) => event['id'] == id);
    final event = <String, dynamic>{
      'id': id,
      'name': name,
      'arguments': arguments,
      'content': content,
      if (metadata != null) 'metadata': metadata,
    };
    if (index < 0) {
      events.add(event);
    } else {
      events[index] = event;
    }
  }

  @override
  String? getGeminiThoughtSignature(String messageId) => signatures[messageId];

  @override
  Future<void> setGeminiThoughtSignature(
    String messageId,
    String signature,
  ) async {
    signatures[messageId] = signature;
  }
}

class _StreamSettings extends Fake implements SettingsProvider {
  final ProviderConfig config = ProviderConfig(
    id: 'P',
    enabled: true,
    name: 'P',
    apiKey: 'key',
    baseUrl: 'https://example.com',
    modelOverrides: const {
      'reasoning-model': {
        'abilities': ['reasoning', 'tool'],
      },
    },
  );

  @override
  ProviderConfig getProviderConfig(String key, {String? defaultName}) => config;

  @override
  int? get thinkingBudget => null;

  @override
  bool get autoCollapseThinking => false;
}
