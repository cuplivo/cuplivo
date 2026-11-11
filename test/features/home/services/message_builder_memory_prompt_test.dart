import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_data.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/memory_entry.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/logging/context_log_models.dart';
import 'package:Cuplivo/core/services/logging/context_logger.dart';
import 'package:Cuplivo/core/services/memory/memory_block_builder.dart';
import 'package:Cuplivo/core/services/memory/memory_prompts.dart';
import 'package:Cuplivo/features/home/services/message_builder_service.dart';
import 'package:Cuplivo/features/home/services/ocr_service.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

class _FakeBuildContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeChatService extends ChatService {
  _FakeChatService(this.persistedMessages);

  final List<ChatMessage> persistedMessages;

  @override
  List<ChatMessage> getMessages(String conversationId) {
    return persistedMessages
        .where((message) => message.conversationId == conversationId)
        .toList();
  }
}

class _CountingPromptRepository extends ChatDatabaseRepository {
  _CountingPromptRepository(super.database);

  int singlePromptReads = 0;
  int batchPromptReads = 0;

  /// Revision ids whose prompt row was written, in order. A turn that changes
  /// nothing must leave this empty: re-freezing a carrier is what moves the
  /// rewrite point, and no test can see that in the payload alone.
  final List<String> promptWrites = <String>[];

  @override
  Future<MessagePromptRow?> getMessagePrompt(String revisionId) {
    singlePromptReads++;
    return super.getMessagePrompt(revisionId);
  }

  @override
  Future<Map<String, MessagePromptRow>> getMessagePrompts(
    Iterable<String> revisionIds,
  ) {
    batchPromptReads++;
    return super.getMessagePrompts(revisionIds);
  }

  @override
  Future<void> putMessagePrompt({
    required String revisionId,
    required String conversationId,
    required String payload,
    required bool carriesMemorySnapshot,
  }) {
    promptWrites.add(revisionId);
    return super.putMessagePrompt(
      revisionId: revisionId,
      conversationId: conversationId,
      payload: payload,
      carriesMemorySnapshot: carriesMemorySnapshot,
    );
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase database;
  late BusinessRepository businessRepository;
  late BusinessPreferences preferences;
  late ChatDatabaseRepository chatRepository;
  late SettingsProvider settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) => raw.execute('PRAGMA foreign_keys = ON;'),
      ),
    );
    businessRepository = BusinessRepository(database);
    preferences = BusinessPreferences(businessRepository);
    chatRepository = ChatDatabaseRepository(database);
    await chatRepository.ensureReady();
    await preferences.load();
    settings = SettingsProvider(preferences);
    await settings.loaded;
    await settings.setMemoryPromptLang('zh');
  });

  tearDown(() async {
    await ContextLogger.setEnabled(false);
    await database.close();
  });

  Future<void> seedAssistant(String id) async {
    final raw = preferences.getString(BusinessEntityKind.assistant.sourceKey);
    final list = <Map<String, dynamic>>[
      if (raw != null && raw.isNotEmpty)
        for (final item in jsonDecode(raw) as List)
          (item as Map).cast<String, dynamic>(),
    ];
    if (!list.any((item) => item['id'] == id)) {
      list.add({'id': id, 'name': id});
    }
    await preferences.setString(
      BusinessEntityKind.assistant.sourceKey,
      jsonEncode(list),
    );
  }

  Future<void> putEntry({
    required String id,
    required String content,
    MemoryType type = MemoryType.identity,
    MemoryScope scope = MemoryScope.global,
    String? assistantId,
    MemoryStatus status = MemoryStatus.active,
  }) {
    final created = DateTime.utc(2026, 8, 1).microsecondsSinceEpoch;
    return businessRepository.upsertEntity(
      BusinessEntityKind.memoryEntry,
      BusinessEntityValue(
        id: id,
        sortOrder: 0,
        payload: jsonEncode({
          'id': id,
          'scope': MemoryEntry.scopeToString(scope),
          'assistantId': assistantId,
          'type': MemoryEntry.typeToString(type),
          'status': MemoryEntry.statusToString(status),
          'content': content,
          'source': 'manual',
          'relatedIds': <String>[],
          'createdAt': created,
          'updatedAt': created,
        }),
      ),
    );
  }

  Future<Conversation> seedConversation(
    String id, {
    String? injectedMemoryHash,
  }) async {
    final conversation = Conversation(
      id: id,
      title: id,
      injectedMemoryHash: injectedMemoryHash,
    );
    await chatRepository.putConversation(conversation);
    return conversation;
  }

  Future<ChatMessage> seedUserMessage({
    required String id,
    required String conversationId,
    String content = 'hi',
    List<MessagePart>? parts,
    DateTime? timestamp,
    int? messageOrder,
  }) async {
    final message = ChatMessage(
      id: id,
      role: 'user',
      content: content,
      parts: parts,
      conversationId: conversationId,
      timestamp: timestamp,
    );
    await chatRepository.putMessage(message, messageOrder: messageOrder);
    return message;
  }

  MessageBuilderService buildService({
    List<ChatMessage> messages = const [],
    ChatDatabaseRepository? repository,
    Future<String?> Function(
      List<String> imagePaths, {
      String? revisionId,
      OcrPrepareSession? session,
      String? requestId,
    })?
    ocrHandler,
    Future<OcrPrepareSession> Function({
      required List<String> revisionIds,
      required List<String> imagePaths,
    })?
    ocrPrefetch,
  }) {
    return MessageBuilderService(
      chatService: _FakeChatService(messages),
      contextProvider: _FakeBuildContext(),
      chatRepository: repository ?? chatRepository,
      ocrHandler: ocrHandler,
      ocrPrefetch: ocrPrefetch,
    );
  }

  const assistant = Assistant(
    id: 'assistant-1',
    name: 'Test',
    enableMemory: true,
    messageTemplate: '{{ message }}',
  );

  test('each assistant injects its own selected types', () async {
    await seedAssistant(assistant.id);
    await seedAssistant('other');
    await settings.setMemoryInjectionMaxItems(1);
    for (final type in [MemoryType.voice, MemoryType.workflow]) {
      for (var i = 0; i < 2; i++) {
        await putEntry(
          id: '${type.name}-$i',
          type: type,
          content: '${type.name} $i',
        );
      }
    }
    final service = buildService();
    final a = assistant.copyWith(memoryFullInjectionTypes: {MemoryType.voice});
    final b = assistant.copyWith(
      id: 'other',
      memoryFullInjectionTypes: {MemoryType.workflow},
    );
    Future<String> snapshot(Assistant value) async =>
        (await service.currentMemorySnapshot(
          assistant: value,
          lang: MemoryPromptLang.zh,
          settings: settings,
        ))!.prefix;
    final first = await snapshot(a);
    final second = await snapshot(b);
    expect(first, contains('<user_memory type="voice">'));
    expect(
      first,
      contains(
        '<user_memory type="workflow" mode="summary" total="2" shown="1">',
      ),
    );
    expect(second, contains('<user_memory type="workflow">'));
    expect(
      second,
      contains('<user_memory type="voice" mode="summary" total="2" shown="1">'),
    );
    await snapshot(a.copyWith(memoryFullInjectionTypes: {}));
    expect(await snapshot(b), second);
  });

  for (final initiallyFull in [false, true]) {
    test(
      'full injection toggle refreshes sends and regeneration ($initiallyFull)',
      () async {
        await seedAssistant(assistant.id);
        await seedAssistant('other');
        await settings.setMemoryInjectionMaxItems(1);
        var currentAssistant = assistant.copyWith(
          memoryFullInjectionTypes: initiallyFull ? {MemoryType.voice} : {},
        );
        await putEntry(
          id: 'voice-1',
          type: MemoryType.voice,
          content: 'Global voice',
        );
        await putEntry(
          id: 'voice-2',
          type: MemoryType.voice,
          content: 'Assistant voice',
          scope: MemoryScope.assistant,
          assistantId: assistant.id,
        );
        await putEntry(
          id: 'voice-3',
          type: MemoryType.voice,
          content: 'Other assistant voice',
          scope: MemoryScope.assistant,
          assistantId: 'other',
        );
        await putEntry(
          id: 'voice-4',
          type: MemoryType.voice,
          content: 'Archived voice',
          status: MemoryStatus.archived,
        );
        await putEntry(id: 'identity-1', content: 'First identity');
        await putEntry(id: 'identity-2', content: 'Second identity');
        final conversation = await seedConversation('injection-toggle');
        final first = await seedUserMessage(
          id: 'first',
          conversationId: conversation.id,
        );
        final service = buildService();

        Future<List<Map<String, dynamic>>> assemble(
          List<ChatMessage> messages,
        ) async {
          final api = service.buildApiMessages(
            messages: messages,
            versionSelections: const {},
            currentConversation: conversation,
          );
          await service.processUserMessagesForApi(
            api,
            settings,
            currentAssistant,
            conversation: conversation,
            sourceMessages: messages,
          );
          return api;
        }

        void expectSnapshot(
          List<Map<String, dynamic>> api, {
          required bool full,
        }) {
          final text = api.map((m) => m['content']).join('\n');
          expect(MemoryPrompts.introFullZh.allMatches(text), hasLength(1));
          expect(text, contains('Global voice'));
          expect(
            text,
            full
                ? contains('(assistant) Assistant voice')
                : isNot(contains('Assistant voice')),
          );
          expect(text, contains('First identity'));
          expect(text, isNot(contains('Second identity')));
          expect(text, isNot(contains('Other assistant voice')));
          expect(text, isNot(contains('Archived voice')));
        }

        expectSnapshot(await assemble([first]), full: initiallyFull);
        final frozen = (await chatRepository.getMessagePrompt(
          first.id,
        ))!.payload;
        currentAssistant = currentAssistant.copyWith(
          memoryFullInjectionTypes: initiallyFull ? {} : {MemoryType.voice},
        );

        // Regeneration has only the frozen user message to carry the new snapshot.
        expectSnapshot(await assemble([first]), full: !initiallyFull);
        expect(
          (await chatRepository.getMessagePrompt(first.id))!.payload,
          frozen,
        );

        final second = await seedUserMessage(
          id: 'second',
          conversationId: conversation.id,
          content: 'next question',
          messageOrder: 1,
        );
        expectSnapshot(await assemble([first, second]), full: !initiallyFull);
        expectSnapshot(await assemble([first, second]), full: !initiallyFull);
        expect(
          (await chatRepository.getMessagePrompt(first.id))!.payload,
          frozen,
        );
      },
    );
  }

  test(
    'context preview includes live memory without freezing or running OCR',
    () async {
      await seedAssistant(assistant.id);
      await putEntry(
        id: 'mem_preview',
        content: 'User prefers concise answers.',
      );
      final conversation = await seedConversation('preview');
      final message = await seedUserMessage(
        id: 'preview-user',
        conversationId: conversation.id,
        content: 'question',
        parts: const [
          TextPart('question'),
          ImagePart(uri: '/missing.png'),
        ],
      );
      await settings.setOcrModel('Test', 'vision');
      await settings.setOcrEnabled(true);
      final service = buildService(
        messages: [message],
        ocrHandler: (paths, {revisionId, session, requestId}) async {
          fail('Preview must not run OCR');
        },
        ocrPrefetch: ({required revisionIds, required imagePaths}) async {
          fail('Preview must not prefetch OCR');
        },
      );
      final apiMessages = service.buildApiMessages(
        messages: [message],
        versionSelections: {},
        currentConversation: conversation,
      );
      await service.processUserMessagesForApi(
        apiMessages,
        settings,
        assistant,
        conversation: conversation,
        sourceMessages: [message],
        previewOnly: true,
      );
      final segments = segmentsFromTaggedMessage(apiMessages.single);
      expect(
        segments
            .where((s) => s.source == ContextSource.memorySnapshot)
            .map((s) => s.text)
            .join(),
        contains('User prefers concise answers.'),
      );
      expect(
        segments
            .where((s) => s.source == ContextSource.chatHistory)
            .map((s) => s.text)
            .join(),
        'question',
      );
      expect(await chatRepository.getMessagePrompt(message.id), isNull);
      expect(
        (await chatRepository.getConversation(
          conversation.id,
        ))!.injectedMemoryHash,
        isNull,
      );
    },
  );

  group('§7.6 — the carrier record decides the request', () {
    // What the send path does, as the provider would see it: the same list it
    // mutates in place, so `api[n]['content']` is a real payload.
    Future<void> runTurn(
      List<Map<String, dynamic>> api, {
      required Conversation conversation,
      List<ChatMessage> messages = const [],
      Assistant? who,
      ChatDatabaseRepository? repository,
    }) async {
      await buildService(
        messages: messages,
        repository: repository,
      ).processUserMessagesForApi(
        api,
        settings,
        who ?? assistant,
        conversation: conversation,
        sourceMessages: messages,
      );
    }

    Map<String, dynamic> userTurn(String id, String content) => {
      'role': 'user',
      'content': content,
      MessageBuilderService.internalRevisionIdKey: id,
    };

    test('enableMemory off injects nothing and records nothing', () async {
      await seedAssistant('assistant-1');
      await putEntry(id: 'mem_01', content: 'User likes Flutter.');
      final conversation = await seedConversation('conv-1');
      final u1 = await seedUserMessage(id: 'u1', conversationId: 'conv-1');
      final api = [userTurn('u1', 'hi')];

      await runTurn(
        api,
        conversation: conversation,
        messages: [u1],
        who: assistant.copyWith(enableMemory: false),
      );

      expect(api.single['content'], 'hi');
      final frozen = await chatRepository.getMessagePrompt('u1');
      expect(frozen?.carriesMemorySnapshot, isFalse);
    });

    test('an empty memory state injects nothing', () async {
      await seedAssistant('assistant-1');
      final conversation = await seedConversation('conv-1');
      final u1 = await seedUserMessage(id: 'u1', conversationId: 'conv-1');
      final api = [userTurn('u1', 'hi')];

      await runTurn(api, conversation: conversation, messages: [u1]);

      expect(api.single['content'], 'hi');
      expect(
        (await chatRepository.getMessagePrompt('u1'))?.carriesMemorySnapshot,
        isFalse,
      );
    });

    test(
      'with no recorded carrier the snapshot lands on the last message',
      () async {
        // A freshly synced conversation: the messages arrived, the freeze rows
        // did not (they never travel), and the peer's row still carries its own
        // memory ledger. Deciding inside the assembly loop let the *oldest*
        // message take the snapshot and froze it there, so every later memory
        // change rewrote the prompt from message one and the provider's prefix
        // cache kept nothing but the system prompt (issue #1086, 1920/250297).
        await seedAssistant('assistant-1');
        await putEntry(id: 'mem_01', content: 'User likes Flutter.');
        final conversation = await seedConversation(
          'conv-1',
          injectedMemoryHash: 'peerhash00000001',
        );
        final u1 = await seedUserMessage(id: 'u1', conversationId: 'conv-1');
        final u2 = await seedUserMessage(
          id: 'u2',
          conversationId: 'conv-1',
          content: 'two',
          messageOrder: 1,
        );
        final u3 = await seedUserMessage(
          id: 'u3',
          conversationId: 'conv-1',
          content: 'three',
          messageOrder: 2,
        );
        final api = [
          userTurn('u1', 'hi'),
          {'role': 'assistant', 'content': 'hello'},
          userTurn('u2', 'two'),
          {'role': 'assistant', 'content': 'hello again'},
          userTurn('u3', 'three'),
        ];

        await runTurn(api, conversation: conversation, messages: [u1, u2, u3]);

        expect(api[0]['content'], 'hi');
        expect(api[2]['content'], 'two');
        expect(api[4]['content'], startsWith(MemoryPrompts.introFullZh));
        expect(api[4]['content'], contains('User likes Flutter.'));
        final rows = await chatRepository.getMessagePrompts(['u1', 'u2', 'u3']);
        expect(
          rows.values.where((row) => row.carriesMemorySnapshot),
          hasLength(1),
          reason: 'exactly one message may carry the snapshot',
        );
        expect(rows['u3']!.carriesMemorySnapshot, isTrue);
      },
    );

    test('a turn that changes no memory moves nothing', () async {
      // 0.6 of the turns in the reported workload change nothing, and they are
      // where the cache has to hold: moving the carrier every turn re-sends the
      // snapshot and invalidates the tail behind it (25k/round instead of 13k).
      await seedAssistant('assistant-1');
      await putEntry(id: 'mem_01', content: 'User likes Flutter.');
      final conversation = await seedConversation('conv-1');
      final u1 = await seedUserMessage(id: 'u1', conversationId: 'conv-1');
      final u2 = await seedUserMessage(
        id: 'u2',
        conversationId: 'conv-1',
        content: 'next',
        messageOrder: 1,
      );

      final first = [userTurn('u1', 'hi')];
      await runTurn(first, conversation: conversation, messages: [u1]);
      final frozen = (await chatRepository.getMessagePrompt('u1'))!.payload;
      expect(frozen, startsWith(MemoryPrompts.introFullZh));

      final counting = _CountingPromptRepository(database);
      final second = [userTurn('u1', 'hi'), userTurn('u2', 'next')];
      await runTurn(
        second,
        conversation: conversation,
        messages: [u1, u2],
        repository: counting,
      );

      expect(
        second[0]['content'],
        frozen,
        reason: 'the recorded carrier is sent byte for byte',
      );
      expect(second[1]['content'], 'next');
      expect(
        (await chatRepository.getMessagePrompt('u1'))!.payload,
        frozen,
        reason: 'nothing is rewritten when memory has not changed',
      );
      expect(
        (await chatRepository.getMessagePrompt('u2'))!.carriesMemorySnapshot,
        isFalse,
      );
      expect(counting.promptWrites, [
        'u2',
      ], reason: 'only the message that had no freeze row yet is written');

      // The same request again: every row it needs already exists, so a turn
      // that changes nothing writes nothing at all.
      counting.promptWrites.clear();
      final again = [userTurn('u1', 'hi'), userTurn('u2', 'next')];
      await runTurn(
        again,
        conversation: conversation,
        messages: [u1, u2],
        repository: counting,
      );
      expect(again[0]['content'], frozen);
      expect(again[1]['content'], 'next');
      expect(counting.promptWrites, isEmpty);
    });

    test('the conversation ledger is not consulted, the record is', () async {
      // injectedMemoryHash is the peer's bookkeeping on this device after a
      // sync: it names a snapshot this device never had. Trusting it forced a
      // re-injection, and trusting it in the other direction swallowed a real
      // change. The request now reads the carrier's own bytes.
      await seedAssistant('assistant-1');
      await putEntry(id: 'mem_01', content: 'User likes Flutter.');
      final conversation = await seedConversation(
        'conv-1',
        injectedMemoryHash: 'stalehash0000001',
      );
      final u1 = await seedUserMessage(id: 'u1', conversationId: 'conv-1');
      final u2 = await seedUserMessage(
        id: 'u2',
        conversationId: 'conv-1',
        content: 'next',
        messageOrder: 1,
      );

      final first = [userTurn('u1', 'hi')];
      await runTurn(first, conversation: conversation, messages: [u1]);
      final frozen = (await chatRepository.getMessagePrompt('u1'))!.payload;

      final second = [userTurn('u1', 'hi'), userTurn('u2', 'next')];
      await runTurn(second, conversation: conversation, messages: [u1, u2]);

      expect(second[0]['content'], frozen);
      expect(second[1]['content'], 'next');
    });

    test(
      'a change moves the snapshot to the tail and leaves the row alone',
      () async {
        await seedAssistant('assistant-1');
        await putEntry(id: 'mem_01', content: 'Original content.');
        final conversation = await seedConversation('conv-1');
        final u1 = await seedUserMessage(id: 'u1', conversationId: 'conv-1');
        final u2 = await seedUserMessage(
          id: 'u2',
          conversationId: 'conv-1',
          content: 'next',
          messageOrder: 1,
        );

        final first = [userTurn('u1', 'hi')];
        await runTurn(first, conversation: conversation, messages: [u1]);
        final frozen = (await chatRepository.getMessagePrompt('u1'))!.payload;

        await putEntry(
          id: 'mem_01',
          content: 'Changed content that alters the hash.',
        );

        final second = [
          userTurn('u1', 'hi'),
          {'role': 'assistant', 'content': 'hello'},
          userTurn('u2', 'next'),
        ];
        await runTurn(second, conversation: conversation, messages: [u1, u2]);

        expect(
          second[0]['content'],
          'hi',
          reason: 'the stale prefix is dropped',
        );
        expect(
          second[2]['content'],
          allOf(
            startsWith(MemoryPrompts.introFullZh),
            contains('Changed content that alters the hash.'),
          ),
        );
        expect(
          (await chatRepository.getMessagePrompt('u1'))!.payload,
          frozen,
          reason: 'a freeze row records what was sent, so it is not rewritten',
        );
        expect(
          MemoryPrompts.introFullZh.allMatches(
            second.map((m) => m['content']).join('\n'),
          ),
          hasLength(1),
          reason: 'exactly one message in the request carries the snapshot',
        );
      },
    );

    test(
      'deleting the last memory strips the carrier and injects nothing',
      () async {
        await seedAssistant('assistant-1');
        await putEntry(id: 'mem_01', content: 'User likes Flutter.');
        final conversation = await seedConversation('conv-1');
        final u1 = await seedUserMessage(id: 'u1', conversationId: 'conv-1');
        final u2 = await seedUserMessage(
          id: 'u2',
          conversationId: 'conv-1',
          content: 'next',
          messageOrder: 1,
        );

        final first = [userTurn('u1', 'hi')];
        await runTurn(first, conversation: conversation, messages: [u1]);
        expect(first.single['content'], contains('User likes Flutter.'));

        await businessRepository.deleteEntity(
          BusinessEntityKind.memoryEntry,
          'mem_01',
        );

        final second = [userTurn('u1', 'hi'), userTurn('u2', 'next')];
        await runTurn(second, conversation: conversation, messages: [u1, u2]);

        final sent = second.map((m) => m['content']).join('\n');
        expect(sent, isNot(contains('User likes Flutter.')));
        expect(sent, isNot(contains('<user_profile/>')));
        expect(sent, isNot(contains(MemoryPrompts.introFullZh)));
        expect(second[0]['content'], 'hi');
        expect(second[1]['content'], 'next');
      },
    );

    test('a frozen message without the snapshot is left alone', () async {
      // Only rows that came from injection are candidates. Text that merely
      // looks like a snapshot is the user's own and must survive.
      await seedAssistant('assistant-1');
      await putEntry(id: 'mem_01', content: 'User likes Flutter.');
      final conversation = await seedConversation('conv-1');
      final pasted =
          '${MemoryPrompts.introFullZh}\n'
          '<user_profile/>\n'
          '<user_memory type="identity">\n'
          '- [2026-08-01] pasted by the user\n'
          '</user_memory>\n'
          '<user_memory type="workflow"/>\n'
          '<user_memory type="voice"/>\n'
          '<user_memory type="instruction"/>\n'
          'my question';
      final u1 = await seedUserMessage(
        id: 'u1',
        conversationId: 'conv-1',
        content: 'my question',
      );
      await chatRepository.putMessagePrompt(
        revisionId: 'u1',
        conversationId: 'conv-1',
        payload: pasted,
        carriesMemorySnapshot: false,
      );
      final u2 = await seedUserMessage(
        id: 'u2',
        conversationId: 'conv-1',
        content: 'next',
        messageOrder: 1,
      );
      final api = [userTurn('u1', 'my question'), userTurn('u2', 'next')];

      await runTurn(api, conversation: conversation, messages: [u1, u2]);

      expect(api[0]['content'], pasted);
      expect(api[1]['content'], startsWith(MemoryPrompts.introFullZh));
    });
  });

  for (final hasConversation in [false, true]) {
    for (final appendTime in [false, true]) {
      test(
        'API time format: conversation=$hasConversation, append=$appendTime',
        () async {
          await seedAssistant('assistant-1');
          final conversation = await seedConversation('conv-time');
          final timestamp = DateTime(2026, 9, 10, 14, 30, 5);
          final message = await seedUserMessage(
            id: 'u-time',
            conversationId: conversation.id,
            content: 'hello',
            timestamp: timestamp,
          );
          final apiMessages = <Map<String, dynamic>>[
            {
              'role': 'user',
              'content': 'hello',
              MessageBuilderService.internalRevisionIdKey: message.id,
            },
          ];
          await buildService().processUserMessagesForApi(
            apiMessages,
            settings,
            assistant.copyWith(
              enableMemory: false,
              appendCurrentTimeToUserMessage: appendTime,
              useIso8601TimeFormat: true,
            ),
            conversation: hasConversation ? conversation : null,
            sourceMessages: [message],
          );
          final expected = appendTime
              ? 'hello\n\n${MemoryPrompts.formatCurrentTimeTag(timestamp, useIso8601: true)}'
              : 'hello';
          expect(apiMessages.single['content'], expected);
        },
      );
    }
  }

  group('§18.4 item 29 — promptContent immutability', () {
    for (final iso8601 in [false, true]) {
      test(
        'time format ISO=$iso8601 stays frozen across retries and format changes',
        () async {
          await seedAssistant('assistant-1');
          await putEntry(id: 'mem_01', content: 'User likes Flutter.');

          final ts = DateTime(2026, 8, 7, 14, 3, 22);
          final conversation = await seedConversation('conv-1');
          final message = await seedUserMessage(
            id: 'u1',
            conversationId: 'conv-1',
            content: 'hello world',
            timestamp: ts,
          );
          final service = buildService(messages: [message]);

          // A frozen prompt is what the turn sends, whatever the body, the
          // template or the time format has become since.
          Future<String> send({
            required String body,
            required Assistant who,
          }) async {
            final api = <Map<String, dynamic>>[
              {
                'role': 'user',
                'content': body,
                MessageBuilderService.internalRevisionIdKey: 'u1',
              },
            ];
            await service.processUserMessagesForApi(
              api,
              settings,
              who,
              conversation: conversation,
              sourceMessages: [message],
            );
            return api.single['content'] as String;
          }

          final first = await send(
            body: 'hello world',
            who: assistant.copyWith(
              appendCurrentTimeToUserMessage: true,
              useIso8601TimeFormat: iso8601,
            ),
          );
          final second = await send(
            body: 'hello world CHANGED',
            who: assistant.copyWith(
              appendCurrentTimeToUserMessage: true,
              messageTemplate: 'IGNORE {{ message }}',
              useIso8601TimeFormat: !iso8601,
            ),
          );
          final retry = await send(body: 'retry body', who: assistant);

          expect(second, first);
          expect(retry, first);
          expect(first, contains('hello world'));
          expect(
            first,
            contains(
              MemoryPrompts.formatCurrentTimeTag(ts, useIso8601: iso8601),
            ),
          );
          expect(first, contains('<user_memory type="identity">'));
        },
      );
    }

    test(
      'first message of a fresh conversation gets the snapshot even when the '
      'chat cache is empty',
      () async {
        // ChatService only serves conversations already in its cache, so on a
        // brand new conversation the lookup misses. Falling back to an
        // unfrozen render silently dropped memory from the first turn, then
        // added it a turn later — rewriting history and losing the cache.
        await seedAssistant('assistant-1');
        await putEntry(id: 'mem_01', content: 'User likes Flutter.');

        final conversation = await seedConversation('conv-fresh');
        final message = await seedUserMessage(
          id: 'u1',
          conversationId: 'conv-fresh',
          content: 'what is my name',
        );

        // Empty cache, exactly as for a conversation created this turn.
        final service = buildService();
        final apiMessages = <Map<String, dynamic>>[
          {
            'role': 'user',
            'content': 'what is my name',
            MessageBuilderService.internalRevisionIdKey: 'u1',
          },
        ];

        await service.processUserMessagesForApi(
          apiMessages,
          settings,
          assistant,
          conversation: conversation,
          sourceMessages: [message],
        );

        final content = apiMessages.single['content'] as String;
        expect(content, contains(MemoryPrompts.introFullZh));
        expect(content, contains('<user_memory type="identity">'));
        expect(content, endsWith('what is my name'));

        // And it is frozen, so the next turn replays the same bytes.
        final frozen = await chatRepository.getMessagePrompt('u1');
        expect(frozen, isNotNull);
        expect(frozen!.payload, content);
        expect(frozen.carriesMemorySnapshot, isTrue);
      },
    );

    test(
      'failed OCR is retried instead of freezing an incomplete prompt',
      () async {
        await seedAssistant('assistant-1');
        final conversation = await seedConversation('conv-ocr-retry');
        final message = await seedUserMessage(
          id: 'u1',
          conversationId: conversation.id,
          parts: const [
            TextPart('describe this'),
            ImagePart(uri: '/tmp/retry.png', mime: 'image/png'),
          ],
        );
        await settings.setOcrModel('ocr-provider', 'ocr-model');
        await settings.setOcrEnabled(true);

        var ocrCalls = 0;
        final service = buildService(
          messages: [message],
          ocrHandler: (imagePaths, {revisionId, session, requestId}) async {
            ocrCalls++;
            return ocrCalls == 1 ? null : 'recognized image';
          },
        );

        List<Map<String, dynamic>> apiMessages() => [
          {
            'role': 'user',
            'content': message.content,
            MessageBuilderService.internalRevisionIdKey: message.id,
          },
        ];

        final first = apiMessages();
        await service.processUserMessagesForApi(
          first,
          settings,
          assistant,
          conversation: conversation,
          sourceMessages: [message],
        );
        expect(await chatRepository.getMessagePrompt(message.id), isNull);

        final retry = apiMessages();
        await service.processUserMessagesForApi(
          retry,
          settings,
          assistant,
          conversation: conversation,
          sourceMessages: [message],
        );

        expect(ocrCalls, 2);
        expect(retry.single['content'], contains('recognized image'));
        expect(
          (await chatRepository.getMessagePrompt(message.id))?.payload,
          retry.single['content'],
        );
      },
    );

    test(
      'cancelled OCR does not freeze the prompt or continue later messages',
      () async {
        await seedAssistant('assistant-1');
        final conversation = await seedConversation('conv-ocr-cancel');
        final first = await seedUserMessage(
          id: 'u1',
          conversationId: conversation.id,
          parts: const [
            TextPart('first'),
            ImagePart(uri: '/tmp/first.png', mime: 'image/png'),
          ],
        );
        final second = await seedUserMessage(
          id: 'u2',
          conversationId: conversation.id,
          parts: const [
            TextPart('second'),
            ImagePart(uri: '/tmp/second.png', mime: 'image/png'),
          ],
          messageOrder: 1,
        );
        await settings.setOcrModel('ocr-provider', 'ocr-model');
        await settings.setOcrEnabled(true);

        final ocrCalls = <String?>[];
        final service = buildService(
          messages: [first, second],
          ocrHandler: (imagePaths, {revisionId, session, requestId}) async {
            ocrCalls.add(revisionId);
            if (revisionId == first.id) return 'ocr-first';
            throw http.ClientException('cancelled');
          },
        );

        final apiMessages = <Map<String, dynamic>>[
          {
            'role': 'user',
            'content': first.content,
            MessageBuilderService.internalRevisionIdKey: first.id,
          },
          {
            'role': 'user',
            'content': second.content,
            MessageBuilderService.internalRevisionIdKey: second.id,
          },
        ];

        await expectLater(
          service.processUserMessagesForApi(
            apiMessages,
            settings,
            assistant,
            conversation: conversation,
            sourceMessages: [first, second],
          ),
          throwsA(isA<http.ClientException>()),
        );

        expect(ocrCalls, [first.id, second.id]);
        expect(await chatRepository.getMessagePrompt(second.id), isNull);
      },
    );

    test('frozen prompts are batch-read once and reused by OCR', () async {
      await seedAssistant('assistant-1');
      final conversation = await seedConversation('conv-batch');
      final first = await seedUserMessage(
        id: 'u1',
        conversationId: 'conv-batch',
        parts: const [
          TextPart('first'),
          ImagePart(uri: '/tmp/first.png', mime: 'image/png'),
        ],
      );
      final second = await seedUserMessage(
        id: 'u2',
        conversationId: 'conv-batch',
        parts: const [
          TextPart('second'),
          ImagePart(uri: '/tmp/second.png', mime: 'image/png'),
        ],
        messageOrder: 1,
      );
      await chatRepository.putMessagePrompt(
        revisionId: 'u1',
        conversationId: 'conv-batch',
        payload: 'frozen first',
        carriesMemorySnapshot: false,
      );
      await chatRepository.putMessagePrompt(
        revisionId: 'u2',
        conversationId: 'conv-batch',
        payload: 'frozen second',
        carriesMemorySnapshot: false,
      );
      await settings.setProviderConfig(
        'ocr-provider',
        ProviderConfig(
          id: 'ocr-provider',
          enabled: true,
          name: 'OCR',
          apiKey: 'key',
          baseUrl: 'https://example.test',
          models: const ['ocr-model'],
          modelOverrides: const {
            'ocr-model': {
              'input': ['text', 'image'],
            },
          },
        ),
      );
      await settings.setOcrModel('ocr-provider', 'ocr-model');
      await settings.setOcrEnabled(true);

      final countingRepository = _CountingPromptRepository(database);
      var ocrPrefetchCalls = 0;
      final service = buildService(
        messages: [first, second],
        repository: countingRepository,
        ocrPrefetch: ({required revisionIds, required imagePaths}) async {
          ocrPrefetchCalls++;
          return OcrPrepareSession();
        },
      );
      final apiMessages = <Map<String, dynamic>>[
        {
          'role': 'user',
          'content': first.content,
          MessageBuilderService.internalRevisionIdKey: first.id,
        },
        {
          'role': 'user',
          'content': second.content,
          MessageBuilderService.internalRevisionIdKey: second.id,
        },
      ];

      await service.processUserMessagesForApi(
        apiMessages,
        settings,
        assistant,
        conversation: conversation,
        sourceMessages: [first, second],
      );

      expect(apiMessages.map((message) => message['content']), [
        'frozen first',
        'frozen second',
      ]);
      expect(countingRepository.batchPromptReads, 1);
      expect(countingRepository.singlePromptReads, 0);
      expect(ocrPrefetchCalls, 0);
    });

    test(
      'frozen carriesMemorySnapshot splits prefix from the user turn',
      () async {
        await seedAssistant('assistant-1');
        await putEntry(id: 'mem_01', content: 'User likes Flutter.');
        final conversation = await seedConversation('conv-frozen-tag');
        final message = await seedUserMessage(
          id: 'u1',
          conversationId: 'conv-frozen-tag',
          content: 'hello',
        );
        final profileBlock = MemoryBlockBuilder.buildProfileBlock(
          fields: await chatRepository.readProfileFields(),
          lang: MemoryPromptLang.zh,
        );
        final memoryBlock = MemoryBlockBuilder.buildMemoryBlock(
          visible: await chatRepository.queryVisibleMemories(
            assistantId: 'assistant-1',
          ),
          totalByType: await chatRepository.countVisibleMemoriesByType(
            assistantId: 'assistant-1',
          ),
          lang: MemoryPromptLang.zh,
          maxItems: 10,
        );
        final prefix = MemoryBlockBuilder.buildFullSnapshotPrefix(
          profileBlock,
          memoryBlock,
          MemoryPromptLang.zh,
        );
        final payload = '${prefix}hello';
        await chatRepository.putMessagePrompt(
          revisionId: 'u1',
          conversationId: 'conv-frozen-tag',
          payload: payload,
          carriesMemorySnapshot: true,
        );

        await ContextLogger.setEnabled(true);
        addTearDown(() => ContextLogger.setEnabled(false));

        final service = buildService(messages: [message]);
        final apiMessages = <Map<String, dynamic>>[
          {
            'role': 'user',
            'content': 'hello',
            MessageBuilderService.internalRevisionIdKey: 'u1',
          },
        ];
        await service.processUserMessagesForApi(
          apiMessages,
          settings,
          assistant,
          conversation: conversation,
          sourceMessages: [message],
        );

        expect(apiMessages.single['content'], payload);
        final tags = ContextSegmentTags.read(apiMessages.single);
        expect(tags, hasLength(2));
        expect(tags[0]['source'], ContextSource.memorySnapshot.wireName);
        expect(tags[0]['length'], prefix.length);
        expect(tags[0]['meta']?['kind'], 'full');
        expect(tags[1]['source'], ContextSource.chatHistory.wireName);
        expect(tags[1]['length'], 'hello'.length);
      },
    );
  });

  group('superseded snapshots are stripped from history', () {
    test(
      'memories moved to another assistant stop replaying in this one',
      () async {
        // The reported bug: memories were global when this conversation took
        // its snapshot, the user then scoped them to a different assistant, and
        // the frozen snapshot kept handing them back on every later turn.
        await seedAssistant('assistant-1');
        await seedAssistant('assistant-2');
        await putEntry(id: 'mem_01', content: 'User likes Flutter.');

        final conversation = await seedConversation('conv-2');
        final u1 = await seedUserMessage(id: 'u1', conversationId: 'conv-2');
        final assistant2 = assistant.copyWith(id: 'assistant-2');
        final firstTurn = <Map<String, dynamic>>[
          {
            'role': 'user',
            'content': 'hi',
            MessageBuilderService.internalRevisionIdKey: 'u1',
          },
        ];
        await buildService(messages: [u1]).processUserMessagesForApi(
          firstTurn,
          settings,
          assistant2,
          conversation: conversation,
          sourceMessages: [u1],
        );
        expect(firstTurn.single['content'], contains('User likes Flutter.'));

        // Scope the memory to assistant-1 only.
        await putEntry(
          id: 'mem_01',
          content: 'User likes Flutter.',
          scope: MemoryScope.assistant,
          assistantId: 'assistant-1',
        );

        final u2 = await seedUserMessage(
          id: 'u2',
          conversationId: 'conv-2',
          content: 'next',
          messageOrder: 1,
        );
        final secondTurn = <Map<String, dynamic>>[
          {
            'role': 'user',
            'content': 'hi',
            MessageBuilderService.internalRevisionIdKey: 'u1',
          },
          {'role': 'assistant', 'content': 'hello'},
          {
            'role': 'user',
            'content': 'next',
            MessageBuilderService.internalRevisionIdKey: 'u2',
          },
        ];
        await buildService(messages: [u1, u2]).processUserMessagesForApi(
          secondTurn,
          settings,
          assistant2,
          conversation: conversation,
          sourceMessages: [u1, u2],
        );

        final sent = secondTurn.map((m) => m['content'].toString()).join('\n');
        expect(sent, isNot(contains('User likes Flutter.')));
        expect(sent, isNot(contains('<user_profile/>')));
        expect(sent, isNot(contains(MemoryPrompts.introFullZh)));
        expect(secondTurn.first['content'], 'hi');

        // The freeze row still records what was actually sent that turn.
        final frozen = await chatRepository.getMessagePrompt('u1');
        expect(frozen?.payload, contains('User likes Flutter.'));
        expect(frozen?.carriesMemorySnapshot, isTrue);
      },
    );

    test('only the newest snapshot survives into the request', () async {
      await seedAssistant('assistant-1');
      await putEntry(id: 'mem_01', content: 'User likes Flutter.');

      final conversation = await seedConversation('conv-1');
      final u1 = await seedUserMessage(id: 'u1', conversationId: 'conv-1');
      final u2 = await seedUserMessage(
        id: 'u2',
        conversationId: 'conv-1',
        content: 'again',
        messageOrder: 1,
      );
      final u3 = await seedUserMessage(
        id: 'u3',
        conversationId: 'conv-1',
        content: 'third',
        messageOrder: 2,
      );

      final profileBlock = MemoryBlockBuilder.buildProfileBlock(
        fields: await chatRepository.readProfileFields(),
        lang: MemoryPromptLang.zh,
      );
      final memoryBlock = MemoryBlockBuilder.buildMemoryBlock(
        visible: await chatRepository.queryVisibleMemories(
          assistantId: 'assistant-1',
        ),
        totalByType: await chatRepository.countVisibleMemoriesByType(
          assistantId: 'assistant-1',
        ),
        lang: MemoryPromptLang.zh,
        maxItems: 10,
      );
      // u2 carries the snapshot the conversation's hash names; u1 carries an
      // older one that a previous version left frozen in history.
      final stale = MemoryBlockBuilder.buildFullSnapshotPrefix(
        profileBlock,
        '<user_memory type="identity">\n'
        '- [2026-08-01] stale entry\n'
        '</user_memory>\n'
        '<user_memory type="workflow"/>\n'
        '<user_memory type="voice"/>\n'
        '<user_memory type="instruction"/>\n',
        MemoryPromptLang.zh,
      );
      await chatRepository.putMessagePrompt(
        revisionId: 'u1',
        conversationId: 'conv-1',
        payload: '${stale}hi',
        carriesMemorySnapshot: true,
      );
      await chatRepository.putMessagePrompt(
        revisionId: 'u2',
        conversationId: 'conv-1',
        payload:
            '${MemoryBlockBuilder.buildFullSnapshotPrefix(profileBlock, memoryBlock, MemoryPromptLang.zh)}again',
        carriesMemorySnapshot: true,
      );

      final apiMessages = <Map<String, dynamic>>[
        {
          'role': 'user',
          'content': 'hi',
          MessageBuilderService.internalRevisionIdKey: 'u1',
        },
        {
          'role': 'user',
          'content': 'again',
          MessageBuilderService.internalRevisionIdKey: 'u2',
        },
        {
          'role': 'user',
          'content': 'third',
          MessageBuilderService.internalRevisionIdKey: 'u3',
        },
      ];
      await buildService(messages: [u1, u2, u3]).processUserMessagesForApi(
        apiMessages,
        settings,
        assistant,
        conversation: conversation,
        sourceMessages: [u1, u2, u3],
      );

      expect(apiMessages[0]['content'], 'hi');
      expect(apiMessages[1]['content'], contains('User likes Flutter.'));
      expect(apiMessages[2]['content'], 'third');
      final sent = apiMessages.map((m) => m['content'].toString()).join('\n');
      expect(sent, isNot(contains('stale entry')));
    });
  });

  for (final previewOnly in [false, true]) {
    for (final followUp in [false, true]) {
      test('native PDF mode retains current memory after two frozen PDFs '
          '(preview=$previewOnly, followUp=$followUp)', () async {
        await seedAssistant(assistant.id);
        await putEntry(id: 'mem_pdf', content: 'Memory before the update.');
        final conversation = await seedConversation('pdf-memory');
        final directory = await Directory.systemTemp.createTemp('pdf_memory_');
        addTearDown(() => directory.delete(recursive: true));
        final document = PdfDocument();
        document.pages.add().graphics.drawString(
          'Extracted PDF contents',
          PdfStandardFont(PdfFontFamily.helvetica, 12),
        );
        final bytes = await document.save();
        document.dispose();

        Future<ChatMessage> pdfMessage(String id) async {
          final file = File('${directory.path}/$id.pdf');
          await file.writeAsBytes(bytes);
          return seedUserMessage(
            id: id,
            conversationId: conversation.id,
            content: id,
            parts: [
              TextPart(id),
              FilePart(
                uri: file.path,
                name: '$id.pdf',
                mime: 'application/pdf',
              ),
            ],
          );
        }

        Future<List<Map<String, dynamic>>> assemble(
          List<ChatMessage> messages, {
          bool nativePdfInput = false,
          bool preview = false,
        }) async {
          final service = buildService(messages: messages);
          final apiMessages = service.buildApiMessages(
            messages: messages,
            versionSelections: const {},
            currentConversation: conversation,
          );
          await service.processUserMessagesForApi(
            apiMessages,
            settings,
            assistant,
            conversation: conversation,
            sourceMessages: messages,
            nativePdfInput: nativePdfInput,
            previewOnly: preview,
          );
          return apiMessages;
        }

        final first = await pdfMessage('pdf-first');
        await assemble([first]);
        final frozenFirst = (await chatRepository.getMessagePrompt(first.id))!;
        expect(frozenFirst.payload, contains('Memory before the update.'));
        expect(frozenFirst.payload, contains('Extracted PDF contents'));

        await putEntry(id: 'mem_pdf', content: 'Memory after the update.');
        final second = await pdfMessage('pdf-second');
        await assemble([first, second]);
        final frozenSecond = (await chatRepository.getMessagePrompt(
          second.id,
        ))!;
        expect(frozenSecond.payload, contains('Memory after the update.'));
        expect(frozenFirst.carriesMemorySnapshot, isTrue);
        expect(frozenSecond.carriesMemorySnapshot, isTrue);

        var apiMessages = await assemble(
          [first, second],
          nativePdfInput: true,
          preview: previewOnly,
        );
        if (followUp) {
          final next = await seedUserMessage(
            id: 'pdf-follow-up',
            conversationId: conversation.id,
            content: 'ordinary follow-up',
          );
          apiMessages = await assemble(
            [first, second, next],
            nativePdfInput: true,
            preview: previewOnly,
          );
        }
        final sent = apiMessages.map((m) => m['content']).join('\n');
        expect(sent, contains('Memory after the update.'));
        expect(sent, isNot(contains('Memory before the update.')));
        expect(sent, isNot(contains('Extracted PDF contents')));
        expect(MemoryPrompts.introFullZh.allMatches(sent), hasLength(1));
        expect(
          (await chatRepository.getMessagePrompt(first.id))!.payload,
          frozenFirst.payload,
        );
        expect(
          (await chatRepository.getMessagePrompt(second.id))!.payload,
          frozenSecond.payload,
        );
        if (previewOnly && followUp) {
          expect(
            await chatRepository.getMessagePrompt('pdf-follow-up'),
            isNull,
          );
        }
        final extractedAgain = (await assemble([
          first,
          second,
        ])).map((m) => m['content']).join('\n');
        expect(extractedAgain, contains('Extracted PDF contents'));
        expect(extractedAgain, contains('Memory after the update.'));
        expect(extractedAgain, isNot(contains('Memory before the update.')));
        expect(
          MemoryPrompts.introFullZh.allMatches(extractedAgain),
          hasLength(1),
        );
      });
    }
  }

  group('regeneration and forged snapshots', () {
    // Snapshot + hash for whatever [assistantId] can currently see.
    Future<({String prefix, String hash})> currentSnapshot(
      String assistantId,
    ) async {
      final profileBlock = MemoryBlockBuilder.buildProfileBlock(
        fields: await chatRepository.readProfileFields(),
        lang: MemoryPromptLang.zh,
      );
      final memoryBlock = MemoryBlockBuilder.buildMemoryBlock(
        visible: await chatRepository.queryVisibleMemories(
          assistantId: assistantId,
        ),
        totalByType: await chatRepository.countVisibleMemoriesByType(
          assistantId: assistantId,
        ),
        lang: MemoryPromptLang.zh,
        maxItems: 10,
      );
      return (
        prefix: MemoryBlockBuilder.buildFullSnapshotPrefix(
          profileBlock,
          memoryBlock,
          MemoryPromptLang.zh,
        ),
        hash: MemoryBlockBuilder.hashBlocks(profileBlock, memoryBlock),
      );
    }

    test(
      'native PDF mode keeps and refreshes an ordinary frozen snapshot',
      () async {
        await seedAssistant(assistant.id);
        await putEntry(id: 'mem_pdf', content: 'Memory before the update.');
        final conversation = await seedConversation('mixed-pdf-memory');
        final ordinary = await seedUserMessage(
          id: 'ordinary',
          conversationId: conversation.id,
        );
        final firstSnapshot = await currentSnapshot(assistant.id);
        final frozenOrdinary = '${firstSnapshot.prefix}hi';
        await chatRepository.putMessagePrompt(
          revisionId: ordinary.id,
          conversationId: conversation.id,
          payload: frozenOrdinary,
          carriesMemorySnapshot: true,
        );

        await putEntry(id: 'mem_pdf', content: 'Memory after the update.');
        final pdf = await seedUserMessage(
          id: 'pdf',
          conversationId: conversation.id,
          content: 'PDF question',
          parts: const [
            TextPart('PDF question'),
            FilePart(
              uri: '/report.pdf',
              name: 'report.pdf',
              mime: 'application/pdf',
            ),
          ],
        );
        final latestSnapshot = await currentSnapshot(assistant.id);
        await chatRepository.putMessagePrompt(
          revisionId: pdf.id,
          conversationId: conversation.id,
          payload: '${latestSnapshot.prefix}Extracted PDF contents',
          carriesMemorySnapshot: true,
        );
        final service = buildService(messages: [ordinary, pdf]);
        final apiMessages = service.buildApiMessages(
          messages: [ordinary, pdf],
          versionSelections: const {},
          currentConversation: conversation,
        );
        await service.processUserMessagesForApi(
          apiMessages,
          settings,
          assistant,
          conversation: conversation,
          sourceMessages: [ordinary, pdf],
          nativePdfInput: true,
        );
        // The ordinary message is a stale carrier now, so this request drops
        // its prefix; the fresh snapshot goes to the last user message, which
        // native PDF mode never freezes. Refreshing the older message instead
        // would put the rewrite point back in the middle of the history.
        expect(apiMessages[0]['content'], 'hi');
        expect(
          apiMessages[1]['content'],
          '${latestSnapshot.prefix}PDF question',
        );
        expect(
          (await chatRepository.getMessagePrompt(ordinary.id))!.payload,
          frozenOrdinary,
        );
      },
    );

    test(
      'regenerating after a scope change drops the stale snapshot',
      () async {
        // Regeneration adds no user message, so nothing calls
        // resolveMemoryPrefix and the stored hash alone cannot say whether the
        // frozen snapshot is still accurate.
        await seedAssistant('assistant-1');
        await seedAssistant('assistant-2');
        await putEntry(id: 'mem_01', content: 'User likes Flutter.');
        final conversation = await seedConversation('conv-2');
        final u1 = await seedUserMessage(id: 'u1', conversationId: 'conv-2');
        final snapshot = await currentSnapshot('assistant-2');
        await chatRepository.putMessagePrompt(
          revisionId: 'u1',
          conversationId: 'conv-2',
          payload: '${snapshot.prefix}hi',
          carriesMemorySnapshot: true,
        );

        await putEntry(
          id: 'mem_01',
          content: 'User likes Flutter.',
          scope: MemoryScope.assistant,
          assistantId: 'assistant-1',
        );

        final apiMessages = <Map<String, dynamic>>[
          {
            'role': 'user',
            'content': 'hi',
            MessageBuilderService.internalRevisionIdKey: 'u1',
          },
        ];
        await buildService(messages: [u1]).processUserMessagesForApi(
          apiMessages,
          settings,
          assistant.copyWith(id: 'assistant-2'),
          conversation: conversation,
          sourceMessages: [u1],
        );

        expect(apiMessages.single['content'], 'hi');
      },
    );

    test('regenerating after a memory is added refreshes in place', () async {
      // Stripping instead of refreshing would hand the regenerated reply no
      // memory at all, which the automatic memory pipeline would trigger
      // constantly.
      await seedAssistant('assistant-1');
      await putEntry(id: 'mem_01', content: 'User likes Flutter.');
      final conversation = await seedConversation('conv-1');
      final u1 = await seedUserMessage(id: 'u1', conversationId: 'conv-1');
      final snapshot = await currentSnapshot('assistant-1');
      await chatRepository.putMessagePrompt(
        revisionId: 'u1',
        conversationId: 'conv-1',
        payload: '${snapshot.prefix}hi',
        carriesMemorySnapshot: true,
      );

      await putEntry(id: 'mem_02', content: 'User ships on Fridays.');

      final apiMessages = <Map<String, dynamic>>[
        {
          'role': 'user',
          'content': 'hi',
          MessageBuilderService.internalRevisionIdKey: 'u1',
        },
      ];
      await buildService(messages: [u1]).processUserMessagesForApi(
        apiMessages,
        settings,
        assistant,
        conversation: conversation,
        sourceMessages: [u1],
      );

      final sent = apiMessages.single['content'].toString();
      expect(sent, contains('User likes Flutter.'));
      expect(sent, contains('User ships on Fridays.'));
      expect(sent, endsWith('hi'));
      // Ephemeral: only the request is refreshed. The freeze row keeps the
      // snapshot it actually sent, so the next turn re-derives the same bytes.
      expect(
        (await chatRepository.getMessagePrompt('u1'))?.payload,
        '${snapshot.prefix}hi',
      );
    });

    test(
      'regenerating an earlier reply refreshes that turn\'s snapshot',
      () async {
        // Regeneration cuts the later messages out of the request, so the
        // conversation's stored hash — which names the snapshot the *newest*
        // message carries — says nothing about the one that survives here.
        await seedAssistant('assistant-1');
        await seedAssistant('assistant-2');
        await putEntry(id: 'mem_01', content: 'User likes Flutter.');
        final conversation = await seedConversation('conv-1');
        final u1 = await seedUserMessage(id: 'u1', conversationId: 'conv-1');
        final u2 = await seedUserMessage(
          id: 'u2',
          conversationId: 'conv-1',
          content: 'again',
          messageOrder: 1,
        );

        // u1 froze snapshot A, back when the memory was global.
        final snapshotA = await currentSnapshot('assistant-1');
        await chatRepository.putMessagePrompt(
          revisionId: 'u1',
          conversationId: 'conv-1',
          payload: '${snapshotA.prefix}hi',
          carriesMemorySnapshot: true,
        );

        // The memory moves to another assistant, then u2 froze snapshot B and
        // advanced the conversation hash to it.
        await putEntry(
          id: 'mem_01',
          content: 'User likes Flutter.',
          scope: MemoryScope.assistant,
          assistantId: 'assistant-2',
        );
        final snapshotB = await currentSnapshot('assistant-1');
        await chatRepository.putMessagePrompt(
          revisionId: 'u2',
          conversationId: 'conv-1',
          payload: '${snapshotB.prefix}again',
          carriesMemorySnapshot: true,
        );

        // Regenerating the reply after u1 leaves u2 out of the request.
        final apiMessages = <Map<String, dynamic>>[
          {
            'role': 'user',
            'content': 'hi',
            MessageBuilderService.internalRevisionIdKey: 'u1',
          },
        ];
        await buildService(messages: [u1, u2]).processUserMessagesForApi(
          apiMessages,
          settings,
          assistant,
          conversation: conversation,
          sourceMessages: [u1, u2],
        );

        final sent = apiMessages.single['content'].toString();
        expect(sent, isNot(contains('User likes Flutter.')));
        expect(sent, 'hi');
      },
    );

    test(
      'a stale carrier is overridden at the tail, not refreshed in place',
      () async {
        // The only frozen message in this request holds a snapshot from before
        // the last memory change. Overwriting it in place would move the
        // rewrite point back to where it sits; the fresh snapshot goes to the
        // last user message instead, and the row keeps what it actually sent.
        await seedAssistant('assistant-1');
        await putEntry(id: 'mem_01', content: 'User likes Flutter.');
        final conversation = await seedConversation('conv-1');
        final u1 = await seedUserMessage(id: 'u1', conversationId: 'conv-1');
        final u2 = await seedUserMessage(
          id: 'u2',
          conversationId: 'conv-1',
          content: 'again',
          messageOrder: 1,
        );
        final stale = MemoryBlockBuilder.buildFullSnapshotPrefix(
          MemoryBlockBuilder.buildProfileBlock(
            fields: const [],
            lang: MemoryPromptLang.zh,
          ),
          '<user_memory type="identity">\n'
          '- [2026-08-01] stale entry\n'
          '</user_memory>\n'
          '<user_memory type="workflow"/>\n'
          '<user_memory type="voice"/>\n'
          '<user_memory type="instruction"/>\n',
          MemoryPromptLang.zh,
        );
        await chatRepository.putMessagePrompt(
          revisionId: 'u2',
          conversationId: 'conv-1',
          payload: '${stale}again',
          carriesMemorySnapshot: true,
        );

        final apiMessages = <Map<String, dynamic>>[
          {
            'role': 'user',
            'content': 'hi',
            MessageBuilderService.internalRevisionIdKey: 'u1',
          },
          {'role': 'assistant', 'content': 'hello'},
          {
            'role': 'user',
            'content': 'again',
            MessageBuilderService.internalRevisionIdKey: 'u2',
          },
        ];
        await buildService(messages: [u1, u2]).processUserMessagesForApi(
          apiMessages,
          settings,
          assistant,
          conversation: conversation,
          sourceMessages: [u1, u2],
        );

        expect(apiMessages[0]['content'], 'hi');
        expect(
          apiMessages[2]['content'],
          startsWith(MemoryPrompts.introFullZh),
        );
        expect(apiMessages[2]['content'], contains('User likes Flutter.'));
        expect(apiMessages[2]['content'], endsWith('again'));
        final sent = apiMessages.map((m) => m['content'].toString()).join('\n');
        expect(sent, isNot(contains('stale entry')));
        expect(
          (await chatRepository.getMessagePrompt('u2'))!.payload,
          '${stale}again',
        );
      },
    );

    test('user text that looks like a snapshot is left alone', () async {
      // Format alone must not decide: a user pasting a snapshot out of the
      // context log would otherwise lose the head of their own message.
      await seedAssistant('assistant-1');
      await putEntry(id: 'mem_01', content: 'User likes Flutter.');
      final conversation = await seedConversation('conv-1');
      final u1 = await seedUserMessage(id: 'u1', conversationId: 'conv-1');
      final u2 = await seedUserMessage(
        id: 'u2',
        conversationId: 'conv-1',
        content: 'again',
        messageOrder: 1,
      );
      final snapshot = await currentSnapshot('assistant-1');
      final pasted = '${snapshot.prefix}why is this in my prompt?';
      await chatRepository.putMessagePrompt(
        revisionId: 'u1',
        conversationId: 'conv-1',
        payload: pasted,
        carriesMemorySnapshot: false,
      );
      await chatRepository.putMessagePrompt(
        revisionId: 'u2',
        conversationId: 'conv-1',
        payload: '${snapshot.prefix}again',
        carriesMemorySnapshot: true,
      );

      final apiMessages = <Map<String, dynamic>>[
        {
          'role': 'user',
          'content': 'hi',
          MessageBuilderService.internalRevisionIdKey: 'u1',
        },
        {
          'role': 'user',
          'content': 'again',
          MessageBuilderService.internalRevisionIdKey: 'u2',
        },
      ];
      await buildService(messages: [u1, u2]).processUserMessagesForApi(
        apiMessages,
        settings,
        assistant,
        conversation: conversation,
        sourceMessages: [u1, u2],
      );

      expect(apiMessages[0]['content'], pasted);
      expect(apiMessages[1]['content'], '${snapshot.prefix}again');
    });
  });

  group('§18.4 item 30 — self-heal after truncateIndex advances', () {
    test(
      'dropping the carrier out of the request yields a full snapshot again',
      () async {
        await seedAssistant('assistant-1');
        await putEntry(id: 'mem_01', content: 'User likes Flutter.');

        final conversation = await seedConversation('conv-1');
        final u1 = await seedUserMessage(id: 'u1', conversationId: 'conv-1');
        final u2 = await seedUserMessage(
          id: 'u2',
          conversationId: 'conv-1',
          content: 'again',
          messageOrder: 1,
        );
        final u3 = await seedUserMessage(
          id: 'u3',
          conversationId: 'conv-1',
          content: 'after truncate',
          messageOrder: 2,
        );
        final service = buildService(messages: [u1, u2, u3]);

        Future<List<Map<String, dynamic>>> turn(
          List<ChatMessage> messages,
        ) async {
          final api = <Map<String, dynamic>>[
            for (final message in messages)
              {
                'role': 'user',
                'content': message.content,
                MessageBuilderService.internalRevisionIdKey: message.id,
              },
          ];
          await service.processUserMessagesForApi(
            api,
            settings,
            assistant,
            conversation: conversation,
            sourceMessages: messages,
          );
          return api;
        }

        // First turn: no recorded carrier → the snapshot lands on u1, which is
        // also the last message of this request.
        final first = await turn([u1]);
        expect(first.single['content'], startsWith(MemoryPrompts.introFullZh));

        // Unchanged memory: the record still holds, so u2 gets nothing.
        final same = await turn([u1, u2]);
        expect(same[0]['content'], startsWith(MemoryPrompts.introFullZh));
        expect(same[1]['content'], 'again');

        // truncateIndex advanced and u1 left the request: the record is now
        // outside it, so the snapshot has to be sent again — on u3.
        final healed = await turn([u3]);
        expect(healed.single['content'], startsWith(MemoryPrompts.introFullZh));
        expect(
          healed.single['content'],
          isNot(contains('<user_memory_update>')),
        );
      },
    );
  });

  group('§11.1 system message stability', () {
    test(
      'system message is byte-identical before and after a memory is created',
      () async {
        await seedAssistant('assistant-1');
        final service = buildService();
        final apiBefore = <Map<String, dynamic>>[
          {'role': 'system', 'content': 'base system'},
        ];
        await service.injectMemoryAndRecentChats(
          apiBefore,
          assistant.copyWith(allowPastConversationRecall: true),
          settings: settings,
        );
        final before = (apiBefore.first['content'] ?? '').toString();

        await putEntry(id: 'mem_01', content: 'Brand new memory.');

        final apiAfter = <Map<String, dynamic>>[
          {'role': 'system', 'content': 'base system'},
        ];
        await service.injectMemoryAndRecentChats(
          apiAfter,
          assistant.copyWith(allowPastConversationRecall: true),
          settings: settings,
        );
        final after = (apiAfter.first['content'] ?? '').toString();

        expect(after, before);
        expect(before, contains('## 长期记忆'));
        expect(before, contains(MemoryPrompts.rulesPastConversationRecallZh));
        expect(before, isNot(contains('<memories>')));
        expect(before, isNot(contains('<recent_chats>')));
        expect(before, isNot(contains('当前时间是')));
      },
    );

    test(
      'recall rules ship without memory rules when only recall is on',
      () async {
        // chat_search is registered on allowPastConversationRecall alone, so its
        // usage rules cannot ride along with the long-term memory rules or the
        // tool reaches the model with no instructions at all.
        await seedAssistant('assistant-1');
        final api = <Map<String, dynamic>>[
          {'role': 'system', 'content': 'base system'},
        ];
        await buildService().injectMemoryAndRecentChats(
          api,
          assistant.copyWith(
            enableMemory: false,
            allowPastConversationRecall: true,
          ),
          settings: settings,
        );

        final content = (api.first['content'] ?? '').toString();
        expect(content, contains(MemoryPrompts.rulesPastConversationRecallZh));
        expect(content, isNot(contains('## 长期记忆')));
      },
    );

    test('neither gate injects nothing', () async {
      await seedAssistant('assistant-1');
      final api = <Map<String, dynamic>>[
        {'role': 'system', 'content': 'base system'},
      ];
      await buildService().injectMemoryAndRecentChats(
        api,
        assistant.copyWith(
          enableMemory: false,
          allowPastConversationRecall: false,
        ),
        settings: settings,
      );
      expect(api.first['content'], 'base system');
    });
  });
}
