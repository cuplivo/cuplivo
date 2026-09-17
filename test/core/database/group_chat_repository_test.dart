import 'dart:io';

import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/assistant_detail_injection.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/group_chat.dart';
import 'package:Cuplivo/core/models/group_chat_director_log.dart';
import 'package:Cuplivo/core/models/group_chat_member.dart';
import 'package:flutter_test/flutter_test.dart';

GroupChat _group({
  required String id,
  required String conversationId,
  String name = 'Board',
  DateTime? updatedAt,
}) {
  return GroupChat(
    id: id,
    name: name,
    conversationId: conversationId,
    createdAt: DateTime.utc(2026, 3, 1),
    updatedAt: updatedAt ?? DateTime.utc(2026, 3, 2),
  );
}

void main() {
  group('ChatDatabaseRepository group chat CRUD', () {
    late Directory directory;
    late ChatDatabaseRepository repository;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'kelivo_group_chat_test_',
      );
      repository = ChatDatabaseRepository.open(
        file: File('${directory.path}/chat.sqlite'),
      );
      await repository.ensureReady();
    });

    tearDown(() async {
      await repository.close();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    Future<void> addConversation(String id) async {
      final now = DateTime.utc(2026, 3, 1);
      await repository.putMigrationBatch(
        conversations: [
          Conversation(
            id: id,
            title: id,
            createdAt: now,
            updatedAt: now,
            extras: const {'group.kind': 'group'},
          ),
        ],
        messages: const [],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );
    }

    test('round-trips every group field including defaults', () async {
      await addConversation('conv-1');
      final group = _group(id: 'g1', conversationId: 'conv-1').copyWith(
        avatar: 'sunset.png',
        directorModelProvider: 'openrouter',
        directorModelId: 'anthropic/claude',
        directorSystemPrompt: 'Be brief.',
        maxAssistantMessagesPerRound: 5,
        assistantDetailInjectionMode:
            AssistantDetailInjectionMode.everyNUserMessages,
        assistantDetailInjectionN: 3,
        injectGroupMembersIntoAssistantSystemPrompt: false,
        pendingCapAssistantMessageId: 'msg-9',
        assistantMessagesThisRound: 2,
      );
      await repository.putGroupChat(group);

      final loaded = await repository.getGroupChat('g1');
      expect(loaded, isNotNull);
      expect(loaded!.id, 'g1');
      expect(loaded.name, 'Board');
      expect(loaded.avatar, 'sunset.png');
      expect(loaded.conversationId, 'conv-1');
      expect(loaded.directorModelProvider, 'openrouter');
      expect(loaded.directorModelId, 'anthropic/claude');
      expect(loaded.directorSystemPrompt, 'Be brief.');
      expect(loaded.maxAssistantMessagesPerRound, 5);
      expect(
        loaded.assistantDetailInjectionMode,
        AssistantDetailInjectionMode.everyNUserMessages,
      );
      expect(loaded.assistantDetailInjectionN, 3);
      expect(loaded.injectGroupMembersIntoAssistantSystemPrompt, isFalse);
      expect(loaded.pendingCapAssistantMessageId, 'msg-9');
      expect(loaded.assistantMessagesThisRound, 2);
      // Timestamps go through the microsecond-since-epoch converter, which is
      // absolute but reads back in local time: compare instants, not zones.
      expect(
        loaded.createdAt.microsecondsSinceEpoch,
        group.createdAt.microsecondsSinceEpoch,
      );
      expect(
        loaded.updatedAt.microsecondsSinceEpoch,
        group.updatedAt.microsecondsSinceEpoch,
      );

      // A bare group keeps the model defaults through the schema defaults.
      await addConversation('conv-defaults');
      await repository.putGroupChat(
        GroupChat(
          id: 'g-defaults',
          name: 'Defaults',
          conversationId: 'conv-defaults',
        ),
      );
      final defaults = await repository.getGroupChat('g-defaults');
      expect(
        defaults!.directorSystemPrompt,
        GroupChat.defaultDirectorSystemPrompt,
      );
      expect(defaults.maxAssistantMessagesPerRound, 3);
      expect(
        defaults.assistantDetailInjectionMode,
        AssistantDetailInjectionMode.endOfEveryUserMessage,
      );
      expect(defaults.assistantDetailInjectionN, 5);
      expect(defaults.injectGroupMembersIntoAssistantSystemPrompt, isTrue);
      expect(defaults.pendingCapAssistantMessageId, isNull);
      expect(defaults.assistantMessagesThisRound, 0);
      expect(defaults.directorModelProvider, isNull);
    });

    test(
      'putGroupChat replaces in place and round state updates stick',
      () async {
        await addConversation('conv-2');
        await repository.putGroupChat(
          _group(id: 'g2', conversationId: 'conv-2'),
        );

        var loaded = await repository.getGroupChat('g2');
        final createdAt = loaded!.createdAt;
        await repository.putGroupChat(
          loaded.copyWith(assistantMessagesThisRound: 1, name: 'Renamed'),
        );
        expect(await repository.getAllGroupChats(), hasLength(1));

        loaded = await repository.getGroupChat('g2');
        expect(loaded!.assistantMessagesThisRound, 1);
        expect(loaded.name, 'Renamed');
        expect(loaded.createdAt, createdAt);

        loaded = loaded.copyWith(assistantMessagesThisRound: 0);
        await repository.putGroupChat(loaded);
        expect(
          (await repository.getGroupChat('g2'))!.assistantMessagesThisRound,
          0,
        );
      },
    );

    test('getAllGroupChats orders by updatedAt DESC then id ASC', () async {
      await addConversation('conv-a');
      await addConversation('conv-b');
      await addConversation('conv-c');
      await repository.putGroupChat(
        _group(
          id: 'older',
          conversationId: 'conv-a',
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      );
      // Same timestamp: the id tie-breaker must be deterministic.
      await repository.putGroupChat(
        _group(id: 'b-newest', conversationId: 'conv-b'),
      );
      await repository.putGroupChat(
        _group(id: 'a-newest', conversationId: 'conv-c'),
      );

      final ids = (await repository.getAllGroupChats())
          .map((g) => g.id)
          .toList();
      expect(ids, ['a-newest', 'b-newest', 'older']);
    });

    test('getGroupChatByConversationId finds the single bound group', () async {
      await addConversation('conv-x');
      await addConversation('conv-y');
      await repository.putGroupChat(_group(id: 'gx', conversationId: 'conv-x'));
      await repository.putGroupChat(_group(id: 'gy', conversationId: 'conv-y'));

      expect(
        (await repository.getGroupChatByConversationId('conv-x'))?.id,
        'gx',
      );
      expect(
        (await repository.getGroupChatByConversationId('conv-y'))?.id,
        'gy',
      );
      expect(await repository.getGroupChatByConversationId('missing'), isNull);
    });

    test('members round-trip ordered by sortOrder', () async {
      await addConversation('conv-m');
      await repository.putGroupChat(_group(id: 'gm', conversationId: 'conv-m'));
      await repository.putGroupMembers('gm', [
        GroupChatMember.assistant(
          groupChatId: 'gm',
          assistantId: 'assist-2',
          sortOrder: 2,
        ),
        GroupChatMember.user(groupChatId: 'gm'),
        GroupChatMember.assistant(
          groupChatId: 'gm',
          assistantId: 'assist-1',
          sortOrder: 1,
        ),
      ]);

      final members = await repository.getGroupMembers('gm');
      expect(members.map((m) => m.memberKey).toList(), [
        GroupChatMember.userKey,
        'assist-1',
        'assist-2',
      ]);
      expect(members.map((m) => m.sortOrder).toList(), [0, 1, 2]);
      expect(members[0].isUser, isTrue);
      expect(members[0].assistantId, isNull);
      expect(members[1].isUser, isFalse);
      expect(members[1].assistantId, 'assist-1');
      expect(await repository.getGroupMembers('nope'), isEmpty);
    });

    test('putGroupMembers replaces the whole roster', () async {
      await addConversation('conv-r');
      await repository.putGroupChat(_group(id: 'gr', conversationId: 'conv-r'));
      await repository.putGroupMembers('gr', [
        GroupChatMember.user(groupChatId: 'gr'),
        GroupChatMember.assistant(
          groupChatId: 'gr',
          assistantId: 'gone',
          sortOrder: 1,
        ),
      ]);
      await repository.putGroupMembers('gr', [
        GroupChatMember.user(groupChatId: 'gr'),
        GroupChatMember.assistant(
          groupChatId: 'gr',
          assistantId: 'kept',
          sortOrder: 1,
        ),
      ]);

      final members = await repository.getGroupMembers('gr');
      expect(members.map((m) => m.memberKey).toList(), ['user', 'kept']);

      // An empty list clears the roster without touching the group row.
      await repository.putGroupMembers('gr', const []);
      expect(await repository.getGroupMembers('gr'), isEmpty);
      expect(await repository.getGroupChat('gr'), isNotNull);
    });

    test('removeAssistantFromAllGroups matches both column forms', () async {
      await addConversation('conv-1a');
      await addConversation('conv-1b');
      await repository.putGroupChat(
        _group(id: 'g1a', conversationId: 'conv-1a'),
      );
      await repository.putGroupChat(
        _group(id: 'g1b', conversationId: 'conv-1b'),
      );
      // Standard member: memberKey == assistantId == 'doomed'.
      await repository.putGroupMembers('g1a', [
        GroupChatMember.user(groupChatId: 'g1a'),
        GroupChatMember.assistant(
          groupChatId: 'g1a',
          assistantId: 'doomed',
          sortOrder: 1,
        ),
      ]);
      // Denormalized form: memberKey differs but assistantId points at it.
      await repository.putGroupMembers('g1b', [
        GroupChatMember(
          groupChatId: 'g1b',
          memberKey: 'alias-key',
          assistantId: 'doomed',
          sortOrder: 0,
        ),
        GroupChatMember.assistant(
          groupChatId: 'g1b',
          assistantId: 'survivor',
          sortOrder: 1,
        ),
      ]);

      await repository.removeAssistantFromAllGroups('doomed');

      expect(
        (await repository.getGroupMembers('g1a')).map((m) => m.memberKey),
        ['user'],
      );
      expect(
        (await repository.getGroupMembers('g1b')).map((m) => m.memberKey),
        ['survivor'],
      );
    });

    test('deleting a group cascades to its members', () async {
      await addConversation('conv-d');
      await repository.putGroupChat(_group(id: 'gd', conversationId: 'conv-d'));
      await repository.putGroupMembers('gd', [
        GroupChatMember.user(groupChatId: 'gd'),
        GroupChatMember.assistant(
          groupChatId: 'gd',
          assistantId: 'a1',
          sortOrder: 1,
        ),
      ]);

      await repository.deleteGroupChat('gd');

      expect(await repository.getGroupChat('gd'), isNull);
      expect(await repository.getGroupMembers('gd'), isEmpty);
      expect(await repository.getAllGroupChats(), isEmpty);
    });

    test(
      'deleting the conversation cascades to the group and members',
      () async {
        await addConversation('conv-e');
        await repository.putGroupChat(
          _group(id: 'ge', conversationId: 'conv-e'),
        );
        await repository.putGroupMembers('ge', [
          GroupChatMember.user(groupChatId: 'ge'),
        ]);

        await repository.deleteConversation('conv-e');

        expect(await repository.getGroupChatByConversationId('conv-e'), isNull);
        expect(await repository.getGroupMembers('ge'), isEmpty);
      },
    );
  });

  group('GroupChat model', () {
    test('copyWith sentinel distinguishes absent from explicit null', () {
      final group = GroupChat(
        id: 'g',
        name: 'N',
        conversationId: 'c',
        avatar: 'pic',
        directorModelProvider: 'p',
        directorModelId: 'm',
        pendingCapAssistantMessageId: 'msg',
      );

      final untouched = group.copyWith(name: 'Other');
      expect(untouched.avatar, 'pic');
      expect(untouched.directorModelProvider, 'p');
      expect(untouched.directorModelId, 'm');
      expect(untouched.pendingCapAssistantMessageId, 'msg');

      final cleared = group.copyWith(
        avatar: null,
        pendingCapAssistantMessageId: null,
      );
      expect(cleared.avatar, isNull);
      expect(cleared.pendingCapAssistantMessageId, isNull);
      expect(cleared.directorModelProvider, 'p');
    });

    test('clearDirectorModel drops provider and id together', () {
      final group = GroupChat(
        id: 'g',
        name: 'N',
        conversationId: 'c',
        directorModelProvider: 'p',
        directorModelId: 'm',
      );
      final cleared = group.copyWith(clearDirectorModel: true);
      expect(cleared.directorModelProvider, isNull);
      expect(cleared.directorModelId, isNull);
      expect(cleared.name, 'N');
    });

    test('toJson/fromJson round-trips with fork key names', () {
      final group = GroupChat(
        id: 'g',
        name: 'N',
        conversationId: 'c',
        avatar: 'pic',
        directorModelProvider: 'p',
        directorModelId: 'm',
        maxAssistantMessagesPerRound: 4,
        assistantDetailInjectionMode:
            AssistantDetailInjectionMode.appendIntoSystemPrompt,
        assistantDetailInjectionN: 7,
        injectGroupMembersIntoAssistantSystemPrompt: false,
        pendingCapAssistantMessageId: 'msg',
        assistantMessagesThisRound: 3,
        createdAt: DateTime.utc(2026, 5, 6, 7, 8, 9),
        updatedAt: DateTime.utc(2026, 5, 7),
      );
      final json = group.toJson();
      expect(json['assistantDetailInjectionMode'], 'appendIntoSystemPrompt');
      expect(json['createdAt'], '2026-05-06T07:08:09.000Z');

      final restored = GroupChat.fromJson(json);
      expect(restored.id, group.id);
      expect(restored.conversationId, group.conversationId);
      expect(
        restored.assistantDetailInjectionMode,
        group.assistantDetailInjectionMode,
      );
      expect(restored.assistantDetailInjectionN, 7);
      expect(restored.injectGroupMembersIntoAssistantSystemPrompt, isFalse);
      expect(restored.assistantMessagesThisRound, 3);
      expect(restored.createdAt, group.createdAt);
      expect(restored.updatedAt, group.updatedAt);
    });

    test('fromJson fills defaults for a sparse payload', () {
      final group = GroupChat.fromJson({'id': 'g', 'conversationId': 'c'});
      expect(group.name, '');
      expect(group.directorSystemPrompt, GroupChat.defaultDirectorSystemPrompt);
      expect(group.maxAssistantMessagesPerRound, 3);
      expect(group.assistantDetailInjectionN, 5);
      expect(group.assistantMessagesThisRound, 0);
      expect(group.createdAt.isAfter(DateTime.utc(2000)), isTrue);
    });

    test('directorPromptVariables covers the default prompt placeholders', () {
      for (final variable in GroupChat.directorPromptVariables) {
        expect(variable.startsWith('{'), isTrue);
        expect(variable.endsWith('}'), isTrue);
      }
      expect(
        GroupChat.directorPromptVariables,
        containsAll(<String>[
          '{group_name}',
          '{member_names}',
          '{max_assistant_messages_per_round}',
          '{user_name}',
        ]),
      );
      for (final variable in const [
        '{group_name}',
        '{user_name}',
        '{member_names}',
        '{max_assistant_messages_per_round}',
      ]) {
        expect(GroupChat.defaultDirectorSystemPrompt, contains(variable));
      }
    });
  });

  group('AssistantDetailInjectionMode', () {
    test('has seven storage values that round-trip', () {
      expect(AssistantDetailInjectionMode.values, hasLength(7));
      for (final mode in AssistantDetailInjectionMode.values) {
        expect(
          AssistantDetailInjectionModeX.fromStorage(mode.storageValue),
          mode,
        );
      }
    });

    test('fromStorage falls back for unknown, empty, and null values', () {
      final fallback = AssistantDetailInjectionMode.endOfEveryUserMessage;
      expect(AssistantDetailInjectionModeX.fromStorage(null), fallback);
      expect(AssistantDetailInjectionModeX.fromStorage(''), fallback);
      expect(AssistantDetailInjectionModeX.fromStorage('nope'), fallback);
    });

    test('needsN is true only for the two every-N modes', () {
      for (final mode in AssistantDetailInjectionMode.values) {
        final expected =
            mode == AssistantDetailInjectionMode.everyNUserMessages ||
            mode == AssistantDetailInjectionMode.everyNUserAndAssistantMessages;
        expect(mode.needsN, expected, reason: mode.name);
      }
    });
  });

  group('GroupChatMember', () {
    test('factories encode user versus assistant membership', () {
      const user = GroupChatMember.userKey;
      final human = GroupChatMember.user(groupChatId: 'g', sortOrder: 0);
      expect(human.memberKey, user);
      expect(human.isUser, isTrue);
      expect(human.assistantId, isNull);

      final assistant = GroupChatMember.assistant(
        groupChatId: 'g',
        assistantId: 'a',
        sortOrder: 1,
      );
      expect(assistant.memberKey, 'a');
      expect(assistant.assistantId, 'a');
      expect(assistant.isUser, isFalse);
    });

    test('toJson/fromJson round-trips', () {
      final member = GroupChatMember.assistant(
        groupChatId: 'g',
        assistantId: 'a',
        sortOrder: 4,
      );
      final restored = GroupChatMember.fromJson(member.toJson());
      expect(restored.groupChatId, 'g');
      expect(restored.memberKey, 'a');
      expect(restored.assistantId, 'a');
      expect(restored.sortOrder, 4);
      expect(
        GroupChatMember.fromJson({
          'groupChatId': 'g',
          'memberKey': 'user',
        }).sortOrder,
        0,
      );
    });
  });

  group('GroupChatDirectorRuntimeLog', () {
    test('attemptErrors are unmodifiable', () {
      final log = GroupChatDirectorRuntimeLog(
        sourceMessageId: 'm',
        trigger: GroupChatDirectorLogTrigger.capMerge,
        startedAt: DateTime.utc(2026),
        finishedAt: DateTime.utc(2026, 1, 1),
        providerKey: 'p',
        modelId: 'm',
        requestMessageCount: 3,
        attemptCount: 2,
        attemptErrors: ['boom'],
      );
      expect(log.hasErrors, isTrue);
      expect(() => log.attemptErrors.add('again'), throwsUnsupportedError);
    });

    test('hasErrors covers failure-only and clean cases', () {
      GroupChatDirectorRuntimeLog build({
        List<String> errors = const [],
        String? failure,
      }) {
        return GroupChatDirectorRuntimeLog(
          sourceMessageId: null,
          trigger: GroupChatDirectorLogTrigger.user,
          startedAt: DateTime.utc(2026),
          finishedAt: DateTime.utc(2026),
          providerKey: null,
          modelId: null,
          requestMessageCount: 0,
          attemptCount: 1,
          attemptErrors: errors,
          failure: failure,
        );
      }

      expect(build().hasErrors, isFalse);
      expect(build(failure: 'timeout').hasErrors, isTrue);
      expect(build(errors: ['e']).hasErrors, isTrue);
      expect(build().fallback, isFalse);
    });
  });
}
