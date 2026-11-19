import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/dsh/dsh_events.dart';
import 'package:Cuplivo/core/dsh/dsh_models.dart';
import 'package:flutter_test/flutter_test.dart';

List<Map<String, Object?>> _jsonl(String name) {
  final file = File('test/core/dsh/fixtures/$name');
  return file
      .readAsLinesSync()
      .where((line) => line.trim().isNotEmpty)
      .map((line) => (jsonDecode(line) as Map).cast<String, Object?>())
      .toList(growable: false);
}

Map<String, Object?> _fixture(String name) =>
    (jsonDecode(File('test/core/dsh/fixtures/$name').readAsStringSync()) as Map)
        .cast<String, Object?>();

void main() {
  group('follow snapshot', () {
    test('parses header, projections, records and assistant baseline', () {
      final frames = _jsonl('follow_frames.jsonl');
      final snapshot = DshSessionSnapshot.fromJson(
        (frames.first['value'] as Map).cast<String, Object?>(),
      );
      expect(snapshot.header.id, startsWith('session-7f3c2a9e'));
      expect(snapshot.header.version, 4);
      expect(snapshot.header.isReadable, isTrue);
      expect(snapshot.cursor, 2);
      expect(snapshot.hasMore, isFalse);
      expect(snapshot.records, hasLength(3));
      expect(snapshot.records[0], isA<DshPermissionPresetEvent>());
      expect(snapshot.records[1], isA<DshSandboxModeEvent>());
      expect(snapshot.records[2], isA<DshApprovalPolicyEvent>());
      expect(snapshot.projections.title, isNull);
      expect(snapshot.projections.permissionsCurrent, 'workspace-write');
      expect(snapshot.projections.imageLimits.maxImagesPerMessage, 20);
      expect(snapshot.assistantStream.revision, 0);
      expect(snapshot.assistantStream.activeAttempt, isNull);
    });

    test('parses the durable events and the live assistant attempt', () {
      final frames = _jsonl('follow_frames.jsonl');
      final events = <DshSessionEvent>[];
      final assistant = <DshAssistantStreamFrame>[];
      for (final frame in frames) {
        final value = (frame['value'] as Map).cast<String, Object?>();
        switch (value['type']) {
          case 'event':
            events.add(DshSessionEvent.fromJson(value['event']));
          case 'assistant-stream':
            assistant.add(DshAssistantStreamFrame.fromJson(value['frame']));
        }
      }
      expect(
        events.map((event) => event.type),
        containsAll([
          'user/message',
          'turn/start',
          'step/start',
          'assistant/message',
          'step/end',
          'turn/end',
        ]),
      );
      final user =
          events.firstWhere((e) => e is DshUserMessageEvent)
              as DshUserMessageEvent;
      expect(user.isHumanPrompt, isTrue);
      expect(
        user.message.source.requestId,
        '66ac0d91-fe81-441d-8b38-c665decb002f',
      );
      final assistantMessage =
          events.firstWhere((e) => e is DshAssistantMessageEvent)
              as DshAssistantMessageEvent;
      expect(assistantMessage.message.text, 'pong');
      expect(assistantMessage.usage!.effectiveTotal, 8933);
      final turnEnd =
          events.firstWhere((e) => e is DshTurnEnded) as DshTurnEnded;
      expect(turnEnd.reason.isCompleted, isTrue);

      expect(assistant.first, isA<DshAssistantStreamStart>());
      expect(assistant.first.revision, 1);
      expect(assistant.whereType<DshAssistantStreamChunkFrame>(), hasLength(9));
      final textDeltas = assistant
          .whereType<DshAssistantStreamChunkFrame>()
          .where((frame) => frame.chunk is DshTextDeltaChunk)
          .map((frame) => (frame.chunk as DshTextDeltaChunk).text)
          .join();
      expect(textDeltas, 'pong');
      final end = assistant.last as DshAssistantStreamEnd;
      expect(end.outcome, isA<DshAssistantStreamCommitted>());
      expect((end.outcome as DshAssistantStreamCommitted).seq, 6);
    });

    test('parses durable tool/approval events from the fixture', () {
      final events = (_fixture('durable_events.json')['events'] as List)
          .map(DshSessionEvent.fromJson)
          .toList(growable: false);
      final toolCall =
          events.firstWhere((e) => e is DshToolCallEvent) as DshToolCallEvent;
      expect(toolCall.callId, 'call_1');
      expect(toolCall.name, 'read');
      expect(toolCall.arguments, contains('notes.txt'));

      final toolResult =
          events.firstWhere((e) => e is DshToolResultEvent)
              as DshToolResultEvent;
      expect(toolResult.callId, 'call_1');
      expect(toolResult.message.text, 'hello from a probe');
      expect(toolResult.isError, isFalse);
      expect(toolResult.meta, {'path': '/workspace/demo/notes.txt'});

      final asked =
          events.firstWhere((e) => e is DshApprovalAskedEvent)
              as DshApprovalAskedEvent;
      expect(asked.id, 'approval-1');
      expect(asked.callId, 'call_1');
      final decided =
          events.firstWhere((e) => e is DshApprovalDecidedEvent)
              as DshApprovalDecidedEvent;
      expect(decided.outcome, DshApprovalOutcome.allowedOnce);
    });

    test('unknown events parse as an opaque append row', () {
      final unknown = DshSessionEvent.fromJson({
        'type': 'plugin/something-new',
        'seq': 42,
        'time': 1,
        'data': {'x': 1},
      });
      expect(unknown, isA<DshUnknownSessionEvent>());
      expect(unknown.seq, 42);
      expect(unknown.isAppendOrigin, isTrue);
    });

    test('a replacement surfaceOp is not append origin', () {
      final events = (_fixture('durable_events.json')['events'] as List)
          .map(DshSessionEvent.fromJson)
          .toList(growable: false);
      final replacement = events.last;
      expect(replacement.type, 'assistant/message');
      expect(replacement.surfaceOp, isNull);
      expect(replacement.isAppendOrigin, isFalse);
    });
  });

  group(r'$events frames', () {
    test('parses ready, emit, waterfall and cancel', () {
      final frames = _jsonl('host_frames.jsonl');
      final events = frames
          .map((frame) => DshHostEvent.fromJson(frame['value']))
          .toList(growable: false);

      final ready = events.first as DshHostReady;
      expect(ready.clientId, 'client-1');
      expect(ready.home, '/home/demo');

      final added = events[1] as DshHostEmit;
      expect(added.event, 'api-session/added');
      expect(added.sessionSummary!.sessionId, startsWith('session-7f3c2a9e'));
      expect(added.sessionSummary!.title, 'Pong');

      final status = events[2] as DshHostEmit;
      expect(status.running, isTrue);

      final approval = events[3] as DshApprovalRequest;
      expect(approval.eventId, 'approval-1');
      expect(approval.sessionId, startsWith('session-7f3c2a9e'));
      expect(approval.toolName, 'shell');
      expect(approval.callId, 'call_1');
      expect(approval.describe(), 'Allow the shell command?');

      final question = events[4] as DshUserQuestionRequest;
      expect(question.questions.single.id, 'q1');
      expect(question.questions.single.options.map((o) => o.label), [
        'Blue',
        'Green',
      ]);

      final cancelled = events[5] as DshHostRequestCancelled;
      expect(cancelled.eventId, 'finding-later');

      expect(events[6], isA<DshHostUnknown>());
    });

    test('approval answers are plain strings in the audit vocabulary', () {
      final approval = DshHostEvent.fromJson({
        'type': 'waterfall',
        'event': 'approval/request',
        'eventId': 'a1',
        'agentId': 's1',
        'request': {'toolName': 'shell'},
      });
      expect(approval, isA<DshApprovalRequest>());
      expect(DshApprovalDecision.allowOnce.wire, 'allowed-once');
      expect(DshApprovalDecision.reject.wire, 'rejected');
      expect(DshApprovalDecision.pass.wire, 'next');
    });

    test('question answers serialize to the wire object', () {
      expect(const DshQuestionAnswer(id: 'q1', selected: ['Blue']).toJson(), {
        'id': 'q1',
        'selected': ['Blue'],
      });
      expect(
        const DshQuestionAnswer(
          id: 'q1',
          selected: ['Other'],
          custom: 'teal',
        ).toJson(),
        {
          'id': 'q1',
          'selected': ['Other'],
          'custom': 'teal',
        },
      );
    });
  });

  group('workspace updates and control frames', () {
    test('parses each workspace increment', () {
      final baseline = DshWorkspaceUpdate.tryParse({
        'type': 'baseline',
        'value': {
          'items': [
            {
              'workspaceId': 'w1',
              'path': '/workspace/demo',
              'title': 'Demo',
              'sessionIds': ['s1'],
            },
          ],
          'archivedSessionIds': ['s2'],
          'pinnedSessionIds': ['s1'],
        },
      });
      expect(baseline, isA<DshWorkspaceBaselineUpdate>());
      final value = (baseline as DshWorkspaceBaselineUpdate).baseline;
      expect(value.items.single.title, 'Demo');
      expect(value.archivedSessionIds, ['s2']);
      expect(value.pinnedSessionIds, ['s1']);

      expect(
        DshWorkspaceUpdate.tryParse({'type': 'remove', 'workspaceId': 'w1'}),
        isA<DshWorkspaceRemoveUpdate>(),
      );
      expect(DshWorkspaceUpdate.tryParse({'type': 'future'}), isNull);
    });
  });

  group('model parsing', () {
    test('message parts tolerate unknown block types', () {
      final message = DshMessage.fromJson({
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'hi'},
          {'type': 'tool-addition', 'toolName': 'x'},
          {
            'type': 'image',
            'attachment': {
              'attachmentId': 'sha256:00',
              'mediaType': 'image/png',
            },
          },
        ],
        'source': {'kind': 'model'},
        'id': 'm1',
      });
      expect(message.parts[1], isA<DshUnknownPart>());
      expect(message.text, 'hi');
      expect(message.images.single.mediaType, 'image/png');
    });

    test('model catalog parses groups, defaults and failures', () {
      final values = _fixture('catalog_values.json');
      final catalog = DshModelCatalog.fromJson(values['session/modelCatalog']);
      expect(
        catalog.defaultSelection,
        const DshModelSelection(
          provider: 'deepseek-official',
          model: 'deepseek-flash',
          reasoningEffort: 'off',
        ),
      );
      expect(catalog.groups.single.name, 'DeepSeek');
      expect(
        catalog.groups.single.models.first.reasoning!.efforts,
        hasLength(2),
      );
      expect(catalog.failures.single.id, 'amazon-bedrock');
      expect(
        catalog.model('deepseek-official', 'deepseek-pro')?.name,
        'DeepSeek-Pro',
      );
    });

    test('localized plugin text resolves locale, language then en', () {
      final text = DshLocalizedText.fromJson({'en': 'Title', 'zh': '标题'});
      expect(text.resolve('en'), 'Title');
      expect(text.resolve('zh-CN'), '标题');
      expect(text.resolve('fr'), 'Title');
    });
  });
}
