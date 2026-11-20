import 'package:Cuplivo/core/dsh/dsh_endpoint.dart';
import 'package:Cuplivo/core/dsh/dsh_mux.dart';
import 'package:Cuplivo/core/dsh/dsh_rpc.dart';
import 'package:Cuplivo/core/dsh/dsh_session.dart';
import 'package:Cuplivo/core/dsh/dsh_terminal.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dsh_fakes.dart';

void main() {
  late FakeDshTransport transport;
  late DshMux mux;

  setUp(() {
    transport = FakeDshTransport(
      endpoint: DshEndpoint.parse('http://127.0.0.1:3080/?token=t'),
    );
    mux = DshMux(transport);
  });

  tearDown(() async {
    await mux.close();
  });

  DshSession session() => DshSession(
    sessionId: 'session-1',
    mux: mux,
    rpc: DshRpc(transport),
    transport: transport,
  );

  group('terminal frame decoding', () {
    test('decodes snapshot, output, state and ack frames', () {
      final snapshot = DshTerminalFrame.fromJson({
        'type': 'snapshot',
        'sequence': 1,
        'screen': r'$ ',
        'writable': true,
        'inputWindow': {'capacity': 4},
        'info': {
          'id': 't-1',
          'title': 'zsh',
          'state': 'running',
          'cols': 80,
          'rows': 24,
          'cwd': '/workspace/demo',
          'shell': {
            'path': '/bin/zsh',
            'args': ['-l'],
            'name': 'zsh',
          },
        },
      });
      final snapshotFrame = snapshot as DshTerminalSnapshotFrame;
      expect(snapshotFrame.sequence, 1);
      expect(snapshotFrame.screen, r'$ ');
      expect(snapshotFrame.writable, isTrue);
      expect(snapshotFrame.inputWindow, isNotNull);
      expect(snapshotFrame.info!.id, 't-1');
      expect(snapshotFrame.info!.isRunning, isTrue);
      expect(snapshotFrame.info!.shell!.path, '/bin/zsh');
      expect(snapshotFrame.info!.cols, 80);

      final output = DshTerminalFrame.fromJson({
        'type': 'output',
        'sequence': 2,
        'data': 'hello\r\n',
      });
      expect(output, isA<DshTerminalOutputFrame>());
      expect((output as DshTerminalOutputFrame).data, 'hello\r\n');
      expect(output.sequence, 2);

      final state = DshTerminalFrame.fromJson({
        'type': 'state',
        'writable': false,
        'info': {'id': 't-1', 'state': 'exited', 'exitCode': 0},
      });
      expect(state, isA<DshTerminalStateFrame>());
      expect(
        (state as DshTerminalStateFrame).info!.processState,
        DshTerminalProcessState.exited,
      );
      expect(state.info!.exitCode, 0);
      expect(state.writable, isFalse);

      final ack = DshTerminalFrame.fromJson({
        'type': 'ack',
        'sequence': 3,
        'refusal': 'read-only',
      });
      expect(ack, isA<DshTerminalAckFrame>());
      expect((ack as DshTerminalAckFrame).accepted, isFalse);
      expect(ack.refusal, 'read-only');
      expect(ack.sequence, 3);
    });

    test('tolerates alternate text keys and unknown frames', () {
      final output = DshTerminalFrame.fromJson({
        'type': 'output',
        'text': 'from text',
      });
      expect((output as DshTerminalOutputFrame).data, 'from text');

      final snapshot =
          DshTerminalFrame.fromJson({'type': 'snapshot', 'data': 'from data'})
              as DshTerminalSnapshotFrame;
      expect(snapshot.screen, 'from data');
      expect(snapshot.writable, isFalse);
      expect(snapshot.info, isNull);

      final unknown = DshTerminalFrame.fromJson({
        'type': 'something-new',
        'sequence': 9,
      });
      expect(unknown, isA<DshTerminalUnknownFrame>());
      expect((unknown as DshTerminalUnknownFrame).raw['type'], 'something-new');
      expect(unknown.sequence, 9);
    });

    test('parses environment, info and shells', () {
      final environment = DshTerminalEnvironment.fromJson({
        'cwd': '/workspace/demo',
        'maxInputBytes': 4096,
        'maxBufferedBytes': 65536,
        'maxCols': 200,
        'maxRows': 80,
        'scrollback': 5000,
      });
      expect(environment.cwd, '/workspace/demo');
      expect(environment.maxInputBytes, 4096);
      expect(environment.maxCols, 200);

      final shell = DshTerminalShell.fromJson({
        'path': '/bin/bash',
        'args': ['-l'],
        'name': 'bash',
      });
      expect(shell.path, '/bin/bash');
      expect(shell.args, ['-l']);

      final info = DshTerminalInfo.fromJson({
        'id': 't-2',
        'state': 'failed',
        'error': 'spawn failed',
      });
      expect(info.id, 't-2');
      expect(info.processState, DshTerminalProcessState.failed);
      expect(info.error, 'spawn failed');
      expect(info.stateRaw, 'failed');
    });
  });

  group('terminal uplink', () {
    test('DshStream.sendItem writes the mux item envelope', () async {
      final stream = await mux.open(
        dshTerminalAttachEndpoint,
        args: {'agentId': 'session-1', 'id': 't-1'},
      );
      stream.sendItem({'type': 'write', 'sequence': 1, 'data': 'ls\n'});
      stream.sendItem({
        'type': 'resize',
        'sequence': 2,
        'cols': 120,
        'rows': 40,
      });
      final sent = transport.sockets.single.sent;
      expect(
        sent,
        contains({
          'type': 'item',
          'streamId': stream.id,
          'value': {'type': 'write', 'sequence': 1, 'data': 'ls\n'},
        }),
      );
      expect(sent.last, {
        'type': 'item',
        'streamId': stream.id,
        'value': {'type': 'resize', 'sequence': 2, 'cols': 120, 'rows': 40},
      });
    });

    test('sendItem after close is a no-op', () async {
      final stream = await mux.open('terminal/attach');
      await stream.cancel();
      final before = transport.sockets.single.sent.length;
      stream.sendItem({'type': 'write', 'sequence': 1, 'data': 'x'});
      expect(transport.sockets.single.sent.length, before);
    });
  });

  group('DshSession terminal RPCs', () {
    test(
      'environment, create, list and close use the documented envelopes',
      () async {
        transport.values[dshTerminalEnvironmentEndpoint] = {
          'cwd': '/workspace/demo',
          'maxInputBytes': 4096,
          'maxBufferedBytes': 65536,
          'maxCols': 200,
          'maxRows': 80,
          'scrollback': 5000,
        };
        transport.values[dshTerminalCreateEndpoint] = {
          'id': 't-1',
          'title': 'zsh',
          'state': 'running',
          'cols': 100,
          'rows': 30,
          'cwd': '/workspace/demo',
        };
        transport.values[dshTerminalListEndpoint] = [
          {'id': 't-1', 'state': 'running'},
          {'id': 't-2', 'state': 'exited', 'exitCode': 0},
        ];
        transport.values[dshTerminalShellsEndpoint] = [
          {
            'path': '/bin/zsh',
            'args': ['-l'],
            'name': 'zsh',
          },
        ];
        transport.values[dshTerminalCloseEndpoint] = null;
        final view = session();

        final shells = await view.terminalShells();
        expect(shells.single.path, '/bin/zsh');
        final shellsPost = transport.posted.firstWhere(
          (post) => post['endpoint'] == dshTerminalShellsEndpoint,
        );
        expect(shellsPost['payload'], {
          'args': {'agentId': 'session-1'},
        });

        final environment = await view.terminalEnvironment();
        expect(environment.cwd, '/workspace/demo');
        expect(environment.maxCols, 200);

        final created = await view.createTerminal(
          cols: 100,
          rows: 30,
          id: 't-1',
          shellPath: '/bin/zsh',
        );
        expect(created.id, 't-1');

        final terminals = await view.listTerminals();
        expect(terminals.map((info) => info.id), ['t-1', 't-2']);

        await view.closeTerminal('t-1');
        expect(transport.posted.last['endpoint'], dshTerminalCloseEndpoint);

        final createPost = transport.posted.firstWhere(
          (post) => post['endpoint'] == dshTerminalCreateEndpoint,
        );
        expect(createPost['payload'], {
          'args': {
            'agentId': 'session-1',
            'request': {
              'id': 't-1',
              'cols': 100,
              'rows': 30,
              'shellPath': '/bin/zsh',
            },
          },
        });
        final environmentPost = transport.posted.firstWhere(
          (post) => post['endpoint'] == dshTerminalEnvironmentEndpoint,
        );
        expect(environmentPost['payload'], {
          'args': {'agentId': 'session-1'},
        });
        final listPost = transport.posted.firstWhere(
          (post) => post['endpoint'] == dshTerminalListEndpoint,
        );
        expect(listPost['payload'], {
          'args': {'sessionId': 'session-1'},
        });
      },
    );

    test('a generated create id is sent and attach opens the stream', () async {
      transport.values[dshTerminalCreateEndpoint] = {
        'id': 'server-chosen',
        'state': 'running',
      };
      transport.streamOpening[dshTerminalAttachEndpoint] = [
        {
          'type': 'snapshot',
          'sequence': 1,
          'screen': r'$ ',
          'writable': true,
          'info': {'id': 'server-chosen', 'state': 'running'},
        },
        {'type': 'output', 'sequence': 2, 'data': 'hi\r\n'},
        {'type': 'ack', 'sequence': 3, 'refusal': 'read-only'},
      ];
      final view = session();
      await view.createTerminal(cols: 80, rows: 24);
      final request =
          (transport.posted.firstWhere(
                    (post) => post['endpoint'] == dshTerminalCreateEndpoint,
                  )['payload']!
                  as Map)['args']!
              as Map;
      final requestBody = (request['request']! as Map);
      expect(requestBody['id'], isNotEmpty);
      expect(requestBody['shellPath'], isNull);

      final attachment = await view.attachTerminal('server-chosen');
      final frames = await attachment.frames.take(3).toList();
      expect(frames[0], isA<DshTerminalSnapshotFrame>());
      expect((frames[0] as DshTerminalSnapshotFrame).screen, r'$ ');
      expect(frames[1], isA<DshTerminalOutputFrame>());
      expect((frames[1] as DshTerminalOutputFrame).data, 'hi\r\n');
      expect(frames[2], isA<DshTerminalAckFrame>());
      expect((frames[2] as DshTerminalAckFrame).refusal, 'read-only');

      final open =
          transport.sockets.single.sent.firstWhere(
                (frame) =>
                    frame is Map &&
                    frame['type'] == 'open' &&
                    frame['endpoint'] == dshTerminalAttachEndpoint,
              )
              as Map;
      expect(open['payload'], {
        'args': {'agentId': 'session-1', 'id': 'server-chosen'},
      });
      await attachment.close();
      expect(attachment.isClosed, isTrue);
    });
  });
}
