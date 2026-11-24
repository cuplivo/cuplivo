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
    test('a conversation without a workspace still delegates', () async {
      // The child inherits whatever the parent has, including nothing: an
      // unbound parent gets an unbound child rather than a refusal, because
      // "no files" is a smaller problem than "the tool does not exist here".
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

      expect(start, isA<SubagentStarted>());
      final created = chat.created.single;
      expect(created.extras[WorkspaceBinding.keyId], isNull);
      expect(created.extras[SubagentExtrasKeys.parent], 'parent');
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
      final wakes = _Wakes();
      final coordinator = SubagentCoordinator(
        chat,
        clock: _clock(),
        pollInterval: const Duration(milliseconds: 1),
      )..attachHost(_host(chat, wakes: wakes));
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

      // Written when the child finishes, so a process killed while the app is in
      // the background still leaves the divider, and handed to the queue in the
      // same breath so the parent may be continued.
      expect(chat.written, hasLength(1));
      final message = chat.written.single;
      expect(wakes.enqueued.single.id, message.id);
      expect(message.role, 'user');
      expect(
        message.id,
        SubagentResultPart.messageIdFor(
          message.conversationId == 'parent'
              ? chat.created.single.id
              : 'unreachable',
          // One result row per segment: the row is keyed by the run that
          // produced it, so a continued delegation writes a second one.
          runId: 'run-1',
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
      'a cancelled child leaves its row queued but asks for no continuation',
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

        // The row lands, because the timeline is where "it stopped" is visible;
        // no generation is spent explaining the user's own Stop.
        expect(chat.written, hasLength(1));
        expect(wakes.followUps.single, isFalse);
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
          wakes.enqueued.single.parts
              .whereType<SubagentResultPart>()
              .single
              .outcome,
          'failed',
        );
        expect(wakes.enqueued.single.content, contains('upstream_timeout'));
        expect(wakes.woken, hasLength(1));
        coordinator.dispose();
      },
    );

    test('a busy parent still gets the result queued', () async {
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
      chat.repo.run = _run(state: GenerationRunState.completed);
      await _settle();

      // Nothing is dropped when the parent is busy: the row is written and the
      // queue holds the continuation until the turn ends. The coordinator does not
      // ask whether it may land.
      expect(wakes.enqueued, hasLength(1));
      expect(chat.written, hasLength(1));
      coordinator.dispose();
    });
  });

  group('delegate: the waiting state', () {
    test('a child parked on a question reads as waiting, not running', () async {
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
      // The run state alone says "parked": `waitingTool` means the child is
      // blocked on the user whatever the probe can see. The probe only decides
      // which sentence the strip shows, and its silence falls back to the
      // generic one.
      expect(coordinator.liveFor('parent').single.needsInput, isTrue);
      expect(
        coordinator.liveFor('parent').single.waitReason,
        SubagentWaitReason.answer,
      );

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
      coordinator.dispose();
    });
  });

  group('delegate: a turn that waits', () {
    test('gets the result instead of a notice, and nothing is written', () async {
      // The turn already receives the conclusion as a tool result. Writing the
      // notice as well would put the same report into the next request twice and
      // leave a divider the user has to read past for no new information.
      final chat = _FakeChat(<String, Conversation>{
        'parent': Conversation(id: 'parent', title: 'Chat'),
      });
      final coordinator = SubagentCoordinator(
        chat,
        clock: _clock(),
        pollInterval: const Duration(milliseconds: 1),
      )..attachHost(_host(chat));

      final start = await coordinator.begin(
        parentConversationId: 'parent',
        toolCallId: 'call-1',
        task: 'summarise the repo',
        label: 'summary',
        assistant: _assistant(),
      );
      // The run has to exist before the first poll, or the watcher reads it as a
      // deleted conversation and finishes the entry as interrupted.
      chat.repo.run = _run(state: GenerationRunState.requesting);
      final childId = (start as SubagentStarted).entry.childConversationId;

      final wait = coordinator.awaitJob(childId);
      await _settle();
      chat.repo.run = _run(state: GenerationRunState.completed);
      await _settle();

      final result = await wait;
      expect(result['status'], 'completed');
      expect((result['payload'] as Map)['text'], isNotEmpty);
      expect(chat.written, isEmpty);
      expect(coordinator.liveFor('parent'), isEmpty);
      coordinator.dispose();
    });
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
          enqueueResult:
              ({
                required parentConversationId,
                required notice,
                required assistant,
                required followUp,
              }) {},
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

  group('delegate: mail and the model’s stop', () {
    SubagentHost mailHost(_Wakes wakes, {void Function(String)? onCancel}) =>
        SubagentHost(
          turnStarter:
              ({
                required conversationId,
                required assistant,
                required task,
              }) async => const SubagentTurnStart.started(runId: 'run-1'),
          enqueueResult:
              ({
                required parentConversationId,
                required notice,
                required assistant,
                required followUp,
              }) {
                wakes.woken.add(parentConversationId);
                wakes.enqueued.add(notice);
                wakes.followUps.add(followUp);
              },
          enqueueMail: ({required conversationId, required message}) {
            wakes.woken.add(conversationId);
            wakes.enqueued.add(message);
          },
          cancelTurn: (conversationId) async => onCancel?.call(conversationId),
        );

    Future<SubagentStarted> startChild(SubagentCoordinator coordinator) async {
      final start = await coordinator.begin(
        parentConversationId: 'parent',
        toolCallId: 'call-1',
        task: 'refactor auth',
        label: 'auth',
        assistant: _assistant(),
      );
      return start as SubagentStarted;
    }

    test(
      'a delegator’s message lands in the child and is queued there',
      () async {
        final chat = _FakeChat(<String, Conversation>{
          'parent': Conversation(id: 'parent', title: 'Chat'),
        });
        final wakes = _Wakes();
        final coordinator = SubagentCoordinator(
          chat,
          clock: _clock(),
          pollInterval: const Duration(milliseconds: 1),
        )..attachHost(mailHost(wakes));
        final start = await startChild(coordinator);
        final childId = start.entry.childConversationId;

        final result = await coordinator.sendToChild(
          parentConversationId: 'parent',
          jobId: childId,
          text: 'use YAML',
          assistant: _assistant(),
          toolCallId: 'call-2',
        );

        expect(result['status'], 'delivered');
        // The host in this test cannot see a running turn, so the answer says the
        // message starts one. The branch itself is the host's word, not a state
        // this coordinator invents.
        expect(result['delivery'], 'turn_started');
        final row = chat.written.single;
        expect(row.conversationId, childId);
        expect(row.role, 'user');
        expect(
          row.parts.whereType<SubagentMailPart>().single.from,
          SubagentMailSender.delegator,
        );
        // The row stores the body. The model-facing "The delegator sent a
        // message:" sentence is added when the request is built, so the
        // transcript and the exports do not carry an English prefix.
        expect(row.content, 'use YAML');
        expect(wakes.enqueued.single.id, row.id);
        coordinator.dispose();
      },
    );

    test('a job that is not this conversation’s child is refused', () async {
      final chat = _FakeChat(<String, Conversation>{
        'parent': Conversation(id: 'parent', title: 'Chat'),
        'stranger': Conversation(
          id: 'stranger',
          title: 'Elsewhere',
          extras: const <String, dynamic>{SubagentExtrasKeys.parent: 'other'},
        ),
      });
      final coordinator = SubagentCoordinator(chat, clock: _clock())
        ..attachHost(mailHost(_Wakes()));

      final result = await coordinator.sendToChild(
        parentConversationId: 'parent',
        jobId: 'stranger',
        text: 'hello',
        assistant: _assistant(),
        toolCallId: 'call-2',
      );

      expect(result['status'], 'rejected');
      expect(result['reason'], 'not_found');
      expect(chat.written, isEmpty);
      coordinator.dispose();
    });

    test(
      'a child writes into its delegator, marked as the subagent’s',
      () async {
        final chat = _FakeChat(<String, Conversation>{
          'parent': Conversation(id: 'parent', title: 'Chat'),
        });
        final wakes = _Wakes();
        final coordinator = SubagentCoordinator(chat, clock: _clock())
          ..attachHost(mailHost(wakes));
        final start = await startChild(coordinator);
        chat.written.clear();

        final result = await coordinator.sendToParent(
          childConversationId: start.entry.childConversationId,
          text: 'the token is in .env',
          toolCallId: 'call-3',
        );

        expect(result['status'], 'delivered');
        final row = chat.written.single;
        expect(row.conversationId, 'parent');
        expect(
          row.parts.whereType<SubagentMailPart>().single.from,
          SubagentMailSender.subagent,
        );
        // Body only, like the other direction.
        expect(row.content, 'the token is in .env');
        expect(wakes.woken.single, 'parent');
        coordinator.dispose();
      },
    );

    test(
      'the model’s stop writes no row and does not wake the parent',
      () async {
        final chat = _FakeChat(<String, Conversation>{
          'parent': Conversation(id: 'parent', title: 'Chat'),
        });
        final wakes = _Wakes();
        final cancelled = <String>[];
        final coordinator = SubagentCoordinator(
          chat,
          clock: _clock(),
          pollInterval: const Duration(milliseconds: 1),
        )..attachHost(mailHost(wakes, onCancel: cancelled.add));
        final start = await startChild(coordinator);
        final childId = start.entry.childConversationId;

        final accepted = await coordinator.interruptChild(
          parentConversationId: 'parent',
          jobId: childId,
        );
        expect(accepted['status'], 'accepted');
        expect(cancelled, <String>[childId]);

        // The run row cannot say who stopped it; the coordinator's flag can.
        chat.repo.run = _run(state: GenerationRunState.cancelled);
        await _settle();

        // The model asked for the stop and got `accepted`; a divider would tell
        // it what it just did, and there is no conclusion to hand over.
        expect(wakes.enqueued, isEmpty);
        expect(chat.written, isEmpty);
        expect(start.entry.phase, SubagentPhase.stopped);
        coordinator.dispose();
      },
    );

    test('the user’s stop stays final', () async {
      final chat = _FakeChat(<String, Conversation>{
        'parent': Conversation(id: 'parent', title: 'Chat'),
      });
      final coordinator = SubagentCoordinator(
        chat,
        clock: _clock(),
        pollInterval: const Duration(milliseconds: 1),
      )..attachHost(mailHost(_Wakes()));
      final start = await startChild(coordinator);

      chat.repo.run = _run(state: GenerationRunState.cancelled);
      await _settle();

      final result = await coordinator.sendToChild(
        parentConversationId: 'parent',
        jobId: start.entry.childConversationId,
        text: 'one more thing',
        assistant: _assistant(),
        toolCallId: 'call-4',
      );
      expect(result['status'], 'rejected');
      expect(result['reason'], 'not_continuable');
      coordinator.dispose();
    });

    test('a finished child is continued instead of refused', () async {
      final chat = _FakeChat(<String, Conversation>{
        'parent': Conversation(id: 'parent', title: 'Chat'),
      });
      final coordinator = SubagentCoordinator(
        chat,
        clock: _clock(),
        pollInterval: const Duration(milliseconds: 1),
      )..attachHost(mailHost(_Wakes()));
      final start = await startChild(coordinator);

      chat.repo.run = _run(state: GenerationRunState.completed);
      await _settle();
      expect(start.entry.phase, SubagentPhase.completed);

      final result = await coordinator.sendToChild(
        parentConversationId: 'parent',
        jobId: start.entry.childConversationId,
        text: 'and the tests',
        assistant: _assistant(),
        toolCallId: 'call-5',
      );
      expect(result['status'], 'delivered');
      expect(start.entry.phase, SubagentPhase.running);
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

/// Records what the coordinator handed to the parent's queue.
final class _Wakes {
  final List<String> woken = <String>[];
  final List<ChatMessage> enqueued = <ChatMessage>[];
  final List<bool> followUps = <bool>[];
}

SubagentHost _host(
  _FakeChat chat, {
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
    enqueueResult:
        ({
          required parentConversationId,
          required notice,
          required assistant,
          required followUp,
        }) {
          record.woken.add(parentConversationId);
          record.enqueued.add(notice);
          record.followUps.add(followUp);
        },
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
  Future<GenerationRun?> latestGenerationRun(String conversationId) async =>
      run;

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
