import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/dsh/dsh_mux.dart';
import 'package:Cuplivo/core/dsh/dsh_terminal.dart';
import 'package:Cuplivo/features/harness/services/dsh_terminal_runtime.dart';

/// A `DshStream` stand-in: the terminal attachment only needs `items`,
/// `sendItem`, `cancel` and the stream identity fields.
class _FakeStream implements DshStream {
  final StreamController<Object?> _controller = StreamController<Object?>();
  final List<Map<String, Object?>> sentItems = <Map<String, Object?>>[];
  bool _closed = false;

  @override
  String get id => 'attach-1';

  @override
  String get endpoint => 'terminal/attach';

  @override
  Map<String, Object?> get args => const <String, Object?>{};

  @override
  bool get autoReopen => false;

  @override
  Stream<Object?> get items => _controller.stream;

  @override
  bool get isClosed => _closed;

  @override
  void sendItem(Map<String, Object?> value) => sentItems.add(value);

  @override
  Future<void> cancel() async {
    if (_closed) return;
    _closed = true;
    await _controller.close();
  }

  void emit(Object? value) => _controller.add(value);
}

DshTerminalEnvironment _environment({int maxInputBytes = 1024}) =>
    DshTerminalEnvironment(
      cwd: '/var/lib/dsh-e2e/workspace',
      maxInputBytes: maxInputBytes,
    );

DshTerminalInfo _info({String state = 'running', int? exitCode}) =>
    DshTerminalInfo.fromJson(<String, Object?>{
      'id': 'term-1',
      'title': 'bash',
      'cwd': '/var/lib/dsh-e2e/workspace',
      'cols': 80,
      'rows': 24,
      'state': state,
      if (exitCode != null) 'exitCode': exitCode,
    });

Future<void> _flush([int times = 3]) async {
  for (var i = 0; i < times; i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

DshPtySession _session(_FakeStream stream, {int maxInputBytes = 1024}) {
  return DshPtySession(
    attachment: DshTerminalAttachment(id: 'term-1', stream: stream),
    initialInfo: _info(),
    environment: _environment(maxInputBytes: maxInputBytes),
  );
}

void main() {
  test('snapshot replays the screen and output frames become bytes', () async {
    final stream = _FakeStream();
    final session = _session(stream);
    final chunks = <String>[];
    final subscription = session.output.listen(
      (bytes) => chunks.add(utf8.decode(bytes, allowMalformed: true)),
    );
    addTearDown(subscription.cancel);
    addTearDown(session.close);

    stream.emit(<String, Object?>{
      'type': 'snapshot',
      'sequence': 1,
      'screen': 'bash-5.2\$ ',
      'writable': true,
      'info': <String, Object?>{'id': 'term-1', 'title': 'bash'},
    });
    await _flush();
    expect(chunks, <String>['bash-5.2\$ ']);

    stream.emit(<String, Object?>{
      'type': 'output',
      'sequence': 2,
      'data': 'PROBE_OK\r\n',
    });
    await _flush();
    expect(chunks, <String>['bash-5.2\$ ', 'PROBE_OK\r\n']);
    expect(session.writable.value, isTrue);
    expect(session.info.value?.title, 'bash');
  });

  test('write and resize use consecutive uplink sequences', () async {
    final stream = _FakeStream();
    final session = _session(stream, maxInputBytes: 3);
    addTearDown(session.close);

    await session.write(Uint8List.fromList(utf8.encode('abcdef')));
    await session.resize(100, 30);

    expect(stream.sentItems, <Map<String, Object?>>[
      <String, Object?>{'type': 'write', 'sequence': 1, 'data': 'abc'},
      <String, Object?>{'type': 'write', 'sequence': 2, 'data': 'def'},
      <String, Object?>{
        'type': 'resize',
        'sequence': 3,
        'cols': 100,
        'rows': 30,
      },
    ]);
  });

  test('a read-only snapshot and a refused ack drop input', () async {
    final stream = _FakeStream();
    final session = _session(stream);
    addTearDown(session.close);

    stream.emit(<String, Object?>{
      'type': 'snapshot',
      'sequence': 1,
      'screen': '',
      'writable': false,
    });
    await _flush();
    expect(session.writable.value, isFalse);

    await session.write(Uint8List.fromList(utf8.encode('x')));
    await session.resize(90, 20);
    expect(
      stream.sentItems,
      isEmpty,
      reason: 'read-only terminals send no uplink',
    );

    // A writable attachment that later receives a refusal also stops sending.
    final otherStream = _FakeStream();
    final other = _session(otherStream);
    addTearDown(other.close);
    otherStream.emit(<String, Object?>{
      'type': 'ack',
      'sequence': 1,
      'refusal': 'read-only',
    });
    await _flush();
    expect(other.writable.value, isFalse);
    await other.write(Uint8List.fromList(utf8.encode('y')));
    expect(otherStream.sentItems, isEmpty);
  });

  test(
    'a state frame reports the process exit code and closes output',
    () async {
      final stream = _FakeStream();
      final session = _session(stream);
      var done = false;
      final subscription = session.output.listen(
        (_) {},
        onDone: () => done = true,
      );
      addTearDown(subscription.cancel);

      stream.emit(<String, Object?>{
        'type': 'state',
        'sequence': 4,
        'writable': false,
        'info': <String, Object?>{
          'id': 'term-1',
          'title': 'bash',
          'state': 'exited',
          'exitCode': 7,
        },
      });
      await _flush();

      expect(await session.exitCode, 7);
      expect(session.writable.value, isFalse);
      expect(done, isTrue);
    },
  );

  test('unknown frame types are tolerated', () async {
    final stream = _FakeStream();
    final session = _session(stream);
    addTearDown(session.close);

    stream.emit(<String, Object?>{'type': 'future-frame', 'value': 1});
    await _flush();
    expect(session.writable.value, isTrue);
  });

  test('closing detaches and completes the exit future', () async {
    final stream = _FakeStream();
    final session = _session(stream);

    await session.close();
    expect(await session.exitCode, 0);
    expect(stream.isClosed, isTrue);
  });
}
