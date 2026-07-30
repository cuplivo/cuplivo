import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/director_session.dart';
import 'package:Cuplivo/core/models/group_chat.dart';
import 'package:Cuplivo/core/models/group_chat_member.dart';
import 'package:Cuplivo/core/models/group_chat_message.dart';
import 'package:Cuplivo/core/models/group_chat_settings.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';
import 'package:Cuplivo/core/services/chat/group_chat_service.dart';
import 'package:Cuplivo/core/services/group_chat/director_prompt_builder.dart';
import 'package:Cuplivo/core/services/group_chat/director_tool_service.dart';
import 'package:Cuplivo/core/services/group_chat/group_chat_orchestrator.dart';

Future<GroupMemberGenerationPreparation> _prepareFakeMemberGeneration({
  required String groupId,
  required List<GroupChatMessage> timeline,
  required Assistant assistant,
  required Map<String, String> assistantNames,
  required String providerKey,
  required String modelId,
  required SettingsProvider settings,
}) async {
  return GroupMemberGenerationPreparation(
    apiMessages: timeline
        .map(
          (message) => <String, dynamic>{
            'role': message.role,
            'content': message.content,
          },
        )
        .toList(growable: false),
    toolDefs: const <Map<String, dynamic>>[],
    onToolCall: null,
    userMediaPaths: const <String>[],
  );
}

Future<GroupChatMessage> _runFakeMemberStream({
  required GroupChatMessage placeholder,
  required Assistant assistant,
  required SettingsProvider settings,
  required String providerKey,
  required String modelId,
  required GroupMemberGenerationPreparation prepared,
  required GroupChatStreamFactory sendMessageStream,
  required bool Function() isCancelled,
}) async {
  final content = StringBuffer();
  var tokens = 0;
  await for (final chunk in sendMessageStream(
    GroupChatStreamRequest(
      config: settings.getProviderConfig(providerKey),
      modelId: modelId,
      messages: prepared.apiMessages,
      tools: prepared.toolDefs.isEmpty ? null : prepared.toolDefs,
      onToolCall: prepared.onToolCall,
      requestId: placeholder.id,
    ),
  )) {
    if (isCancelled()) throw StateError('cancelled');
    content.write(chunk.content);
    if (chunk.totalTokens > 0) tokens = chunk.totalTokens;
  }
  return placeholder.copyWith(
    content: content.toString(),
    totalTokens: tokens,
    isStreaming: false,
  );
}

void main() {
  group('DirectorToolService', () {
    test('parses select_speaker and end_round', () {
      final select = DirectorToolService.parseToolCall('select_speaker', {
        'assistant_id': 'aid-1',
        'reason': 'knows topic',
      });
      expect(select, isNotNull);
      expect(select!.isSelectSpeaker, isTrue);
      expect(select.assistantId, 'aid-1');
      expect(select.endRound, isFalse);

      final end = DirectorToolService.parseToolCall('end_round', {
        'reason': 'done',
      });
      expect(end, isNotNull);
      expect(end!.endRound, isTrue);
      expect(end.assistantId, isNull);
    });

    test('handler records first decision only', () async {
      final svc = DirectorToolService();
      final handler = svc.buildHandler(allowedAssistantIds: {'a1', 'a2'});
      final r1 = await handler('select_speaker', {'assistant_id': 'a1'});
      expect(r1.contains('true'), isTrue);
      expect(svc.lastDecision?.assistantId, 'a1');

      final r2 = await handler('end_round', {});
      expect(r2.contains('ignored'), isTrue);
      expect(svc.lastDecision?.endRound, isFalse);
      expect(svc.decisions.length, 1);
    });

    test('rejects assistant not in group', () async {
      final svc = DirectorToolService();
      final handler = svc.buildHandler(allowedAssistantIds: {'a1'});
      final r = await handler('select_speaker', {'assistant_id': 'zzz'});
      expect(r.contains('assistant_not_in_group'), isTrue);
      expect(svc.lastDecision, isNull);
    });

    test('tool definitions include both tools', () {
      final defs = DirectorToolService.toolDefinitions(
        allowedAssistantIds: ['a', 'b'],
      );
      final names = defs.map((d) => (d['function'] as Map)['name']).toList();
      expect(names, containsAll(['select_speaker', 'end_round']));
    });
  });

  group('modelSupportsToolCalling', () {
    test('honors modelOverrides abilities', () {
      final withTool = ProviderConfig(
        id: 'P',
        enabled: true,
        name: 'P',
        apiKey: 'k',
        baseUrl: 'https://example.com',
        modelOverrides: {
          'gpt-tool': {
            'abilities': ['tool', 'reasoning'],
          },
        },
      );
      final noTool = ProviderConfig(
        id: 'P',
        enabled: true,
        name: 'P',
        apiKey: 'k',
        baseUrl: 'https://example.com',
        modelOverrides: {
          'plain': {
            'abilities': ['reasoning'],
          },
        },
      );

      expect(
        modelSupportsToolCalling(config: withTool, modelId: 'gpt-tool'),
        isTrue,
      );
      expect(
        modelSupportsToolCalling(config: noTool, modelId: 'plain'),
        isFalse,
      );
    });

    test('override map without abilities falls through to infer', () {
      final cfg = ProviderConfig(
        id: 'P',
        enabled: true,
        name: 'P',
        apiKey: 'k',
        baseUrl: 'https://example.com',
        modelOverrides: {
          'gpt-4o-mini': {'temperature': 0.5},
        },
      );
      expect(
        modelSupportsToolCalling(config: cfg, modelId: 'gpt-4o-mini'),
        isTrue,
      );
    });

    test('empty model id is false', () {
      final cfg = ProviderConfig(
        id: 'P',
        enabled: true,
        name: 'P',
        apiKey: 'k',
        baseUrl: 'https://example.com',
      );
      expect(modelSupportsToolCalling(config: cfg, modelId: ''), isFalse);
    });
  });

  group('directorForcedToolChoiceExtraBody', () {
    test('openai uses required', () {
      final cfg = ProviderConfig(
        id: 'OpenAI',
        enabled: true,
        name: 'OpenAI',
        apiKey: 'k',
        baseUrl: 'https://api.openai.com/v1',
      );
      final body = directorForcedToolChoiceExtraBody(cfg);
      expect(body['tool_choice'], 'required');
    });

    test('claude uses type any', () {
      final cfg = ProviderConfig(
        id: 'Anthropic',
        enabled: true,
        name: 'Claude',
        apiKey: 'k',
        baseUrl: 'https://api.anthropic.com',
        providerType: ProviderKind.claude,
      );
      final body = directorForcedToolChoiceExtraBody(cfg);
      expect(body['tool_choice'], isA<Map>());
      expect((body['tool_choice'] as Map)['type'], 'any');
    });
  });

  group('GroupChatRoundPolicy', () {
    test('max assistant messages per user turn', () {
      expect(GroupChatRoundPolicy.canSpeakMore(count: 0, max: 6), isTrue);
      expect(GroupChatRoundPolicy.canSpeakMore(count: 5, max: 6), isTrue);
      expect(GroupChatRoundPolicy.canSpeakMore(count: 6, max: 6), isFalse);
      expect(GroupChatRoundPolicy.canSpeakMore(count: 0, max: 0), isFalse);
    });

    test('consecutive speaker rule', () {
      expect(
        GroupChatRoundPolicy.allowsSpeaker(
          allowSameAssistantConsecutive: true,
          lastSpeakerId: 'a',
          nextAssistantId: 'a',
        ),
        isTrue,
      );
      expect(
        GroupChatRoundPolicy.allowsSpeaker(
          allowSameAssistantConsecutive: false,
          lastSpeakerId: 'a',
          nextAssistantId: 'a',
        ),
        isFalse,
      );
      expect(
        GroupChatRoundPolicy.allowsSpeaker(
          allowSameAssistantConsecutive: false,
          lastSpeakerId: 'a',
          nextAssistantId: 'b',
        ),
        isTrue,
      );
    });
  });

  group('DirectorPromptBuilder', () {
    test('default system prompt used when empty custom', () {
      expect(
        DirectorPromptBuilder.resolveSystemPrompt(GroupChatSettings.defaults),
        DirectorPromptBuilder.defaultSystemPrompt,
      );
      expect(
        DirectorPromptBuilder.resolveSystemPrompt(
          const GroupChatSettings(directorSystemPrompt: 'custom'),
        ),
        'custom',
      );
    });

    test('initial messages include members and user text', () {
      final msgs = DirectorPromptBuilder.buildInitialMessages(
        systemPrompt: 'SYS',
        members: const [
          DirectorMemberIntro(
            assistantId: 'a1',
            name: 'Alice',
            systemPrompt: 'be helpful',
          ),
        ],
        userMessage: 'Hello group',
      );
      expect(msgs.first['role'], 'system');
      expect(msgs.last['role'], 'user');
      final body = msgs.last['content'] as String;
      expect(body, contains('a1'));
      expect(body, contains('Alice'));
      expect(body, contains('be helpful'));
      expect(body, contains('Hello group'));
      expect(body, contains('select_speaker'));
    });
  });

  group('GroupChatOrchestrator end_round / max with fake stream', () {
    late _MemoryGroupChatService mem;
    late Map<String, Assistant> assistants;
    late _FakeSettings settings;

    setUp(() {
      mem = _MemoryGroupChatService();
      assistants = {
        'a1': Assistant(
          id: 'a1',
          name: 'Alice',
          systemPrompt: 'A',
          chatModelProvider: 'P',
          chatModelId: 'm1',
        ),
        'a2': Assistant(
          id: 'a2',
          name: 'Bob',
          systemPrompt: 'B',
          chatModelProvider: 'P',
          chatModelId: 'm1',
        ),
      };
      settings = _FakeSettings(
        providerKey: 'P',
        modelId: 'tool-model',
        config: ProviderConfig(
          id: 'P',
          enabled: true,
          name: 'P',
          apiKey: 'k',
          baseUrl: 'https://example.com',
          modelOverrides: {
            'tool-model': {
              'abilities': ['tool'],
            },
            'm1': {
              'abilities': ['tool'],
            },
          },
        ),
      );
    });

    test(
      'end_round stops without member messages when director ends first',
      () async {
        final group = await mem.createGroup(
          title: 'T',
          assistantIds: ['a1', 'a2'],
          settings: const GroupChatSettings(
            directorModelProvider: 'P',
            directorModelId: 'tool-model',
            maxAssistantMessagesPerUserTurn: 6,
          ),
        );

        final orch = GroupChatOrchestrator(
          groupChatService: mem,
          resolveAssistant: (id) => assistants[id],
          resolveSettings: () => settings,
          prepareMemberGeneration: _prepareFakeMemberGeneration,
          runMemberStream: _runFakeMemberStream,
          sendMessageStream: (req) async* {
            if (req.tools != null && req.tools!.isNotEmpty) {
              final handler = req.onToolCall;
              if (handler != null) {
                await handler('end_round', {'reason': 'enough'});
              }
              yield ChatStreamChunk(content: '', isDone: true, totalTokens: 0);
              return;
            }
            yield ChatStreamChunk(
              content: 'should not speak',
              isDone: true,
              totalTokens: 1,
            );
          },
        );

        final result = await orch.sendUserMessage(
          groupId: group.id,
          content: 'Hi',
        );
        expect(result.endedBy, 'end_round');
        expect(result.assistantMessages, isEmpty);
        final timeline = await mem.getMessages(group.id);
        expect(timeline.where((m) => m.role == 'user').length, 1);
        expect(timeline.where((m) => m.role == 'assistant'), isEmpty);
      },
    );

    test(
      'maxAssistantMessagesPerUserTurn stops after N member replies',
      () async {
        final group = await mem.createGroup(
          title: 'T',
          assistantIds: ['a1', 'a2'],
          settings: const GroupChatSettings(
            directorModelProvider: 'P',
            directorModelId: 'tool-model',
            maxAssistantMessagesPerUserTurn: 2,
          ),
        );

        var directorCalls = 0;
        final orch = GroupChatOrchestrator(
          groupChatService: mem,
          resolveAssistant: (id) => assistants[id],
          resolveSettings: () => settings,
          prepareMemberGeneration: _prepareFakeMemberGeneration,
          runMemberStream: _runFakeMemberStream,
          sendMessageStream: (req) async* {
            if (req.tools != null && req.tools!.isNotEmpty) {
              directorCalls += 1;
              final pick = directorCalls.isOdd ? 'a1' : 'a2';
              final handler = req.onToolCall;
              if (handler != null) {
                await handler('select_speaker', {'assistant_id': pick});
              }
              yield ChatStreamChunk(content: '', isDone: true, totalTokens: 0);
              return;
            }
            yield ChatStreamChunk(
              content: 'reply-$directorCalls',
              isDone: true,
              totalTokens: 3,
            );
          },
        );

        final result = await orch.sendUserMessage(
          groupId: group.id,
          content: 'Go',
        );
        expect(result.endedBy, 'max_messages');
        expect(result.assistantMessages.length, 2);
        final timeline = await mem.getMessages(group.id);
        expect(timeline.where((m) => m.role == 'assistant').length, 2);
      },
    );

    test('rejects director model without tool ability', () async {
      settings = _FakeSettings(
        providerKey: 'P',
        modelId: 'plain',
        config: ProviderConfig(
          id: 'P',
          enabled: true,
          name: 'P',
          apiKey: 'k',
          baseUrl: 'https://example.com',
          modelOverrides: {
            'plain': {
              'abilities': ['reasoning'],
            },
          },
        ),
      );

      final group = await mem.createGroup(
        title: 'T',
        assistantIds: ['a1', 'a2'],
        settings: const GroupChatSettings(
          directorModelProvider: 'P',
          directorModelId: 'plain',
        ),
      );

      final orch = GroupChatOrchestrator(
        groupChatService: mem,
        resolveAssistant: (id) => assistants[id],
        resolveSettings: () => settings,
        prepareMemberGeneration: _prepareFakeMemberGeneration,
        runMemberStream: _runFakeMemberStream,
        sendMessageStream: (req) async* {
          yield ChatStreamChunk(content: '', isDone: true, totalTokens: 0);
        },
      );

      await expectLater(
        orch.sendUserMessage(groupId: group.id, content: 'Hi'),
        throwsA(
          isA<GroupChatOrchestratorException>().having(
            (e) => e.code,
            'code',
            GroupChatErrorCode.directorModelNoTools,
          ),
        ),
      );
    });

    test(
      'directorNoDecision returns TurnResult (no throw) and keeps user msg',
      () async {
        final group = await mem.createGroup(
          title: 'T',
          assistantIds: ['a1', 'a2'],
          settings: const GroupChatSettings(
            directorModelProvider: 'P',
            directorModelId: 'tool-model',
            maxAssistantMessagesPerUserTurn: 6,
          ),
        );

        final orch = GroupChatOrchestrator(
          groupChatService: mem,
          resolveAssistant: (id) => assistants[id],
          resolveSettings: () => settings,
          prepareMemberGeneration: _prepareFakeMemberGeneration,
          runMemberStream: _runFakeMemberStream,
          sendMessageStream: (req) async* {
            // Director stream finishes without calling tools.
            yield ChatStreamChunk(
              content: 'I will not call tools',
              isDone: true,
              totalTokens: 1,
            );
          },
        );

        final result = await orch.sendUserMessage(
          groupId: group.id,
          content: '你们好',
        );
        expect(result.isSuccess, isFalse);
        expect(result.errorCode, GroupChatErrorCode.directorNoDecision);
        expect(result.endedBy, 'error');
        expect(result.assistantMessages, isEmpty);
        final timeline = await mem.getMessages(group.id);
        expect(timeline.where((m) => m.role == 'user').length, 1);
        expect(timeline.where((m) => m.role == 'assistant'), isEmpty);
      },
    );

    test('director stream cancel after tool decision still succeeds', () async {
      final group = await mem.createGroup(
        title: 'T',
        assistantIds: ['a1', 'a2'],
        settings: const GroupChatSettings(
          directorModelProvider: 'P',
          directorModelId: 'tool-model',
          maxAssistantMessagesPerUserTurn: 1,
        ),
      );

      var directorCalls = 0;
      final orch = GroupChatOrchestrator(
        groupChatService: mem,
        resolveAssistant: (id) => assistants[id],
        resolveSettings: () => settings,
        prepareMemberGeneration: _prepareFakeMemberGeneration,
        runMemberStream: _runFakeMemberStream,
        sendMessageStream: (req) async* {
          if (req.tools != null && req.tools!.isNotEmpty) {
            directorCalls += 1;
            final handler = req.onToolCall;
            if (handler != null) {
              await handler('select_speaker', {'assistant_id': 'a1'});
            }
            // Simulate provider cancel after intentional cancelRequest.
            throw Exception('request cancelled');
          }
          yield ChatStreamChunk(
            content: 'hello from member',
            isDone: true,
            totalTokens: 2,
          );
        },
      );

      final result = await orch.sendUserMessage(
        groupId: group.id,
        content: 'Hi',
      );
      expect(result.isSuccess, isTrue);
      expect(result.assistantMessages.length, 1);
      expect(result.assistantMessages.first.content, 'hello from member');
      expect(directorCalls, greaterThanOrEqualTo(1));
    });

    test('forced tool_choice extraBody is passed to director stream', () async {
      final group = await mem.createGroup(
        title: 'T',
        assistantIds: ['a1', 'a2'],
        settings: const GroupChatSettings(
          directorModelProvider: 'P',
          directorModelId: 'tool-model',
        ),
      );

      Map<String, dynamic>? seenExtra;
      final orch = GroupChatOrchestrator(
        groupChatService: mem,
        resolveAssistant: (id) => assistants[id],
        resolveSettings: () => settings,
        prepareMemberGeneration: _prepareFakeMemberGeneration,
        runMemberStream: _runFakeMemberStream,
        sendMessageStream: (req) async* {
          if (req.tools != null && req.tools!.isNotEmpty) {
            seenExtra = req.extraBody;
            final handler = req.onToolCall;
            if (handler != null) {
              await handler('end_round', {});
            }
            yield ChatStreamChunk(content: '', isDone: true, totalTokens: 0);
            return;
          }
          yield ChatStreamChunk(content: '', isDone: true, totalTokens: 0);
        },
      );

      await orch.sendUserMessage(groupId: group.id, content: 'Hi');
      expect(seenExtra, isNotNull);
      expect(seenExtra!['tool_choice'], 'required');
    });

    test('end_round flushes director transcript including tool note', () async {
      final group = await mem.createGroup(
        title: 'T',
        assistantIds: ['a1', 'a2'],
        settings: const GroupChatSettings(
          directorModelProvider: 'P',
          directorModelId: 'tool-model',
          persistDirectorTranscript: true,
        ),
      );

      final orch = GroupChatOrchestrator(
        groupChatService: mem,
        resolveAssistant: (id) => assistants[id],
        resolveSettings: () => settings,
        prepareMemberGeneration: _prepareFakeMemberGeneration,
        runMemberStream: _runFakeMemberStream,
        sendMessageStream: (req) async* {
          if (req.tools != null && req.tools!.isNotEmpty) {
            final handler = req.onToolCall;
            if (handler != null) {
              await handler('end_round', {'reason': 'done'});
            }
            yield ChatStreamChunk(content: '', isDone: true, totalTokens: 0);
            return;
          }
          yield ChatStreamChunk(content: '', isDone: true, totalTokens: 0);
        },
      );

      await orch.sendUserMessage(groupId: group.id, content: 'Hi');
      final session = await mem.getDirectorSession(group.id);
      expect(session, isNotNull);
      expect(session!.messages, isNotEmpty);
      final joined = session.messages
          .map((m) => (m['content'] ?? '').toString())
          .join('\n');
      expect(joined, contains('[tool] end_round'));
      expect(session.state['lastEndedBy'], 'end_round');
    });

    test('alreadyRunning rejects concurrent second send after claim', () async {
      final group = await mem.createGroup(
        title: 'T',
        assistantIds: ['a1', 'a2'],
        settings: const GroupChatSettings(
          directorModelProvider: 'P',
          directorModelId: 'tool-model',
        ),
      );

      final gate = Completer<void>();
      final orch = GroupChatOrchestrator(
        groupChatService: mem,
        resolveAssistant: (id) => assistants[id],
        resolveSettings: () => settings,
        prepareMemberGeneration: _prepareFakeMemberGeneration,
        runMemberStream: _runFakeMemberStream,
        sendMessageStream: (req) async* {
          if (req.tools != null && req.tools!.isNotEmpty) {
            // Hold director open so second send collides with isRunning.
            await gate.future;
            final handler = req.onToolCall;
            if (handler != null) {
              await handler('end_round', {});
            }
            yield ChatStreamChunk(content: '', isDone: true, totalTokens: 0);
            return;
          }
          yield ChatStreamChunk(content: '', isDone: true, totalTokens: 0);
        },
      );

      final first = orch.sendUserMessage(groupId: group.id, content: 'one');
      // Let the first turn claim the phase.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(orch.isRunning(group.id), isTrue);

      await expectLater(
        orch.sendUserMessage(groupId: group.id, content: 'two'),
        throwsA(
          isA<GroupChatOrchestratorException>().having(
            (e) => e.code,
            'code',
            GroupChatErrorCode.alreadyRunning,
          ),
        ),
      );

      gate.complete();
      final result = await first;
      expect(result.isSuccess, isTrue);
    });
  });
}

/// In-memory [GroupChatService] for orchestrator tests (no SQLite).
class _MemoryGroupChatService extends GroupChatService {
  _MemoryGroupChatService() : super();

  final Map<String, GroupChat> groups = {};
  final Map<String, List<GroupChatMember>> members = {};
  final Map<String, List<GroupChatMessage>> messages = {};
  final Map<String, DirectorSession> directors = {};

  @override
  Future<void> ensureLoaded() async {}

  @override
  GroupChat? getGroup(String id) => groups[id];

  @override
  Future<GroupChat> createGroup({
    required String title,
    required List<String> assistantIds,
    String? avatar,
    GroupChatSettings? settings,
  }) async {
    final g = GroupChat(
      title: title,
      settings: settings ?? GroupChatSettings.defaults,
    );
    groups[g.id] = g;
    final list = <GroupChatMember>[
      GroupChatMember(groupId: g.id, kind: GroupChatMember.kindUser),
      for (var i = 0; i < assistantIds.length; i++)
        GroupChatMember(
          groupId: g.id,
          kind: GroupChatMember.kindAssistant,
          assistantId: assistantIds[i],
          sortOrder: i + 1,
        ),
    ];
    members[g.id] = list;
    messages[g.id] = [];
    return g;
  }

  @override
  Future<List<GroupChatMember>> getMembers(String groupId) async =>
      List.unmodifiable(members[groupId] ?? const []);

  @override
  Future<List<GroupChatMessage>> getMessages(String groupId) async =>
      List.unmodifiable(messages[groupId] ?? const []);

  @override
  Future<GroupChatMessage> addMessage(GroupChatMessage message) async {
    final list = messages.putIfAbsent(message.groupId, () => []);
    final order = list.isEmpty ? 0 : list.last.messageOrder + 1;
    final m = message.copyWith(messageOrder: order);
    list.add(m);
    return m;
  }

  @override
  Future<void> updateMessage(
    GroupChatMessage message, {
    bool notify = true,
  }) async {
    final list = messages[message.groupId];
    if (list == null) return;
    final idx = list.indexWhere((m) => m.id == message.id);
    if (idx >= 0) list[idx] = message;
  }

  @override
  Future<DirectorSession?> getDirectorSession(String groupId) async =>
      directors[groupId];

  @override
  Future<DirectorSession?> reloadDirectorSession(String groupId) async =>
      directors[groupId];

  @override
  Future<DirectorSession> ensureDirectorSession(String groupId) async {
    final existing = directors[groupId];
    if (existing != null) return existing;
    return putDirectorSession(DirectorSession(groupId: groupId));
  }

  @override
  Future<DirectorSession> putDirectorSession(DirectorSession session) async {
    final updated = session.copyWith(
      updatedAt: DateTime.now(),
      messages: List<Map<String, dynamic>>.from(
        session.messages.map((e) => Map<String, dynamic>.from(e)),
      ),
      state: Map<String, dynamic>.from(session.state),
    );
    directors[updated.groupId] = updated;
    return updated;
  }
}

/// Minimal SettingsProvider stand-in: only what orchestrator reads.
class _FakeSettings extends Fake implements SettingsProvider {
  _FakeSettings({
    required this.providerKey,
    required this.modelId,
    required this.config,
  });

  final String providerKey;
  final String modelId;
  final ProviderConfig config;

  @override
  String? get currentModelProvider => providerKey;

  @override
  String? get currentModelId => modelId;

  @override
  int? get thinkingBudget => null;

  @override
  ProviderConfig getProviderConfig(String key, {String? defaultName}) => config;
}
