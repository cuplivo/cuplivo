import 'dart:async';

import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/database/generation_run.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/workspace_binding.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/subagent/services/subagent_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

/// `await_job` answers with the conclusion, and it does not answer before the
/// conclusion exists.
///
/// The coordinator computes the brief and then flips the phase; a wait that woke
/// in between used to report `completed` with `text: ''` — a model blocked on the
/// job would have been told "done, nothing to say". The order is now
/// compute-then-flip; this test parks the brief's read so the window is
/// deterministic instead of a race.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a wait is still_running until the brief exists, then carries the text',
    () async {
      final briefGate = Completer<void>();
      final chat = _GatedChat(briefGate);
      final coordinator = SubagentCoordinator(
        chat,
        clock: DateTime.now,
        pollInterval: const Duration(milliseconds: 1),
      );
      coordinator.attachHost(
        SubagentHost(
          turnStarter:
              ({
                required conversationId,
                required assistant,
                required task,
                delegator,
                target,
              }) async => const SubagentTurnStart.started(runId: 'run-1'),
          enqueueResult:
              ({
                required parentConversationId,
                required notice,
                required assistant,
                required followUp,
              }) {},
        ),
      );

      final start = await coordinator.begin(
        parentConversationId: 'parent',
        toolCallId: 'call-1',
        task: 'summarise the repo',
        label: 'summary',
        assistant: Assistant(id: 'a', name: 'A'),
      );
      final childId = (start as SubagentStarted).entry.childConversationId;

      // The watcher saw the terminal run and is now parked inside the brief.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(chat.briefEntered, isTrue, reason: 'watcher reached the brief');

      // With no timeout the wait has no ceiling of its own: a delegation may run
      // for half an hour, and giving up early would turn the model into a poller.
      var settledEarly = false;
      unawaited(coordinator.awaitJob(childId).then((_) => settledEarly = true));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(settledEarly, isFalse, reason: 'the default wait has no ceiling');

      final whileWriting = await coordinator.awaitJob(
        childId,
        timeout: const Duration(milliseconds: 60),
      );
      expect(whileWriting['status'], 'still_running');
      expect(whileWriting['elapsed_ms'], isA<int>());

      briefGate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final settled = await coordinator.awaitJob(
        childId,
        timeout: const Duration(milliseconds: 200),
      );
      expect(settled['status'], 'completed');
      final payload = settled['payload'] as Map;
      expect(payload['conversation_id'], childId);
      expect(payload['text'], contains('everything the subagent concluded'));

      coordinator.dispose();
    },
  );
}

class _FixedRepository extends Fake implements ChatDatabaseRepository {
  _FixedRepository({this.briefGate, this.onBriefEntered});

  final Completer<void>? briefGate;
  final void Function()? onBriefEntered;

  @override
  Future<GenerationRun?> getGenerationRun(String id) async {
    final at = DateTime(2026, 11, 21, 12);
    return GenerationRun(
      id: id,
      conversationId: 'child-1',
      targetRevisionId: 'assistant-message',
      state: GenerationRunState.completed,
      stateRevision: 1,
      checkpointSeq: 1,
      errorCode: null,
      createdAt: at,
      updatedAt: at,
      terminalAt: at,
    );
  }

  @override
  Future<GenerationRun?> latestGenerationRun(String conversationId) =>
      getGenerationRun('run-1');

  @override
  Future<ChatMessage?> getMessage(String id) async {
    onBriefEntered?.call();
    await briefGate?.future;
    return ChatMessage(
      id: id,
      role: 'assistant',
      content: 'everything the subagent concluded',
      conversationId: 'child-1',
    );
  }
}

class _GatedChat extends Fake implements ChatService {
  _GatedChat(this.briefGate);

  final Completer<void> briefGate;
  bool briefEntered = false;
  final Map<String, Conversation> _conversations = <String, Conversation>{
    'parent': Conversation(
      id: 'parent',
      title: 'Chat',
      extras: const <String, dynamic>{
        WorkspaceBinding.keyId: 'ws-1',
        WorkspaceBinding.keyCwd: '/w',
      },
    ),
  };

  @override
  Conversation? getConversation(String id) => _conversations[id];

  @override
  bool isTemporaryConversation(String? id) => false;

  @override
  ChatDatabaseRepository get chatRepositoryOrNull => _FixedRepository(
    briefGate: briefGate,
    onBriefEntered: () => briefEntered = true,
  );

  @override
  Future<Conversation> createConversation({
    String? title,
    String? assistantId,
    String? groupChatId,
    bool activate = true,
    Map<String, dynamic>? extras,
  }) async {
    final conversation = Conversation(
      id: 'child-1',
      title: title ?? 'title',
      assistantId: assistantId,
      extras: extras ?? const <String, dynamic>{},
    );
    _conversations[conversation.id] = conversation;
    return conversation;
  }

  @override
  Future<void> addMessageDirectly(
    String conversationId,
    ChatMessage message,
  ) async {}

  @override
  List<ChatMessage> getMessages(String conversationId) => const <ChatMessage>[];
}
