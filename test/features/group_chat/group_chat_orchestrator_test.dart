import 'dart:async';
import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/assistant_detail_injection.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/group_chat.dart';
import 'package:Cuplivo/core/models/group_chat_director_log.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/user_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/group_chat/controllers/group_chat_orchestrator.dart';
import 'package:Cuplivo/features/group_chat/services/director_context_builder.dart';
import 'package:Cuplivo/features/group_chat/services/director_runner.dart';
import 'package:Cuplivo/features/group_chat/services/director_tool_protocol.dart';
import 'package:Cuplivo/utils/sandbox_path_resolver.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart' show NativeDatabase;
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Scripted stand-in for [DirectorRunner]. The class is concrete but its only
/// member used by the orchestrator is [run], which is virtual, so a fake only
/// has to override that one method.
class _FakeDirectorRunner extends DirectorRunner {
  _FakeDirectorRunner()
    : super(
        chatService: ChatService(),
        contextBuilder: DirectorContextBuilder(chatService: ChatService()),
      );

  final List<String> newUserContents = <String>[];
  final List<GroupChatDirectorLogTrigger> triggers =
      <GroupChatDirectorLogTrigger>[];
  final List<List<Assistant>> rosters = <List<Assistant>>[];
  final List<String?> sourceMessageIds = <String?>[];

  /// Queued in call order; when exhausted the director ends the round.
  final List<DirectorDecision> script = <DirectorDecision>[];

  /// When set, thrown instead of consumed from [script] (every call).
  Object? error;

  int get callCount => newUserContents.length;

  @override
  Future<DirectorDecision> run({
    required GroupChat group,
    required String newUserContent,
    required List<Assistant> rosterAssistants,
    required String userName,
    required List<String> memberNames,
    required SettingsProvider settings,
    required bool Function(String providerKey, String modelId)
    modelSupportsTools,
    required List<ChatMessage> publicMessages,
    required Map<String, int> versionSelections,
    required Map<String, Assistant> assistantsById,
    String? skipPendingCapMessageId,
    String? excludeTrailingUserMessageId,
    String? sourceMessageId,
    GroupChatDirectorLogTrigger trigger = GroupChatDirectorLogTrigger.user,
    DirectorRuntimeLogSink? onRuntimeLog,
  }) async {
    newUserContents.add(newUserContent);
    triggers.add(trigger);
    rosters.add(rosterAssistants);
    sourceMessageIds.add(sourceMessageId);
    final failure = error;
    if (failure != null) throw failure;
    if (script.isEmpty) return DirectorDecision.end(reason: 'script exhausted');
    return script.removeAt(0);
  }
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory tempDir;
  late AppDatabase database;
  late BusinessPreferences preferences;
  late ChatService chatService;
  late ChatDatabaseRepository repository;
  late GroupChatProvider groupChatProvider;
  late AssistantProvider assistantProvider;
  late UserProvider userProvider;
  late SettingsProvider settings;
  late _FakeDirectorRunner director;
  late GroupChatOrchestrator orchestrator;
  late List<GroupChatTurnRequest> turnRequests;
  late List<String> feedbackKeys;
  final turnCompleters = <Completer<void>>[];

  const alice = Assistant(
    id: 'a1',
    name: 'Alice',
    systemPrompt: 'Senior engineer.',
    chatModelProvider: 'TestProvider',
    chatModelId: 'test-model',
  );
  const bob = Assistant(
    id: 'a2',
    name: 'Bob',
    systemPrompt: '',
    chatModelProvider: 'TestProvider',
    chatModelId: 'test-model',
  );

  /// Turn driver: records each request, persists the member's bubble through
  /// the real [ChatService] (mirroring what the send seam does), and optionally
  /// waits for the test to release it via [turnCompleters].
  Future<ChatMessage?> fakeTurnDriver(GroupChatTurnRequest request) async {
    turnRequests.add(request);
    if (request.input == null && turnCompleters.isNotEmpty) {
      await turnCompleters.removeAt(0).future;
    }
    return chatService.addMessage(
      conversationId: request.conversation.id,
      role: 'assistant',
      content: '${request.speaker.name} says hi',
      senderId: request.speaker.id,
    );
  }

  Future<GroupChat> createGroup({
    int cap = 3,
    AssistantDetailInjectionMode injectionMode =
        AssistantDetailInjectionMode.beforeSystemPrompt,
    bool injectMembers = true,
  }) async {
    final conversation = await chatService.createConversation(title: 'G');
    final group = GroupChat(
      name: 'G',
      conversationId: conversation.id,
      maxAssistantMessagesPerRound: cap,
      assistantDetailInjectionMode: injectionMode,
      injectGroupMembersIntoAssistantSystemPrompt: injectMembers,
    );
    await repository.putGroupChat(group);
    await groupChatProvider.load();
    await groupChatProvider.setMembers(group.id, const ['a1', 'a2']);
    return groupChatProvider.getById(group.id)!;
  }

  Future<ChatMessage> addUserMessage(GroupChat group, String text) {
    return chatService.addMessage(
      conversationId: group.conversationId,
      role: 'user',
      content: text,
    );
  }

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('kelivo_group_orch_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    // ChatService.init resolves the app-data dir; keep everything sandboxed.
    SandboxPathResolver.debugSetDirs(
      docsDir: tempDir.path,
      supportDir: tempDir.path,
    );
    SharedPreferences.setMockInitialValues({});
    database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    preferences = BusinessPreferences(BusinessRepository(database));
    repository = ChatDatabaseRepository(database);
    chatService = ChatService(existingRepository: repository);
    addTearDown(chatService.close);
    await chatService.init();

    groupChatProvider = GroupChatProvider(chatService: chatService);
    assistantProvider = AssistantProvider(preferences: preferences);
    await assistantProvider.loaded;
    assistantProvider.debugReplaceAssistants(const [alice, bob]);
    userProvider = UserProvider(preferences: preferences);
    settings = SettingsProvider(preferences);
    addTearDown(settings.dispose);
    await settings.loaded;

    director = _FakeDirectorRunner();
    turnRequests = <GroupChatTurnRequest>[];
    feedbackKeys = <String>[];
    turnCompleters.clear();
    orchestrator = GroupChatOrchestrator(
      chatService: chatService,
      groupChatProvider: groupChatProvider,
      assistantProvider: assistantProvider,
      settingsProvider: settings,
      userProvider: userProvider,
      directorRunner: director,
      turnDriver: fakeTurnDriver,
      onUiFeedback: feedbackKeys.add,
    );
  });

  tearDown(() async {
    SandboxPathResolver.debugSetDirs(docsDir: null, supportDir: null);
    for (final completer in turnCompleters) {
      if (!completer.isCompleted) completer.complete();
    }
    turnCompleters.clear();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('handleUserMessage — E1 / round reset', () {
    test(
      'first user turn resets the counter and asks the director once (E1)',
      () async {
        final group = await createGroup();
        director.script.add(DirectorDecision.end(reason: 'done'));

        final user = await addUserMessage(group, 'hello there');
        await orchestrator.handleUserMessage(group: group, userMessage: user);

        expect(director.callCount, 1);
        expect(director.triggers.single, GroupChatDirectorLogTrigger.user);
        expect(
          director.newUserContents.single,
          contains('[User]: hello there'),
        );
        expect(
          director.newUserContents.single,
          contains(DirectorContextBuilder.toolOnlyReminder),
        );
        // Round state persisted: counter reset to 0, no pending cap.
        final g = groupChatProvider.getById(group.id)!;
        expect(g.assistantMessagesThisRound, 0);
        expect(g.pendingCapAssistantMessageId, isNull);
        expect(turnRequests, isEmpty);
      },
    );

    test(
      'counter is reset even when a stale count existed before the user turn',
      () async {
        var group = await createGroup();
        group = group.copyWith(assistantMessagesThisRound: 2);
        await groupChatProvider.persistGroupState(group);
        director.script.add(DirectorDecision.end());

        final user = await addUserMessage(group, 'next question');
        await orchestrator.handleUserMessage(group: group, userMessage: user);

        expect(
          groupChatProvider.getById(group.id)!.assistantMessagesThisRound,
          0,
        );
      },
    );

    test(
      'no members: emits groupChatNoAssistants and never calls the director',
      () async {
        final group = await createGroup();
        await groupChatProvider.setMembers(group.id, const []);
        final user = await addUserMessage(group, 'hi');

        await orchestrator.handleUserMessage(group: group, userMessage: user);

        expect(feedbackKeys, ['groupChatNoAssistants']);
        expect(director.callCount, 0);
      },
    );
  });

  group('directorLoop — E2 continuation', () {
    test('assistant turn then second director call uses E2 content', () async {
      final group = await createGroup(cap: 3);
      director.script.addAll([
        DirectorDecision.speak('a1'),
        DirectorDecision.end(reason: 'round over'),
      ]);

      final user = await addUserMessage(group, 'hi');
      await orchestrator.handleUserMessage(group: group, userMessage: user);

      expect(director.callCount, 2);
      expect(director.triggers[1], GroupChatDirectorLogTrigger.assistant);
      expect(director.newUserContents[1], contains('[Alice]: Alice says hi'));
      expect(director.sourceMessageIds[1], isNotNull);

      // One member turn ran, with the speaker resolved from the roster.
      expect(turnRequests, hasLength(1));
      expect(turnRequests.single.speaker.id, 'a1');
      expect(turnRequests.single.providerKey, 'TestProvider');
      expect(turnRequests.single.modelId, 'test-model');

      final g = groupChatProvider.getById(group.id)!;
      expect(g.assistantMessagesThisRound, 1);
      expect(g.pendingCapAssistantMessageId, isNull);
    });

    test(
      'unknown-speaker decision skips the turn and ends the round',
      () async {
        final group = await createGroup();
        director.script.add(DirectorDecision.speak('ghost-not-in-roster'));

        final user = await addUserMessage(group, 'hi');
        await orchestrator.handleUserMessage(group: group, userMessage: user);

        expect(director.callCount, 1);
        expect(turnRequests, isEmpty);
        final g = groupChatProvider.getById(group.id)!;
        expect(g.assistantMessagesThisRound, 0);
        expect(g.pendingCapAssistantMessageId, isNull);
      },
    );

    test('end_turn stops immediately without running a member', () async {
      final group = await createGroup();
      director.script.add(DirectorDecision.end());

      final user = await addUserMessage(group, 'hi');
      await orchestrator.handleUserMessage(group: group, userMessage: user);

      expect(turnRequests, isEmpty);
      expect(director.callCount, 1);
    });
  });

  group('cap handling', () {
    test(
      'cap-merge (E3) consumes the pending cap message on next user turn',
      () async {
        var group = await createGroup(cap: 1);
        director.script.add(DirectorDecision.speak('a1'));
        final first = await addUserMessage(group, 'first');
        await orchestrator.handleUserMessage(group: group, userMessage: first);

        group = groupChatProvider.getById(group.id)!;
        final cappedId = group.pendingCapAssistantMessageId;
        expect(cappedId, isNotNull, reason: 'cap 1 marks the pending bubble');
        expect(group.assistantMessagesThisRound, 1);

        director.script.add(DirectorDecision.end());
        final second = await addUserMessage(group, 'second');
        await orchestrator.handleUserMessage(group: group, userMessage: second);

        expect(director.triggers.last, GroupChatDirectorLogTrigger.capMerge);
        final e3 = director.newUserContents.last;
        expect(
          e3,
          contains('[Alice]: Alice says hi'),
          reason: 'pending bubble merged',
        );
        expect(e3, contains('[User]: second'));
        // The pending marker was cleared for this call...
        expect(director.rosters.length, 2);
        // ...and the group state now shows a fresh (non-pending) round.
        final g = groupChatProvider.getById(group.id)!;
        expect(g.pendingCapAssistantMessageId, isNull);
        expect(g.assistantMessagesThisRound, 0);
      },
    );

    test(
      'round cap persists pendingCapAssistantMessageId and stops the loop',
      () async {
        final group = await createGroup(cap: 2);
        // Director would happily keep speaking; the cap must stop it after 2.
        director.script.addAll([
          DirectorDecision.speak('a1'),
          DirectorDecision.speak('a2'),
          DirectorDecision.speak('a1'),
        ]);

        final user = await addUserMessage(group, 'go');
        await orchestrator.handleUserMessage(group: group, userMessage: user);

        expect(
          director.callCount,
          2,
          reason: 'loop stops at the cap, no 3rd call',
        );
        expect(turnRequests, hasLength(2));
        final g = groupChatProvider.getById(group.id)!;
        expect(g.assistantMessagesThisRound, 2);
        expect(g.pendingCapAssistantMessageId, isNotNull);
        // The pending id is exactly the last assistant bubble produced.
        final persisted = await chatService.loadMessages(group.conversationId);
        expect(
          persisted.any(
            (m) =>
                m.id == g.pendingCapAssistantMessageId && m.role == 'assistant',
          ),
          isTrue,
        );
      },
    );

    test(
      'nextSpeakerForDecision returns null for endTurn / unknown / budget-exhausted',
      () {
        final group = GroupChat(
          name: 'g',
          conversationId: 'c',
          maxAssistantMessagesPerRound: 2,
        );
        expect(
          GroupChatOrchestrator.nextSpeakerForDecision(
            decision: DirectorDecision.end(),
            rosterIds: {'a1'},
            group: group,
          ),
          isNull,
        );
        expect(
          GroupChatOrchestrator.nextSpeakerForDecision(
            decision: DirectorDecision.speak('zzz'),
            rosterIds: {'a1'},
            group: group,
          ),
          isNull,
        );
        expect(
          GroupChatOrchestrator.nextSpeakerForDecision(
            decision: DirectorDecision.speak('a1'),
            rosterIds: {'a1'},
            group: group.copyWith(assistantMessagesThisRound: 2),
          ),
          isNull,
        );
        expect(
          GroupChatOrchestrator.nextSpeakerForDecision(
            decision: DirectorDecision.speak('a1'),
            rosterIds: {'a1'},
            group: group.copyWith(assistantMessagesThisRound: 1),
          ),
          'a1',
        );
      },
    );
  });

  group('stop flag', () {
    test(
      'requestStop between turns halts the loop after the first member',
      () async {
        final group = await createGroup(cap: 5);
        director.script.addAll([
          DirectorDecision.speak('a1'),
          DirectorDecision.speak('a2'),
        ]);
        final gate = Completer<void>();
        turnCompleters.add(gate);

        final user = await addUserMessage(group, 'hi');
        final running = orchestrator.handleUserMessage(
          group: group,
          userMessage: user,
        );
        // Wait until the first member turn is parked inside the driver.
        while (turnRequests.isEmpty) {
          await Future<void>.delayed(Duration.zero);
        }
        orchestrator.requestStop();
        gate.complete();
        await running;

        expect(director.callCount, 1, reason: 'no director call after stop');
        expect(turnRequests, hasLength(1));
        expect(orchestrator.isBusy, isFalse);
      },
    );
  });

  group('roster injection', () {
    test(
      'assistant system prompt gets the member paragraph when enabled',
      () async {
        final group = await createGroup(injectMembers: true);
        director.script.addAll([
          DirectorDecision.speak('a1'),
          DirectorDecision.end(),
        ]);

        final user = await addUserMessage(group, 'hi');
        await orchestrator.handleUserMessage(group: group, userMessage: user);

        expect(turnRequests, hasLength(1));
        final speaker = turnRequests.single.speaker;
        expect(speaker.id, 'a1');
        expect(speaker.systemPrompt, startsWith('Senior engineer.'));
        expect(speaker.systemPrompt, contains('你现在处于一个群聊中'));
        expect(speaker.systemPrompt, contains('User'));
        expect(speaker.systemPrompt, contains('Alice'));
        expect(speaker.systemPrompt, contains('Bob'));
      },
    );

    test(
      'empty base prompt receives only the injection; disabled flag leaves it untouched',
      () async {
        final group = await createGroup(injectMembers: false);
        director.script.addAll([
          DirectorDecision.speak('a2'),
          DirectorDecision.end(),
        ]);

        final user = await addUserMessage(group, 'hi');
        await orchestrator.handleUserMessage(group: group, userMessage: user);

        expect(turnRequests.single.speaker.systemPrompt, isEmpty);
      },
    );

    test(
      'director content gains the roster block under endOfEveryUserMessage',
      () async {
        final group = await createGroup(
          injectionMode: AssistantDetailInjectionMode.endOfEveryUserMessage,
        );
        director.script.add(DirectorDecision.end());

        final user = await addUserMessage(group, 'hi');
        await orchestrator.handleUserMessage(group: group, userMessage: user);

        final content = director.newUserContents.single;
        expect(content, contains('<assistant_roster>'));
        expect(content, contains('- id: a1'));
        expect(content, contains('name: Alice'));
      },
    );

    test(
      'never mode keeps the director content free of a roster block',
      () async {
        final group = await createGroup();
        director.script.add(DirectorDecision.end());

        final user = await addUserMessage(group, 'hi');
        await orchestrator.handleUserMessage(group: group, userMessage: user);

        expect(
          director.newUserContents.single,
          isNot(contains('<assistant_roster>')),
        );
      },
    );
  });

  group('model-missing paths', () {
    test(
      'speaker without resolvable model emits groupChatAssistantNoModel and stops',
      () async {
        assistantProvider.debugReplaceAssistants(const [
          Assistant(
            id: 'a1',
            name: 'Alice',
            chatModelProvider: null,
            chatModelId: null,
          ),
          bob,
        ]);
        final group = await createGroup();
        director.script.add(DirectorDecision.speak('a1'));

        final user = await addUserMessage(group, 'hi');
        await orchestrator.handleUserMessage(group: group, userMessage: user);

        expect(feedbackKeys, contains('groupChatAssistantNoModel'));
        expect(turnRequests, isEmpty);
        expect(director.callCount, 1, reason: 'loop exits on the failed turn');
      },
    );

    test(
      'director soft error (no model) emits groupChatNoDirectorModel',
      () async {
        final group = await createGroup();
        director.error = DirectorSoftError(DirectorSoftErrorKind.noModel);

        final user = await addUserMessage(group, 'hi');
        await orchestrator.handleUserMessage(group: group, userMessage: user);

        expect(feedbackKeys, ['groupChatNoDirectorModel']);
        expect(turnRequests, isEmpty);
      },
    );

    test('director timeout emits groupChatDirectorTimeout', () async {
      final group = await createGroup();
      director.error = TimeoutException('boom');

      final user = await addUserMessage(group, 'hi');
      await orchestrator.handleUserMessage(group: group, userMessage: user);

      expect(feedbackKeys, ['groupChatDirectorTimeout']);
    });

    test('generic director error emits groupChatDirectorError', () async {
      final group = await createGroup();
      director.error = StateError('kaboom');

      final user = await addUserMessage(group, 'hi');
      await orchestrator.handleUserMessage(group: group, userMessage: user);

      expect(feedbackKeys, ['groupChatDirectorError']);
    });
  });

  group('repairCapIfNeeded', () {
    test('drops the pending marker when its message was deleted', () async {
      var group = await createGroup(cap: 1);
      director.script.add(DirectorDecision.speak('a1'));
      final user = await addUserMessage(group, 'hi');
      await orchestrator.handleUserMessage(group: group, userMessage: user);

      group = groupChatProvider.getById(group.id)!;
      final pending = group.pendingCapAssistantMessageId!;
      await chatService.deleteMessage(pending);
      await orchestrator.repairCapIfNeeded(group.id, deletedIds: {pending});

      final g = groupChatProvider.getById(group.id)!;
      expect(g.pendingCapAssistantMessageId, isNull);
      expect(g.assistantMessagesThisRound, 0);
    });

    test(
      'drops the pending marker when truncation removed the bubble',
      () async {
        var group = await createGroup(cap: 1);
        director.script.add(DirectorDecision.speak('a1'));
        final user = await addUserMessage(group, 'hi');
        await orchestrator.handleUserMessage(group: group, userMessage: user);

        group = groupChatProvider.getById(group.id)!;
        final pending = group.pendingCapAssistantMessageId!;
        await chatService.deleteMessage(pending);
        await orchestrator.repairCapIfNeeded(group.id);

        expect(
          groupChatProvider.getById(group.id)!.pendingCapAssistantMessageId,
          isNull,
        );
      },
    );

    test('keeps the marker while the message still exists', () async {
      var group = await createGroup(cap: 1);
      director.script.add(DirectorDecision.end());
      final user = await addUserMessage(group, 'hi');
      await orchestrator.handleUserMessage(group: group, userMessage: user);

      group = groupChatProvider.getById(group.id)!;
      await orchestrator.repairCapIfNeeded(group.id);

      expect(
        groupChatProvider.getById(group.id)!.pendingCapAssistantMessageId,
        group.pendingCapAssistantMessageId,
      );
    });
  });

  group('truncateAfterMessageGroup', () {
    test('deletes every reply group after the anchor group only', () async {
      final group = await createGroup();
      final u1 = await addUserMessage(group, 'u1');
      await chatService.addMessage(
        conversationId: group.conversationId,
        role: 'assistant',
        content: 'a1',
        groupId: 'ga1',
      );
      final u2 = await chatService.addMessage(
        conversationId: group.conversationId,
        role: 'user',
        content: 'u2',
        groupId: 'gu2',
      );
      final a2 = await chatService.addMessage(
        conversationId: group.conversationId,
        role: 'assistant',
        content: 'a2',
        groupId: 'ga2',
      );

      await orchestrator.truncateAfterMessageGroup(
        conversationId: group.conversationId,
        anchor: u1,
      );

      final remaining = await chatService.loadMessages(group.conversationId);
      expect(remaining.map((m) => m.id), [u1.id]);
      expect(remaining.any((m) => m.id == u2.id || m.id == a2.id), isFalse);
    });
  });

  group('regenerateAssistantMessage', () {
    test('re-runs the same speaker without any director call', () async {
      final group = await createGroup();
      final user = await addUserMessage(group, 'hi');
      final answer = await chatService.addMessage(
        conversationId: group.conversationId,
        role: 'assistant',
        content: 'original',
        senderId: 'a1',
      );

      await orchestrator.regenerateAssistantMessage(
        group: group,
        message: answer,
      );

      expect(director.callCount, 0);
      expect(turnRequests, hasLength(1));
      expect(turnRequests.single.speaker.id, 'a1');
      // Context is strictly the prefix before the regenerated bubble.
      expect(
        turnRequests.single.privateContext.any(
          (m) => m.content.contains('original'),
        ),
        isFalse,
      );
      expect(user.role, 'user');
    });

    test(
      'assistant message with an unknown sender emits the model feedback key',
      () async {
        final group = await createGroup();
        final answer = await chatService.addMessage(
          conversationId: group.conversationId,
          role: 'assistant',
          content: 'orphan',
          senderId: 'gone-assistant',
        );

        await orchestrator.regenerateAssistantMessage(
          group: group,
          message: answer,
        );

        expect(feedbackKeys, contains('groupChatAssistantNoModel'));
        expect(turnRequests, isEmpty);
      },
    );

    test('user messages are ignored', () async {
      final group = await createGroup();
      final user = await addUserMessage(group, 'hi');
      await orchestrator.regenerateAssistantMessage(
        group: group,
        message: user,
      );
      expect(turnRequests, isEmpty);
      expect(feedbackKeys, isEmpty);
    });
  });

  group('resendUserMessage', () {
    test('truncates the tail and re-enters the director loop', () async {
      var group = await createGroup(cap: 1);
      director.script.add(DirectorDecision.speak('a1'));
      final user = await addUserMessage(group, 'again');
      await orchestrator.handleUserMessage(group: group, userMessage: user);
      group = groupChatProvider.getById(group.id)!;
      expect(group.pendingCapAssistantMessageId, isNotNull);

      director.script.add(DirectorDecision.end());
      await orchestrator.resendUserMessage(group: group, userMessage: user);

      // Tail (the capped bubble) was removed, so the repair dropped the marker.
      final messages = await chatService.loadMessages(group.conversationId);
      expect(messages.map((m) => m.role), ['user']);
      expect(
        groupChatProvider.getById(group.id)!.pendingCapAssistantMessageId,
        isNull,
      );
      expect(director.callCount, 2);
      expect(turnRequests, hasLength(1), reason: 'only the first round spoke');
    });
  });

  group('deleteMessageVersions', () {
    test('allVersions removes every row of the reply group', () async {
      final group = await createGroup();
      final v0 = await chatService.addMessage(
        conversationId: group.conversationId,
        role: 'assistant',
        content: 'v0',
        groupId: 'gv',
        version: 0,
      );
      final v1 = await chatService.addMessage(
        conversationId: group.conversationId,
        role: 'assistant',
        content: 'v1',
        groupId: 'gv',
        version: 1,
      );

      await orchestrator.deleteMessageVersions(
        group: group,
        message: v1,
        allVersions: true,
      );

      final remaining = await chatService.loadMessages(group.conversationId);
      expect(remaining.where((m) => m.groupId == 'gv'), isEmpty);
      expect(remaining.any((m) => m.id == v0.id), isFalse);
    });

    test(
      'single version delete keeps the sibling and repairs a pending cap',
      () async {
        var group = await createGroup(cap: 1);
        director.script.add(DirectorDecision.speak('a1'));
        final user = await addUserMessage(group, 'hi');
        await orchestrator.handleUserMessage(group: group, userMessage: user);
        group = groupChatProvider.getById(group.id)!;
        final capped = group.pendingCapAssistantMessageId!;

        await orchestrator.deleteMessageVersions(
          group: group,
          message: await repository.getMessage(capped).then((m) => m!),
          allVersions: false,
        );

        final g = groupChatProvider.getById(group.id)!;
        expect(g.pendingCapAssistantMessageId, isNull);
        expect(g.assistantMessagesThisRound, 0);
      },
    );
  });

  group('busy guard', () {
    test('a concurrent handleUserMessage returns immediately', () async {
      final group = await createGroup(cap: 5);
      director.script.add(DirectorDecision.speak('a1'));
      final gate = Completer<void>();
      turnCompleters.add(gate);

      final user = await addUserMessage(group, 'hi');
      final first = orchestrator.handleUserMessage(
        group: group,
        userMessage: user,
      );
      while (turnRequests.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(orchestrator.isBusy, isTrue);

      await orchestrator.handleUserMessage(group: group, userMessage: user);
      expect(director.callCount, 1, reason: 'second entry bailed out');

      gate.complete();
      director.script.add(DirectorDecision.end());
      await first;
    });
  });

  group('modelSupportsTools', () {
    test('absent override metadata counts as tool-capable', () {
      expect(
        orchestrator.modelSupportsTools('TestProvider', 'no-such-model'),
        isTrue,
      );
    });

    test('abilities list without "tool" reports unsupported', () async {
      final config = settings
          .getProviderConfig('TestProvider')
          .copyWith(
            modelOverrides: const <String, dynamic>{
              'plain-model': <String, dynamic>{
                'abilities': <String>['reasoning'],
              },
            },
          );
      await settings.setProviderConfig('TestProvider', config);
      expect(
        orchestrator.modelSupportsTools('TestProvider', 'plain-model'),
        isFalse,
      );
      expect(
        orchestrator.modelSupportsTools('TestProvider', 'no-such-model'),
        isTrue,
      );
    });
  });
}
