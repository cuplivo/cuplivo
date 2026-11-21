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
/// The coordinator used to flip the phase to terminal before writing the result
/// row, so a wait that woke in that window reported `completed` with
/// `text: ''` — a model blocked on the job would have been told "done, nothing
/// to say". The order is now write-then-flip; this test parks the write on a
/// gate so the window is deterministic instead of a race.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a wait is still_running until the row exists, then carries the text',
    () async {
      final writeGate = Completer<void>();
      final chat = _GatedChat(writeGate);
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
              }) async => const SubagentTurnStart.started(runId: 'run-1'),
          parentWaker:
              ({
                required parentConversationId,
                required result,
                required assistant,
              }) async => true,
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

      // The watcher saw the terminal run and is now parked inside the write.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(chat.writeEntered, isTrue, reason: 'watcher reached the write');

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

      writeGate.complete();
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
  Future<ChatMessage?> getMessage(String id) async => ChatMessage(
    id: id,
    role: 'assistant',
    content: 'everything the subagent concluded',
    conversationId: 'child-1',
  );
}

class _GatedChat extends Fake implements ChatService {
  _GatedChat(this.writeGate);

  final Completer<void> writeGate;
  bool writeEntered = false;
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
  ChatDatabaseRepository get chatRepositoryOrNull => _FixedRepository();

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
  ) async {
    writeEntered = true;
    await writeGate.future;
  }

  @override
  List<ChatMessage> getMessages(String conversationId) => const <ChatMessage>[];
}
