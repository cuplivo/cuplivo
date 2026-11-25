import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/dsh/dsh_events.dart';
import 'package:Cuplivo/core/dsh/dsh_models.dart';
import 'package:Cuplivo/core/dsh/dsh_projection.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _fixture(String name) =>
    (jsonDecode(File('test/core/dsh/fixtures/$name').readAsStringSync()) as Map)
        .cast<String, Object?>();

List<DshSessionEvent> _durableEvents() =>
    (_fixture('durable_events.json')['events'] as List)
        .map(DshSessionEvent.fromJson)
        .toList(growable: false);

List<Object?> _followValues(String name) => File('test/core/dsh/fixtures/$name')
    .readAsLinesSync()
    .where((line) => line.trim().isNotEmpty)
    .map((line) => (jsonDecode(line) as Map)['value'])
    .toList(growable: false);

DshSessionSnapshot _emptySnapshot({Map<String, Object?> values = const {}}) {
  return DshSessionSnapshot.fromJson({
    'header': {
      'version': 4,
      'id': 'session-1',
      'createdAt': 1,
      'cwd': '/workspace/demo',
      'isSeeded': false,
      'agentPreset': 'standard',
    },
    'cursor': 0,
    'records': const [],
    'hasMore': false,
    'projections': {'asOfSeq': 0, 'values': values},
    'assistantStream': {'revision': 0},
  });
}

void main() {
  group('snapshot rebuild', () {
    test('rebuilds the visible transcript from records', () {
      final values = _followValues('follow_frames.jsonl');
      final snapshot = DshSessionSnapshot.fromJson(
        (values.first as Map).cast<String, Object?>(),
      );
      final transcript = DshTranscript()..applySnapshot(snapshot);
      expect(
        transcript.header!.id,
        'session-7f3c2a9e-0000-4000-8000-000000000001',
      );
      expect(transcript.rows, isEmpty);
      expect(transcript.permissionPreset, 'workspace-write');
      expect(transcript.projections.asOfSeq, 2);

      // Apply the live events after the snapshot.
      for (final value in values.skip(1)) {
        final map = (value as Map).cast<String, Object?>();
        if (map['type'] == 'event') {
          transcript.applyEvent(DshSessionEvent.fromJson(map['event']));
        } else if (map['type'] == 'assistant-stream') {
          transcript.applyAssistantFrame(
            DshAssistantStreamFrame.fromJson(map['frame']),
          );
        }
      }
      expect(transcript.rows, hasLength(2));
      expect(transcript.rows.first, isA<DshUserMessageRow>());
      expect(
        (transcript.rows.first as DshUserMessageRow).requestId,
        '66ac0d91-fe81-441d-8b38-c665decb002f',
      );
      final user = transcript.rows.first as DshUserMessageRow;
      expect(
        user.time,
        DateTime.fromMillisecondsSinceEpoch(1795110874469, isUtc: true),
      );
      final assistant = transcript.rows.last as DshAssistantMessageRow;
      expect(assistant.text, 'pong');
      expect(assistant.reasoning, '');
      expect(assistant.usage!.effectiveTotal, 8933);
      expect(
        assistant.time,
        DateTime.fromMillisecondsSinceEpoch(1795110875000, isUtc: true),
      );
      expect(transcript.isRunning, isFalse);
      expect(transcript.lastTurnReason!.isCompleted, isTrue);
      expect(transcript.draft, isNull);
    });

    test('a resume baseline rebuilds the in-flight draft', () {
      final transcript = DshTranscript()
        ..applySnapshot(
          DshSessionSnapshot.fromJson({
            'header': {'version': 4, 'id': 's1', 'createdAt': 1},
            'cursor': 10,
            'records': const [],
            'hasMore': false,
            'projections': {'asOfSeq': 10, 'values': {}},
            'assistantStream': {
              'revision': 5,
              'activeAttempt': {
                'attemptId': 's1:1',
                'startedAfterSeq': 10,
                'turn': 1,
                'step': 1,
                'nextIndex': 2,
                'stream': [
                  {
                    'type': 'chunk',
                    'time': 1795110874476,
                    'chunk': {
                      'type': 'block-start',
                      'index': 0,
                      'blockType': 'text',
                    },
                  },
                  {'type': 'text-delta', 'index': 0, 'text': 'hel'},
                ],
              },
            },
          }),
        );
      expect(transcript.draft, isNotNull);
      expect(transcript.draft!.turn, 1);
      expect(transcript.draft!.text, 'hel');
      expect(
        transcript.draft!.time,
        DateTime.fromMillisecondsSinceEpoch(1795110874476, isUtc: true),
      );
    });
  });

  group('durable events', () {
    late DshTranscript transcript;
    late List<DshSessionEvent> events;

    setUp(() {
      transcript = DshTranscript()..applySnapshot(_emptySnapshot());
      events = _durableEvents();
      for (final event in events) {
        transcript.applyEvent(event);
      }
    });

    test('tool call and result pair into one card', () {
      final tools = transcript.rows.whereType<DshToolRow>().toList();
      expect(tools, hasLength(1));
      expect(tools.single.callId, 'call_1');
      expect(tools.single.name, 'read');
      expect(tools.single.state, DshToolState.succeeded);
      expect(tools.single.resultText, 'hello from a probe');
      expect(tools.single.meta, {'path': '/workspace/demo/notes.txt'});
      expect(tools.single.approvalOutcome, DshApprovalOutcome.allowedOnce);
      expect(tools.single.decodedArguments, {
        'path': '/workspace/demo/notes.txt',
      });
      expect(
        tools.single.time,
        DateTime.fromMillisecondsSinceEpoch(1795110874500, isUtc: true),
        reason:
            'the card keeps the tool/call time after tool/result patches it',
      );
    });

    test(
      'assistant message is the durable answer, reasoning kept separately',
      () {
        final assistant = transcript.rows
            .whereType<DshAssistantMessageRow>()
            .single;
        expect(assistant.text, 'Pink pixel.');
        expect(assistant.reasoning, 'checking');
        expect(assistant.turn, 1);
        expect(assistant.step, 2);
        expect(assistant.usage!.inputTokens, 10);
        expect(
          assistant.time,
          DateTime.fromMillisecondsSinceEpoch(1795110874540, isUtc: true),
        );
      },
    );

    test('replacement assistant messages are not transcript rows', () {
      // seq 14 carries surfaceOp replacement; seq 7 is the visible message.
      expect(transcript.rows.whereType<DshAssistantMessageRow>(), hasLength(1));
      expect(
        transcript.rows.whereType<DshAssistantMessageRow>().single.text,
        'Pink pixel.',
      );
    });

    test('state events update projections, unknown events are ignored', () {
      expect(transcript.title, 'Probe title');
      expect(transcript.permissionPreset, 'read-only');
      expect(
        transcript.modelSelection,
        const DshModelSelection(
          provider: 'deepseek-official',
          model: 'deepseek-pro',
          reasoningEffort: 'high',
        ),
      );
      expect(transcript.projections.asOfSeq, 12);
      expect(transcript.lastTurnReason!.isCompleted, isTrue);
      expect(transcript.rows.every((row) => row.seq <= 9), isTrue);
    });

    test('a live producer updates the title synchronously', () {
      transcript.applyEvent(
        DshSessionEvent.fromJson({
          'type': 'session/title',
          'seq': 20,
          'data': {'title': 'Live title'},
        }),
      );
      expect(transcript.title, 'Live title');
      expect(transcript.projections.asOfSeq, 20);
    });

    test('a control projection frame patches one key', () {
      transcript.applyProjection('permissions', {
        'currentValue': 'danger-full-access',
      }, 15);
      expect(transcript.permissionPreset, 'danger-full-access');
      transcript.applyProjection('permissions', {
        'currentValue': 'read-only',
      }, 14);
      expect(
        transcript.permissionPreset,
        'danger-full-access',
        reason: 'stale frames are dropped',
      );
    });
  });

  group('live assistant frames', () {
    test('deltas accumulate across per-frame revisions', () {
      final transcript = DshTranscript()..applySnapshot(_emptySnapshot());
      final values = _followValues('follow_frames.jsonl');
      final frames = values
          .whereType<Map>()
          .where((map) => map['type'] == 'assistant-stream')
          .map((map) => DshAssistantStreamFrame.fromJson(map['frame']))
          .toList(growable: false);
      // Apply through the text deltas but not the end marker.
      for (final frame in frames) {
        if (frame is DshAssistantStreamEnd) break;
        transcript.applyAssistantFrame(frame);
      }
      expect(transcript.draft, isNotNull);
      expect(transcript.draft!.text, 'pong');
      expect(transcript.draft!.revision, 9);
      expect(transcript.draft!.usage!.outputTokens, 3);
      expect(
        transcript.draft!.time,
        DateTime.fromMillisecondsSinceEpoch(1795110874476, isUtc: true),
      );
      expect(transcript.isRunning, isTrue);
    });

    test('an end frame drops the draft; start of a new attempt resets it', () {
      final transcript = DshTranscript()..applySnapshot(_emptySnapshot());
      transcript.applyAssistantFrame(
        DshAssistantStreamFrame.fromJson({
          'type': 'start',
          'attemptId': 's1:1',
          'revision': 1,
          'turn': 1,
          'step': 1,
          'startedAfterSeq': 0,
        }),
      );
      transcript.applyAssistantFrame(
        DshAssistantStreamFrame.fromJson({
          'type': 'chunk',
          'attemptId': 's1:1',
          'revision': 2,
          'index': 1,
          'chunk': {'type': 'text-delta', 'index': 0, 'text': 'one'},
        }),
      );
      expect(transcript.draft!.text, 'one');
      transcript.applyAssistantFrame(
        DshAssistantStreamFrame.fromJson({
          'type': 'start',
          'attemptId': 's1:2',
          'revision': 1,
          'turn': 1,
          'step': 1,
          'startedAfterSeq': 3,
        }),
      );
      expect(transcript.draft!.text, isEmpty);
      expect(transcript.draft!.attemptId, 's1:2');

      transcript.applyAssistantFrame(
        DshAssistantStreamFrame.fromJson({
          'type': 'chunk',
          'attemptId': 's1:2',
          'revision': 2,
          'index': 1,
          'chunk': {'type': 'text-delta', 'index': 0, 'text': 'two'},
        }),
      );
      transcript.applyAssistantFrame(
        DshAssistantStreamFrame.fromJson({
          'type': 'end',
          'attemptId': 's1:2',
          'revision': 3,
          'index': 2,
          'outcome': {'kind': 'abandoned'},
        }),
      );
      expect(transcript.draft, isNull);
    });

    test('a stale frame from the previous attempt is ignored', () {
      final transcript = DshTranscript()..applySnapshot(_emptySnapshot());
      transcript.applyAssistantFrame(
        DshAssistantStreamFrame.fromJson({
          'type': 'start',
          'attemptId': 's1:2',
          'revision': 5,
          'turn': 2,
          'step': 1,
          'startedAfterSeq': 9,
        }),
      );
      transcript.applyAssistantFrame(
        DshAssistantStreamFrame.fromJson({
          'type': 'chunk',
          'attemptId': 's1:1',
          'revision': 6,
          'index': 1,
          'chunk': {'type': 'text-delta', 'index': 0, 'text': 'stale'},
        }),
      );
      expect(transcript.draft!.text, isEmpty);
    });

    test('tool call deltas surface a live tool call', () {
      final transcript = DshTranscript()..applySnapshot(_emptySnapshot());
      // Chunks belong to an attempt: the start/baseline must precede them.
      transcript.applyAssistantFrame(
        DshAssistantStreamFrame.fromJson({
          'type': 'start',
          'attemptId': 's1:1',
          'revision': 1,
          'turn': 1,
          'step': 1,
          'startedAfterSeq': 0,
        }),
      );
      transcript.applyAssistantFrame(
        DshAssistantStreamFrame.fromJson({
          'type': 'chunk',
          'attemptId': 's1:1',
          'revision': 2,
          'index': 1,
          'time': 1795110874476,
          'chunk': {
            'type': 'tool-call-delta',
            'index': 0,
            'id': 'call_9',
            'name': 'read',
            'argumentsDelta': '{"path":',
          },
        }),
      );
      transcript.applyAssistantFrame(
        DshAssistantStreamFrame.fromJson({
          'type': 'chunk',
          'attemptId': 's1:1',
          'revision': 3,
          'index': 2,
          'chunk': {
            'type': 'tool-call-delta',
            'index': 0,
            'id': 'call_9',
            'argumentsDelta': '"/x"}',
          },
        }),
      );
      final call = transcript.draft!.toolCalls.single;
      expect(call.id, 'call_9');
      expect(call.name, 'read');
      expect(call.arguments, '{"path":"/x"}');
    });
  });

  group('host requests', () {
    test('pending approvals and questions track add/cancel/decide', () {
      final transcript = DshTranscript()..applySnapshot(_emptySnapshot());
      transcript.applyHostEvent(
        DshApprovalRequest.fromJson(
          eventId: 'a1',
          sessionId: 's1',
          request: {'toolName': 'shell'},
        ),
      );
      transcript.applyHostEvent(
        DshUserQuestionRequest.fromJson(
          eventId: 'q1',
          sessionId: 's1',
          request: {
            'questions': [
              {
                'id': 'q1',
                'question': 'Pick a color',
                'options': [
                  {'label': 'Blue'},
                  {'label': 'Green'},
                ],
              },
            ],
          },
        ),
      );
      expect(transcript.awaitingInput, isTrue);
      expect(transcript.pendingApprovals.single.toolName, 'shell');
      expect(
        transcript.pendingQuestions.single.questions.single.question,
        'Pick a color',
      );

      transcript.applyEvent(
        DshSessionEvent.fromJson({
          'type': 'approval/decided',
          'seq': 1,
          'data': {'id': 'a1', 'outcome': 'rejected'},
        }),
      );
      expect(transcript.pendingApprovals, isEmpty);
      expect(transcript.decidedApprovals.single.eventId, 'a1');

      transcript.applyHostEvent(const DshHostRequestCancelled(eventId: 'q1'));
      expect(transcript.pendingQuestions, isEmpty);
      expect(transcript.awaitingInput, isFalse);
    });
  });

  group('history prepend', () {
    test('older rows are inserted in seq order before live rows', () {
      final transcript = DshTranscript()..applySnapshot(_emptySnapshot());
      transcript.applyEvent(
        DshSessionEvent.fromJson({
          'type': 'user/message',
          'seq': 10,
          'data': {
            'content': [
              {'type': 'text', 'text': 'newer'},
            ],
            'source': {'kind': 'user'},
            'role': 'user',
            'id': 'm2',
          },
        }),
      );
      transcript.prepend([
        DshSessionEvent.fromJson({
          'type': 'user/message',
          'seq': 1,
          'data': {
            'content': [
              {'type': 'text', 'text': 'older'},
            ],
            'source': {'kind': 'user'},
            'role': 'user',
            'id': 'm1',
          },
        }),
      ]);
      expect(transcript.rows, hasLength(2));
      expect((transcript.rows.first as DshUserMessageRow).text, 'older');
      expect((transcript.rows.last as DshUserMessageRow).text, 'newer');
      // Duplicate prepends are ignored.
      transcript.prepend([
        DshSessionEvent.fromJson({
          'type': 'user/message',
          'seq': 1,
          'data': {
            'content': [
              {'type': 'text', 'text': 'older'},
            ],
            'source': {'kind': 'user'},
            'role': 'user',
            'id': 'm1',
          },
        }),
      ]);
      expect(transcript.rows, hasLength(2));
    });
  });
}
