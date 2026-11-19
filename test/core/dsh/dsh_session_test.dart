import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:Cuplivo/core/dsh/dsh_endpoint.dart';
import 'package:Cuplivo/core/dsh/dsh_events.dart';
import 'package:Cuplivo/core/dsh/dsh_models.dart';
import 'package:Cuplivo/core/dsh/dsh_mux.dart';
import 'package:Cuplivo/core/dsh/dsh_rpc.dart';
import 'package:Cuplivo/core/dsh/dsh_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dsh_fakes.dart';

Future<void> waitFor(bool Function() condition, {int tries = 100}) async {
  for (var i = 0; i < tries; i += 1) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition not met in time');
}

List<Object?> _followValues() =>
    File('test/core/dsh/fixtures/follow_frames.jsonl')
        .readAsLinesSync()
        .where((line) => line.trim().isNotEmpty)
        .map((line) => (jsonDecode(line) as Map)['value'])
        .toList(growable: false);

Map<String, Object?> _snapshot() =>
    (_followValues().first as Map).cast<String, Object?>();

String _streamId(FakeDshSocket socket, String endpoint) {
  final frame = socket.sent.cast<Map?>().firstWhere(
    (item) => item != null && item['endpoint'] == endpoint,
  )!;
  return '${frame['streamId']}';
}

void main() {
  late FakeDshTransport transport;
  late DshMux mux;
  late DshSession session;

  setUp(() async {
    transport = FakeDshTransport(
      endpoint: DshEndpoint.parse('http://127.0.0.1:3080/?token=t'),
    );
    transport.streamOpening['session/follow'] = [_snapshot()];
    mux = DshMux(transport, options: const DshMuxOptions(retryDelay: _zero));
    session = DshSession(
      sessionId: 'session-7f3c2a9e-0000-4000-8000-000000000001',
      mux: mux,
      rpc: DshRpc(transport),
      transport: transport,
    );
    await session.watch();
  });

  tearDown(() async {
    await session.dispose();
    await mux.close();
  });

  test(
    'watch() delivers the snapshot first and then contiguous events',
    () async {
      final updates = <DshSessionUpdate>[];
      final sub = session.updates.listen(updates.add);
      expect(session.snapshot!.cursor, 2);
      expect(session.lastEventSeq, 2);

      final socket = transport.sockets.single;
      final streamId = _streamId(socket, 'session/follow');
      for (final value in _followValues().skip(1)) {
        final map = (value as Map).cast<String, Object?>();
        if (map['type'] == 'event') {
          socket.pushItem(streamId, map);
        } else if (map['type'] == 'assistant-stream') {
          socket.pushItem(streamId, map);
        }
      }
      await waitFor(
        () => updates.whereType<DshSessionEventUpdate>().length == 6,
      );
      final events = updates
          .whereType<DshSessionEventUpdate>()
          .map((u) => u.event)
          .toList();
      expect(events.map((event) => event.seq), [3, 4, 5, 6, 7, 8]);
      expect(session.lastEventSeq, 8);
      expect(updates.whereType<DshSessionAssistantFrameUpdate>(), isNotEmpty);

      // Duplicate delivery of the same seq is dropped.
      final before = events.length;
      socket.pushItem(streamId, {
        'type': 'event',
        'event': {
          'type': 'step/end',
          'seq': 8,
          'data': {'turn': 1, 'step': 1},
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(updates.whereType<DshSessionEventUpdate>().length, before);
      await sub.cancel();
    },
  );

  test('a live seq jump is gap-filled from session/page first', () async {
    transport.values['session/page'] = {
      'records': [
        {
          'type': 'event',
          'event': {
            'type': 'step/end',
            'seq': 3,
            'data': {'turn': 1, 'step': 1},
          },
        },
        {
          'type': 'event',
          'event': {
            'type': 'user/message',
            'seq': 4,
            'data': {
              'content': [
                {'type': 'text', 'text': 'gap'},
              ],
              'source': {'kind': 'user'},
              'role': 'user',
              'id': 'gap-1',
            },
          },
        },
      ],
      'hasMore': false,
    };
    final closed = <String>[];
    final sub = session.updates.listen((update) {
      if (update is DshSessionEventUpdate) closed.add(update.event.type);
    });
    final socket = transport.sockets.single;
    final streamId = _streamId(socket, 'session/follow');
    socket.pushItem(streamId, {
      'type': 'event',
      'event': {
        'type': 'turn/end',
        'seq': 5,
        'data': {
          'turn': 1,
          'reason': {'kind': 'completed'},
        },
      },
    });
    await waitFor(() => closed.length == 3);
    expect(closed, ['step/end', 'user/message', 'turn/end']);
    expect(transport.posted.single['endpoint'], 'session/page');
    expect(transport.posted.single['payload'], {
      'args': {
        'request': {
          'address': {
            'kind': 'session',
            'sessionId': 'session-7f3c2a9e-0000-4000-8000-000000000001',
          },
          'beforeSeq': 5,
          'maxMessages': 60,
          'turnWindow': {'minMessages': 100, 'minTurns': 10},
        },
      },
    });
    await sub.cancel();
  });

  test('only this session\'s host requests are forwarded', () async {
    final updates = <DshSessionHostRequestUpdate>[];
    final sub = session.updates.listen((update) {
      if (update is DshSessionHostRequestUpdate) updates.add(update);
    });
    final socket = transport.sockets.single;
    socket.pushItem('events', {
      'type': 'waterfall',
      'event': 'approval/request',
      'eventId': 'a-other',
      'agentId': 'session-other',
      'request': {'toolName': 'shell'},
    });
    socket.pushItem('events', {
      'type': 'waterfall',
      'event': 'approval/request',
      'eventId': 'a-mine',
      'agentId': 'session-7f3c2a9e-0000-4000-8000-000000000001',
      'request': {'toolName': 'shell'},
    });
    await waitFor(() => updates.isNotEmpty);
    expect(updates.single.event, isA<DshApprovalRequest>());
    expect((updates.single.event as DshApprovalRequest).eventId, 'a-mine');
    await sub.cancel();
  });

  test('prompt sends text, inline images and file receipts', () async {
    transport.values['session/prompt'] = {'accepted': true};
    final receipt = await session.prompt(
      DshPrompt(
        text: 'Describe this',
        images: [
          DshImageInput(
            bytes: Uint8List.fromList([1, 2, 3]),
            mediaType: 'image/png',
            name: 'one.png',
          ),
        ],
        files: const [DshFileInput('receipt-1')],
      ),
    );
    expect(receipt.accepted, isTrue);
    expect(receipt.requestId, isNotEmpty);

    final request =
        (transport.posted.single['payload'] as Map)['args']['request'] as Map;
    expect(request['sessionId'], session.sessionId);
    expect(request['mode'], 'queue');
    expect(request['clientTimeZone'], 'UTC');
    expect(request['requestId'], receipt.requestId);
    final content = (request['content'] as List).cast<Map>();
    expect(content[0], {'type': 'text', 'text': 'Describe this'});
    expect(content[1], {
      'type': 'image',
      'mediaType': 'image/png',
      'name': 'one.png',
      'data': 'AQID',
    });
    expect(content[2], {'type': 'file', 'receiptId': 'receipt-1'});
  });

  test('prompt rejects an empty payload', () {
    expect(() => session.prompt(const DshPrompt()), throwsArgumentError);
  });

  test('approval and question answers use the waterfall protocol', () async {
    transport.values[r'$events/result'] = const {};
    final socket = transport.sockets.single;
    socket.pushItem('events', {
      'type': 'waterfall',
      'event': 'approval/request',
      'eventId': 'a1',
      'agentId': session.sessionId,
      'request': {'toolName': 'shell'},
    });
    await waitFor(() => mux.pendingRequests.isNotEmpty);
    await session.answerApproval('a1', DshApprovalDecision.allowOnce);
    expect(transport.posted.single['payload'], {
      'args': {
        'clientId': 'client-1',
        'eventId': 'a1',
        'outcome': {'kind': 'result', 'value': 'allowed-once'},
      },
    });

    socket.pushItem('events', {
      'type': 'waterfall',
      'event': 'user-questions/request',
      'eventId': 'q1',
      'agentId': session.sessionId,
      'request': {
        'questions': [
          {'id': 'q1', 'question': 'Pick'},
        ],
      },
    });
    await waitFor(() => mux.pendingRequests.any((r) => r.eventId == 'q1'));
    await session.answerQuestions('q1', [
      const DshQuestionAnswer(id: 'q1', selected: ['Blue']),
    ]);
    expect(transport.posted.last['payload'], {
      'args': {
        'clientId': 'client-1',
        'eventId': 'q1',
        'outcome': {
          'kind': 'result',
          'value': {
            'answers': [
              {
                'id': 'q1',
                'selected': ['Blue'],
              },
            ],
          },
        },
      },
    });
  });

  test(
    'cancel, permission and model changes use their documented endpoints',
    () async {
      transport.values['session/cancel'] = {'accepted': true};
      await session.cancel();
      expect(transport.posted.last['endpoint'], 'session/cancel');
      expect(transport.posted.last['payload'], {
        'args': {
          'request': {'sessionId': session.sessionId},
        },
      });

      transport.values['commands/execute'] = {
        'commandId': 'c1',
        'result': {'kind': 'success'},
      };
      await session.setPermission('read-only');
      expect(transport.posted.last['payload'], {
        'args': {
          'agentId': session.sessionId,
          'line': '/permission read-only',
          'submittedAttachments': <Object?>[],
        },
      });

      transport.values['session/selectModel'] = {
        'selected': {'provider': 'deepseek-official', 'model': 'deepseek-pro'},
      };
      final selected = await session.setModel(
        const DshModelSelection(
          provider: 'deepseek-official',
          model: 'deepseek-pro',
        ),
      );
      expect(selected.model, 'deepseek-pro');
      expect(transport.posted.last['payload'], {
        'args': {
          'request': {
            'sessionId': session.sessionId,
            'provider': 'deepseek-official',
            'model': 'deepseek-pro',
          },
        },
      });
    },
  );

  test(
    'uploadAttachment posts octet-stream bytes and returns the receipt',
    () async {
      final receipt = await session.uploadAttachment(
        Uint8List.fromList([9, 8, 7]),
        name: 'notes.txt',
      );
      expect(receipt.receiptId, 'receipt-1');
      expect(receipt.file!.name, 'notes.txt');
      final request = transport.requests.single;
      expect(request.method, 'POST');
      expect(
        request.uri.toString(),
        'http://127.0.0.1:3080/api/session/uploadFileBinary?sessionId='
        'session-7f3c2a9e-0000-4000-8000-000000000001&name=notes.txt',
      );
      expect(request.body, [9, 8, 7]);
    },
  );

  test('loadOlder pages before the oldest loaded seq', () async {
    transport.values['session/page'] = {
      'records': [
        {
          'type': 'event',
          'event': {
            'type': 'user/message',
            'seq': -2,
            'data': {
              'content': [
                {'type': 'text', 'text': 'older'},
              ],
              'source': {'kind': 'user'},
              'role': 'user',
              'id': 'old-1',
            },
          },
        },
      ],
      'hasMore': true,
    };
    final page = await session.loadOlder();
    expect(page.events.single.seq, -2);
    expect(page.hasMore, isTrue);
    expect(transport.posted.single['payload'], {
      'args': {
        'request': {
          'address': {'kind': 'session', 'sessionId': session.sessionId},
          'beforeSeq': 0,
          'maxMessages': 60,
          'turnWindow': {'minMessages': 100, 'minTurns': 10},
        },
      },
    });
  });

  test(
    'DshSessionStore folds updates into a transcript and notifies',
    () async {
      final store = DshSessionStore(
        session: DshSession(
          sessionId: 'session-7f3c2a9e-0000-4000-8000-000000000002',
          mux: mux,
          rpc: DshRpc(transport),
          transport: transport,
        ),
      );
      transport.streamOpening['session/follow'] = [_snapshot()];
      var changes = 0;
      final sub = store.changes.listen((_) => changes += 1);
      await store.start(activate: true);

      expect(store.transcript.snapshot, isNotNull);
      expect(store.transcript.permissionPreset, 'workspace-write');
      expect(changes, greaterThan(0));
      expect(store.isRunning, isFalse);
      await sub.cancel();
      await store.dispose();
    },
  );
}

Duration _zero(int attempt) => Duration.zero;
