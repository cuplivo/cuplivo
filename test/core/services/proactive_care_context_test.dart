import 'dart:async';
import 'dart:convert';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/assistant_regex.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/world_book.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';
import 'package:Cuplivo/core/services/chat/chat_context_transforms.dart';
import 'package:Cuplivo/core/services/proactive_care_decision_tools.dart';
import 'package:Cuplivo/core/services/proactive_care_message_flow.dart';
import 'package:Cuplivo/core/services/world_book_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

ChatMessage message({
  required String id,
  required String role,
  required String content,
  required DateTime timestamp,
  bool isPreset = false,
}) {
  return ChatMessage(
    id: id,
    role: role,
    content: content,
    timestamp: timestamp,
    conversationId: 'conversation-1',
    isPreset: isPreset,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    businessPrefs = BusinessPreferences.memoryForTests();
    businessPrefs = BusinessPreferences.memoryForTests(<String, Object>{});
    await WorldBookStore(businessPrefs).clear();
  });

  group('ProactiveCareMessageFlow context', () {
    test(
      'care history applies send regexes and timestamps real users only',
      () {
        final assistant = Assistant(
          id: 'assistant-1',
          name: 'Assistant',
          enableTimeInjection: true,
          regexRules: const [
            AssistantRegex(
              id: 'user-regex',
              name: 'User replacement',
              pattern: 'alpha',
              replacement: 'beta',
              scopes: [AssistantRegexScope.user],
              replaceOnly: true,
            ),
            AssistantRegex(
              id: 'assistant-regex',
              name: 'Assistant replacement',
              pattern: 'hello',
              replacement: 'goodbye',
              scopes: [AssistantRegexScope.assistant],
              replaceOnly: true,
            ),
          ],
        );
        final conversation = Conversation(id: 'conversation-1', title: 'Chat');
        final timestamp = DateTime(2026, 8, 18, 9, 7, 5);
        final messages = [
          message(
            id: 'user-real',
            role: 'user',
            content: 'alpha',
            timestamp: timestamp,
          ),
          message(
            id: 'user-preset',
            role: 'user',
            content: 'alpha preset',
            timestamp: timestamp,
            isPreset: true,
          ),
          message(
            id: 'assistant',
            role: 'assistant',
            content: 'hello',
            timestamp: timestamp,
          ),
        ];

        final careHistory = ProactiveCareMessageFlow(preferences: businessPrefs)
            .buildHistory(
              conversation: conversation,
              messages: messages,
              assistant: assistant,
              applySendRegexes: true,
            );
        final decisionHistory =
            ProactiveCareMessageFlow(preferences: businessPrefs).buildHistory(
              conversation: conversation,
              messages: messages,
              assistant: assistant,
              applySendRegexes: false,
            );

        expect(careHistory, [
          {'role': 'user', 'content': 'beta\n\n(Tue 26-08-18 09:07:05)'},
          {'role': 'user', 'content': 'beta preset'},
          {'role': 'assistant', 'content': 'goodbye'},
        ]);
        expect(decisionHistory, [
          {'role': 'user', 'content': 'alpha\n\n(Tue 26-08-18 09:07:05)'},
          {'role': 'user', 'content': 'alpha preset'},
          {'role': 'assistant', 'content': 'hello'},
        ]);
      },
    );

    test('disabled smart time leaves history unchanged', () {
      final assistant = Assistant(id: 'assistant-1', name: 'Assistant');
      final conversation = Conversation(id: 'conversation-1', title: 'Chat');

      final history = ProactiveCareMessageFlow(preferences: businessPrefs)
          .buildHistory(
            conversation: conversation,
            messages: [
              message(
                id: 'user',
                role: 'user',
                content: 'hello',
                timestamp: DateTime(2026, 8, 18),
              ),
            ],
            assistant: assistant,
            applySendRegexes: false,
          );

      expect(history.single['content'], 'hello');
    });

    test('care send regexes preserve attachment markers', () {
      final assistant = Assistant(
        id: 'assistant-1',
        name: 'Assistant',
        regexRules: const [
          AssistantRegex(
            id: 'user-regex',
            name: 'User replacement',
            pattern: 'alpha',
            replacement: 'beta',
            scopes: [AssistantRegexScope.user],
            replaceOnly: true,
          ),
        ],
      );
      final conversation = Conversation(id: 'conversation-1', title: 'Chat');

      final history = ProactiveCareMessageFlow(preferences: businessPrefs)
          .buildHistory(
            conversation: conversation,
            messages: [
              message(
                id: 'user',
                role: 'user',
                content:
                    'alpha [image:/tmp/alpha.png] '
                    '[file:/tmp/alpha.pdf|alpha.pdf|application/pdf] omega',
                timestamp: DateTime(2026, 8, 18),
              ),
            ],
            assistant: assistant,
            applySendRegexes: true,
          );

      expect(
        history.single['content'],
        'beta [image:/tmp/alpha.png] '
        '[file:/tmp/alpha.pdf|alpha.pdf|application/pdf] omega',
      );
    });

    test(
      'care request injects world book, recent chats, and time note',
      () async {
        const worldBook = WorldBook(
          id: 'book-1',
          entries: [
            WorldBookEntry(
              id: 'entry-1',
              content: 'world-book-hit',
              keywords: ['care-keyword'],
              position: WorldBookInjectionPosition.afterSystemPrompt,
            ),
          ],
        );
        await WorldBookStore(businessPrefs).save(const [worldBook]);
        // No assistant-specific selection: exercise the global fallback.
        await WorldBookStore(businessPrefs).setActiveIds(const ['book-1']);
        final assistant = Assistant(
          id: 'assistant-1',
          name: 'Assistant',
          systemPrompt: 'persona',
          enableTimeInjection: true,
          enableRecentChatsReference: true,
          limitContextMessages: false,
        );

        final apiMessages =
            await ProactiveCareMessageFlow(
              preferences: businessPrefs,
            ).buildCareApiMessages(
              assistant: assistant,
              userNickname: 'User',
              modelId: 'model',
              history: const [
                {
                  'role': 'user',
                  'content': 'history\n\n(Tue 26-08-18 09:07:05)',
                },
              ],
              carePrompt: 'care-keyword',
              now: DateTime(2026, 8, 18, 10),
              recentChats: [
                Conversation(
                  id: 'recent',
                  title: 'Trip',
                  updatedAt: DateTime(2026, 8, 17),
                  assistantId: 'assistant-1',
                  summary: 'Pack tonight',
                ),
              ],
            );

        final system = apiMessages.first['content'] as String;
        expect(system, startsWith('persona'));
        expect(system, contains('<recent_chats>'));
        expect(system, contains('2026-08-17: Trip || Pack tonight'));
        expect(system, contains('world-book-hit'));
        expect(system, contains(ChatContextTransforms.timeNote));
        final careMessage = apiMessages.last['content'] as String;
        expect(careMessage, contains('care-keyword'));
        expect(careMessage, contains('2026-08-18T10:00:00.000'));
        expect(careMessage, isNot(contains('Tue 26-08-18')));
      },
    );

    test('assistant world-book selection overrides global fallback', () async {
      await WorldBookStore(businessPrefs).save(const [
        WorldBook(
          id: 'global-book',
          entries: [
            WorldBookEntry(
              id: 'global-entry',
              content: 'global-content',
              constantActive: true,
            ),
          ],
        ),
        WorldBook(
          id: 'assistant-book',
          entries: [
            WorldBookEntry(
              id: 'assistant-entry',
              content: 'assistant-content',
              constantActive: true,
            ),
          ],
        ),
      ]);
      await WorldBookStore(businessPrefs).setActiveIds(const ['global-book']);
      await WorldBookStore(
        businessPrefs,
      ).setActiveIds(const ['assistant-book'], assistantId: 'assistant-1');

      final messages =
          await ProactiveCareMessageFlow(
            preferences: businessPrefs,
          ).buildCareApiMessages(
            assistant: Assistant(id: 'assistant-1', name: 'Assistant'),
            userNickname: 'User',
            modelId: 'model',
            history: const <Map<String, dynamic>>[],
            carePrompt: 'send care',
            now: DateTime(2026, 8, 18, 10),
          );

      expect(messages.toString(), contains('assistant-content'));
      expect(messages.toString(), isNot(contains('global-content')));
    });

    test(
      'headless care reloads world books changed after cache fill',
      () async {
        const staleBook = WorldBook(
          id: 'stale-book',
          entries: [
            WorldBookEntry(
              id: 'stale-entry',
              content: 'stale-world-book-content',
              constantActive: true,
            ),
          ],
        );
        const cachedFreshBook = WorldBook(
          id: 'fresh-book',
          entries: [
            WorldBookEntry(
              id: 'fresh-entry',
              content: 'outdated-fresh-world-book-content',
              constantActive: true,
            ),
          ],
        );
        const freshBook = WorldBook(
          id: 'fresh-book',
          entries: [
            WorldBookEntry(
              id: 'fresh-entry',
              content: 'fresh-world-book-content',
              constantActive: true,
            ),
          ],
        );
        await WorldBookStore(
          businessPrefs,
        ).save(const [staleBook, cachedFreshBook]);
        await WorldBookStore(businessPrefs).setActiveIds(const ['stale-book']);
        expect(await WorldBookStore(businessPrefs).getAll(), hasLength(2));

        final prefs = businessPrefs;
        await prefs.setString(
          'world_books_v1',
          jsonEncode(
            const [staleBook, freshBook].map((book) => book.toJson()).toList(),
          ),
        );
        await prefs.setString(
          'world_books_active_ids_by_assistant_v1',
          jsonEncode(const {
            '__global__': ['fresh-book'],
          }),
        );

        final messages =
            await ProactiveCareMessageFlow(
              preferences: businessPrefs,
            ).buildCareApiMessages(
              assistant: Assistant(id: 'assistant-1', name: 'Assistant'),
              userNickname: 'User',
              modelId: 'model',
              history: const <Map<String, dynamic>>[],
              carePrompt: 'send care',
              now: DateTime(2026, 8, 18, 10),
              reloadWorldBooks: true,
            );

        expect(messages.toString(), contains('fresh-world-book-content'));
        expect(
          messages.toString(),
          isNot(contains('stale-world-book-content')),
        );
        expect(
          messages.toString(),
          isNot(contains('outdated-fresh-world-book-content')),
        );
      },
    );

    test('care context limit keeps system and newest tail', () async {
      final assistant = Assistant(
        id: 'assistant-1',
        name: 'Assistant',
        systemPrompt: 'persona',
        contextMessageSize: 2,
        limitContextMessages: true,
      );

      final apiMessages =
          await ProactiveCareMessageFlow(
            preferences: businessPrefs,
          ).buildCareApiMessages(
            assistant: assistant,
            userNickname: 'User',
            modelId: 'model',
            history: const [
              {'role': 'user', 'content': 'old-user'},
              {'role': 'assistant', 'content': 'old-assistant'},
              {'role': 'user', 'content': 'latest-user'},
              {'role': 'assistant', 'content': 'latest-assistant'},
            ],
            carePrompt: 'send care',
            now: DateTime(2026, 8, 18, 10),
          );

      expect(apiMessages.map((item) => item['content']), [
        'persona',
        'latest-assistant',
        'send care\n\n当前系统时间：2026-08-18T10:00:00.000',
      ]);
    });

    test(
      'decision adds only smart time context and does not crop history',
      () async {
        List<Map<String, dynamic>>? capturedMessages;
        final assistant = Assistant(
          id: 'assistant-1',
          name: 'Assistant',
          systemPrompt: 'persona-without-world-book',
          enableTimeInjection: true,
          contextMessageSize: 1,
          limitContextMessages: true,
        );

        final result =
            await ProactiveCareMessageFlow(
              preferences: businessPrefs,
            ).decideNextCareTime(
              config: ProviderConfig.defaultsFor('TestProvider'),
              modelId: 'test-model',
              assistant: assistant,
              userNickname: 'User',
              currentNextCareTime: null,
              history: const [
                {'role': 'user', 'content': 'first\n\n(Tue 26-08-18 09:00:00)'},
                {'role': 'assistant', 'content': 'second'},
                {'role': 'user', 'content': 'third\n\n(Tue 26-08-18 09:05:00)'},
              ],
              decisionPrompt: 'decide',
              sendMessageStream:
                  ({
                    required config,
                    required modelId,
                    required messages,
                    tools,
                    onToolCall,
                    thinkingBudget,
                    temperature,
                    topP,
                    maxTokens,
                    stream = true,
                    requestId,
                  }) {
                    capturedMessages = messages;
                    return Stream<ChatStreamChunk>.value(
                      ChatStreamChunk(
                        content: '',
                        isDone: false,
                        totalTokens: 0,
                        toolCalls: [
                          ToolCallInfo(
                            id: 'keep',
                            name: ProactiveCareDecisionTools.keepTime,
                            arguments: <String, dynamic>{},
                          ),
                        ],
                      ),
                    );
                  },
            );

        expect(result, isNull);
        final captured = capturedMessages!;
        expect(captured.first['role'], 'system');
        expect(
          captured.first['content'],
          contains(ChatContextTransforms.timeNote),
        );
        expect(captured.any((item) => item['content'] == 'second'), isTrue);
        expect(
          captured.where(
            (item) =>
                (item['content'] ?? '').toString().contains('Tue 26-08-18'),
          ),
          hasLength(2),
        );
        expect(captured.toString(), isNot(contains('world-book-hit')));
        expect(captured.toString(), isNot(contains('<recent_chats>')));
      },
    );
  });
}
