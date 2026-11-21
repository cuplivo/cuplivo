import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/database/generation_run.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/core/models/tool_permission_mode.dart';
import 'package:Cuplivo/core/models/workspace_binding.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/subagent/services/subagent_coordinator.dart';
import 'package:Cuplivo/features/subagent/services/subagent_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('delegate: what begin refuses', () {
    test('a conversation without a workspace is refused', () async {
      final chat = _FakeChat(<String, Conversation>{
        'parent': Conversation(id: 'parent', title: 'Chat'),
      });
      final coordinator = SubagentCoordinator(chat, clock: _clock())
        ..attachHost(_host(chat));

      final start = await coordinator.begin(
        parentConversationId: 'parent',
        toolCallId: 'call-1',
        task: 'refactor auth',
        label: 'auth',
        assistant: _assistant(),
      );

      expect(start, isA<SubagentRefused>());
      expect((start as SubagentRefused).code, 'no_workspace');
      expect(chat.created, isEmpty);
      coordinator.dispose();
    });

    test('a conversation at the delegation limit is refused', () async {
      final chat = _FakeChat(<String, Conversation>{
        'child': Conversation(
          id: 'child',
          title: 'Child',
          extras: const <String, dynamic>{
            WorkspaceBinding.keyId: 'ws-1',
            WorkspaceBinding.keyCwd: '/w',
            SubagentExtrasKeys.depth: kMaxSubagentDepth,
          },
        ),
      });
      final coordinator = SubagentCoordinator(chat, clock: _clock())
        ..attachHost(_host(chat));

      final start = await coordinator.begin(
        parentConversationId: 'child',
        toolCallId: 'call-1',
        task: 'refactor auth',
        label: 'auth',
        assistant: _assistant(),
      );

      expect((start as SubagentRefused).code, 'depth_limit');
      expect(chat.created, isEmpty);
      coordinator.dispose();
    });

    test(
      'a temporary chat is refused, because its promise is to leave nothing',
      () async {
        final chat = _FakeChat(<String, Conversation>{
          'parent': Conversation(
            id: 'parent',
            title: 'Chat',
            extras: const <String, dynamic>{
              WorkspaceBinding.keyId: 'ws-1',
              WorkspaceBinding.keyCwd: '/w',
            },
          ),
        })..markTemporary('parent');
        final coordinator = SubagentCoordinator(chat, clock: _clock())
          ..attachHost(_host(chat));

        final start = await coordinator.begin(
          parentConversationId: 'parent',
          toolCallId: 'call-1',
          task: 'x',
          label: 'x',
          assistant: _assistant(),
        );

        expect((start as SubagentRefused).code, 'temporary_conversation');
        // The child would be a real row with the task text and a transcript, so
        // nothing may be created at all.
        expect(chat.created, isEmpty);
        coordinator.dispose();
      },
    );

    test('a group conversation is refused at the coordinator, not only in the '
        'tool list', () async {
      final chat = _FakeChat(<String, Conversation>{
        'group': Conversation(
          id: 'group',
          title: 'Group',
          extras: const <String, dynamic>{
            WorkspaceBinding.keyId: 'ws-1',
            WorkspaceBinding.keyCwd: '/w',
            Conversation.groupChatIdKey: 'group-chat-1',
          },
        ),
      });
      final coordinator = SubagentCoordinator(chat, clock: _clock())
        ..attachHost(_host(chat));
      final start = await coordinator.begin(
        parentConversationId: 'group',
        toolCallId: 'call-1',
        task: 'x',
        label: 'x',
        assistant: _assistant(),
      );

      // A group conversation's assistantId is null, so the child would silently
      // run as whichever assistant happens to be selected later.
      expect((start as SubagentRefused).code, 'group_conversation');
      expect(chat.created, isEmpty);
      coordinator.dispose();
    });

    test('a workspace that no longer exists is refused', () async {
      final chat = _FakeChat(<String, Conversation>{
        'parent': Conversation(
          id: 'parent',
          title: 'Chat',
          extras: const <String, dynamic>{
            WorkspaceBinding.keyId: 'ws-gone',
            WorkspaceBinding.keyCwd: '/w',
          },
        ),
      });
      final coordinator = SubagentCoordinator(chat, clock: _clock())
        ..attachHost(_host(chat));

      final start = await coordinator.begin(
        parentConversationId: 'parent',
        toolCallId: 'call-1',
        task: 'x',
        label: 'x',
        assistant: _assistant(),
        workspaceExists: (_) => false,
      );

      expect((start as SubagentRefused).code, 'workspace_not_ready');
      expect(chat.created, isEmpty);
      coordinator.dispose();
    });
  });

  group('delegate: the child conversation', () {
    test('inherits the parent workspace and no grant', () async {
      final chat = _FakeChat(<String, Conversation>{
        'parent': Conversation(
          id: 'parent',
          title: 'Chat',
          assistantId: 'assistant-1',
          extras: const <String, dynamic>{
            WorkspaceBinding.keyId: 'ws-1',
            WorkspaceBinding.keyCwd: '/work/app',
            ToolPermissionMode.extrasKey: 'fullAccess',
          },
        ),
      });
      final coordinator = SubagentCoordinator(chat, clock: _clock())
        ..attachHost(_host(chat));
      final turn = _turns(chat);

      await coordinator.begin(
        parentConversationId: 'parent',
        toolCallId: 'call-1',
        task: 'refactor auth',
        label: 'auth',
        assistant: _assistant(),
      );

      expect(chat.created, hasLength(1));
      final extras = chat.created.single.extras;
      expect(extras[WorkspaceBinding.keyId], 'ws-1');
      expect(extras[WorkspaceBinding.keyCwd], '/work/app');
      expect(extras[SubagentExtrasKeys.parent], 'parent');
      expect(extras[SubagentExtrasKeys.root], 'parent');
      expect(extras[SubagentExtrasKeys.depth], 1);
      // A grant is per conversation; the child never carries one.
      expect(
        extras.keys.toSet().intersection(
          ToolPermissionMode.grantExtrasKeys.toSet(),
        ),
        isEmpty,
      );
      expect(chat.created.single.title, 'auth');
      expect(chat.created.single.assistantId, 'assistant-1');
      expect(turn.started, hasLength(1));
      coordinator.dispose();
    });

    test('the same tool call delegates once', () async {
      final chat = _FakeChat(<String, Conversation>{
        'parent': Conversation(
          id: 'parent',
          title: 'Chat',
          extras: const <String, dynamic>{
            WorkspaceBinding.keyId: 'ws-1',
            WorkspaceBinding.keyCwd: '/w',
          },
        ),
      });
      final coordinator = SubagentCoordinator(chat, clock: _clock())
        ..attachHost(_host(chat));
      final turn = _turns(chat);

      final first = await coordinator.begin(
        parentConversationId: 'parent',
        toolCallId: 'call-1',
        task: 'a',
        label: 'a',
        assistant: _assistant(),
      );
      final second = await coordinator.begin(
        parentConversationId: 'parent',
        toolCallId: 'call-1',
        task: 'a',
        label: 'a',
        assistant: _assistant(),
      );

      expect(chat.created, hasLength(1));
      expect(turn.started, hasLength(1));
      expect(
        (first as SubagentStarted).entry.childConversationId,
        (second as SubagentStarted).entry.childConversationId,
      );
      coordinator.dispose();
    });
  });

  group('delegate: the result message', () {
    test('one notice, keyed by the child, and it is not user input', () async {
      final chat = _FakeChat(<String, Conversation>{
        'parent': Conversation(
          id: 'parent',
          title: 'Chat',
          extras: const <String, dynamic>{
            WorkspaceBinding.keyId: 'ws-1',
            WorkspaceBinding.keyCwd: '/w',
          },
        ),
      });
      final coordinator = SubagentCoordinator(
        chat,
        clock: _clock(),
        pollInterval: const Duration(milliseconds: 1),
      )..attachHost(_host(chat));
      _turns(chat);
      await coordinator.begin(
        parentConversationId: 'parent',
        toolCallId: 'call-1',
        task: 'refactor auth',
        label: 'auth',
        assistant: _assistant(),
      );
      chat.repo.run = _run(
        state: GenerationRunState.completed,
        targetRevisionId: 'assistant-message',
      );
      await _settle();

      expect(chat.written, hasLength(1));
      final message = chat.written.single;
      expect(message.role, 'user');
      expect(
        message.id,
        SubagentResultPart.messageIdFor(
          message.conversationId == 'parent'
              ? chat.created.single.id
              : 'unreachable',
        ),
      );
      final part = message.parts.whereType<SubagentResultPart>().single;
      expect(part.outcome, 'completed');
      expect(part.label, 'auth');
      expect(part.elapsedMs, isNotNull);
      // The brief is the message text, so `content` carries it everywhere.
      expect(message.content, contains('auth'));
      expect(message.content, contains('three tests pass'));
      coordinator.dispose();
    });

    test(
      'a cancelled child writes a notice but does not wake the parent',
      () async {
        final chat = _FakeChat(<String, Conversation>{
          'parent': Conversation(
            id: 'parent',
            title: 'Chat',
            extras: const <String, dynamic>{
              WorkspaceBinding.keyId: 'ws-1',
              WorkspaceBinding.keyCwd: '/w',
            },
          ),
        });
        final coordinator = SubagentCoordinator(
          chat,
          clock: _clock(),
          pollInterval: const Duration(milliseconds: 1),
        );
        final wakes = _Wakes();
        coordinator.attachHost(_host(chat, wakes: wakes));
        _turns(chat);

        await coordinator.begin(
          parentConversationId: 'parent',
          toolCallId: 'call-1',
          task: 'x',
          label: 'x',
          assistant: _assistant(),
        );
        chat.repo.run = _run(state: GenerationRunState.cancelled);
        await _settle();

        expect(chat.written, hasLength(1));
        expect(
          chat.written.single.parts
              .whereType<SubagentResultPart>()
              .single
              .outcome,
          'cancelled',
        );
        expect(wakes.woken, isEmpty);
        coordinator.dispose();
      },
    );

    test(
      'a failed child wakes the parent, because one line is easy to miss',
      () async {
        final chat = _FakeChat(<String, Conversation>{
          'parent': Conversation(
            id: 'parent',
            title: 'Chat',
            extras: const <String, dynamic>{
              WorkspaceBinding.keyId: 'ws-1',
              WorkspaceBinding.keyCwd: '/w',
            },
          ),
        });
        final coordinator = SubagentCoordinator(
          chat,
          clock: _clock(),
          pollInterval: const Duration(milliseconds: 1),
        );
        final wakes = _Wakes();
        coordinator.attachHost(_host(chat, wakes: wakes));
        _turns(chat);

        await coordinator.begin(
          parentConversationId: 'parent',
          toolCallId: 'call-1',
          task: 'x',
          label: 'x',
          assistant: _assistant(),
        );
        chat.repo.run = _run(
          state: GenerationRunState.failed,
          errorCode: 'upstream_timeout',
        );
        await _settle();

        expect(
          chat.written.single.parts
              .whereType<SubagentResultPart>()
              .single
              .outcome,
          'failed',
        );
        expect(chat.written.single.content, contains('upstream_timeout'));
        expect(wakes.woken, hasLength(1));
        coordinator.dispose();
      },
    );

    test('a busy parent is not woken', () async {
      final chat = _FakeChat(<String, Conversation>{
        'parent': Conversation(
          id: 'parent',
          title: 'Chat',
          extras: const <String, dynamic>{
            WorkspaceBinding.keyId: 'ws-1',
            WorkspaceBinding.keyCwd: '/w',
          },
        ),
      });
      final coordinator = SubagentCoordinator(
        chat,
        clock: _clock(),
        pollInterval: const Duration(milliseconds: 1),
      );
      final wakes = _Wakes();
      coordinator.attachHost(_host(chat, canWake: false, wakes: wakes));
      _turns(chat);

      await coordinator.begin(
        parentConversationId: 'parent',
        toolCallId: 'call-1',
        task: 'x',
        label: 'x',
        assistant: _assistant(),
      );
      chat.repo.run = _run(state: GenerationRunState.completed);
      await _settle();

      expect(chat.written, hasLength(1));
      expect(wakes.woken, isEmpty);
      coordinator.dispose();
    });
  });

  group('delegate: the waiting state', () {
    test(
      'a child parked on a question reads as waiting, not running',
      () async {
        final chat = _FakeChat(<String, Conversation>{
          'parent': Conversation(
            id: 'parent',
            title: 'Chat',
            extras: const <String, dynamic>{
              WorkspaceBinding.keyId: 'ws-1',
              WorkspaceBinding.keyCwd: '/w',
            },
          ),
        });
        var waiting = false;
        final coordinator = SubagentCoordinator(
          chat,
          clock: _clock(),
          pollInterval: const Duration(milliseconds: 1),
        );
        coordinator.attachHost(_host(chat, isWaiting: () => waiting));
        _turns(chat);

        await coordinator.begin(
          parentConversationId: 'parent',
          toolCallId: 'call-1',
          task: 'x',
          label: 'x',
          assistant: _assistant(),
        );
        chat.repo.run = _run(state: GenerationRunState.waitingTool);
        await _settle();
        expect(coordinator.liveFor('parent').single.needsInput, isFalse);

        waiting = true;
        await _settle();
        expect(coordinator.liveFor('parent').single.needsInput, isTrue);
        // Waiting is not an outcome: nothing is written until the run ends.
        expect(chat.written, isEmpty);
        // And a wait returns instead of blocking, because only a person can
        // move this along.
        final parked = await coordinator.awaitJob(
          coordinator.liveFor('parent').single.childConversationId,
          timeout: const Duration(milliseconds: 50),
        );
        expect(parked['status'], 'waiting_for_input');
        expect(parked['reason'], 'answer');

        waiting = false;
        chat.repo.run = _run(state: GenerationRunState.completed);
        await _settle();
        expect(coordinator.liveFor('parent'), isEmpty);
        expect(chat.written, hasLength(1));
        coordinator.dispose();
      },
    );
  });

  group('delegate: cancellation', () {
    test('stopping the parent stops the child, and only a live one', () async {
      final chat = _FakeChat(<String, Conversation>{
        'parent': Conversation(
          id: 'parent',
          title: 'Chat',
          extras: const <String, dynamic>{
            WorkspaceBinding.keyId: 'ws-1',
            WorkspaceBinding.keyCwd: '/w',
          },
        ),
      });
      final cancelled = <String>[];
      final coordinator = SubagentCoordinator(
        chat,
        clock: _clock(),
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
          cancelTurn: (conversationId) async => cancelled.add(conversationId),
        ),
      );

      final start = await coordinator.begin(
        parentConversationId: 'parent',
        toolCallId: 'call-1',
        task: 'x',
        label: 'x',
        assistant: _assistant(),
      );
      final childId = (start as SubagentStarted).entry.childConversationId;

      await coordinator.cancelChild(childId);
      expect(cancelled, <String>[childId]);

      // A finished child is not cancelled again, and an unknown id is ignored.
      chat.repo.run = _run(state: GenerationRunState.cancelled);
      await _settle();
      await coordinator.cancelChild(childId);
      await coordinator.cancelChild('nobody');
      expect(cancelled, <String>[childId]);
      coordinator.dispose();
    });
  });
}

DateTime Function() _clock() {
  final start = DateTime(2026, 11, 21, 12);
  var now = start;
  return () => now = now.add(const Duration(seconds: 1));
}

/// Long enough for the watcher's poll loop to run at a 1 ms interval.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

Assistant _assistant() => Assistant(id: 'assistant-1', name: 'A');

GenerationRun _run({
  required GenerationRunState state,
  String targetRevisionId = 'assistant-message',
  String? errorCode,
}) {
  final at = DateTime(2026, 11, 21, 12);
  return GenerationRun(
    id: 'run-1',
    conversationId: 'child-1',
    targetRevisionId: targetRevisionId,
    state: state,
    stateRevision: 1,
    checkpointSeq: 0,
    errorCode: errorCode,
    createdAt: at,
    updatedAt: at,
    terminalAt: state.isTerminal ? at : null,
  );
}

class _Turns {
  final List<String> started = <String>[];
}

_Turns _turns(_FakeChat chat) {
  final turn = _Turns();
  chat.onStartTurn = (conversationId) => turn.started.add(conversationId);
  return turn;
}

/// Records the times the coordinator continued the parent conversation.
final class _Wakes {
  final List<String> woken = <String>[];
}

SubagentHost _host(
  _FakeChat chat, {
  bool canWake = true,
  bool Function()? isWaiting,
  _Wakes? wakes,
}) {
  final record = wakes ?? _Wakes();
  return SubagentHost(
    turnStarter:
        ({required conversationId, required assistant, required task}) async {
          chat.onStartTurn?.call(conversationId);
          return const SubagentTurnStart.started(runId: 'run-1');
        },
    parentWaker:
        ({
          required parentConversationId,
          required result,
          required assistant,
        }) async {
          record.woken.add(parentConversationId);
          return true;
        },
    canWake: (_) async => canWake,
    waitReasonFor: isWaiting == null
        ? null
        : (_) => isWaiting() ? SubagentWaitReason.answer : null,
  );
}

class _FakeRepository extends Fake implements ChatDatabaseRepository {
  GenerationRun? run;

  @override
  Future<GenerationRun?> getGenerationRun(String id) async => run;

  @override
  Future<ChatMessage?> getMessage(String id) async => ChatMessage(
    id: id,
    role: 'assistant',
    content: 'three tests pass',
    conversationId: 'child-1',
  );
}

class _FakeChat extends Fake implements ChatService {
  _FakeChat(this.conversations);

  final Map<String, Conversation> conversations;
  final List<Conversation> created = <Conversation>[];
  final List<ChatMessage> written = <ChatMessage>[];
  final _messages = <String, List<ChatMessage>>{};
  final _FakeRepository repo = _FakeRepository();
  void Function(String conversationId)? onStartTurn;

  @override
  Conversation? getConversation(String id) => conversations[id];

  @override
  bool isTemporaryConversation(String? id) =>
      id != null && _temporary.contains(id);

  final Set<String> _temporary = <String>{};

  /// Marks [id] as a temporary chat for the next delegation attempt.
  void markTemporary(String id) => _temporary.add(id);

  @override
  ChatDatabaseRepository get chatRepositoryOrNull => repo;

  @override
  Future<Conversation> createConversation({
    String? title,
    String? assistantId,
    String? groupChatId,
    bool activate = true,
    Map<String, dynamic>? extras,
  }) async {
    final conversation = Conversation(
      id: 'child-${created.length + 1}',
      title: title ?? 'title',
      assistantId: assistantId,
      extras: extras ?? const <String, dynamic>{},
    );
    created.add(conversation);
    conversations[conversation.id] = conversation;
    return conversation;
  }

  @override
  Future<void> addMessageDirectly(
    String conversationId,
    ChatMessage message,
  ) async {
    // Same guarantee as the real service: an id that is already there is a
    // redelivery, not a second row.
    if (written.any((existing) => existing.id == message.id)) return;
    written.add(message);
    _messages.putIfAbsent(conversationId, () => <ChatMessage>[]).add(message);
  }

  @override
  List<ChatMessage> getMessages(String conversationId) =>
      _messages[conversationId] ?? const <ChatMessage>[];
}
