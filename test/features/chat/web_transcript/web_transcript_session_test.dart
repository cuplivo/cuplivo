import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/chat/web_transcript/web_transcript_session.dart';

void main() {
  test('encodes commands and completes only matching ACKs', () async {
    final encoded = <String>[];
    final session = WebTranscriptSession(
      sendEncoded: (value) async => encoded.add(value),
      onEvent: (_) {},
      onFatal: (_) => fail('must not fail'),
    );
    addTearDown(session.dispose);
    session.startNewEpoch();

    final sent = session.send('hello', const <String, Object?>{});
    await Future<void>.delayed(Duration.zero);
    final command =
        jsonDecode(utf8.decode(base64Decode(encoded.single)))
            as Map<String, dynamic>;
    expect(command['epoch'], session.epoch);
    expect(command['sequence'], 1);
    expect(command['type'], 'hello');

    session.receive(
      jsonEncode(<String, Object?>{
        'version': 1,
        'epoch': session.epoch,
        'type': 'ack',
        'commandId': command['id'],
        'payload': const <String, Object?>{},
      }),
    );
    await sent;
  });

  test('ignores stale epoch events', () {
    var delivered = 0;
    final session = WebTranscriptSession(
      sendEncoded: (_) async {},
      onEvent: (_) => delivered++,
      onFatal: (_) => fail('must not fail'),
    );
    addTearDown(session.dispose);
    session.startNewEpoch();
    session.receive(
      jsonEncode(<String, Object?>{
        'version': 1,
        'epoch': session.epoch - 1,
        'type': 'viewport',
        'payload': const <String, Object?>{},
      }),
    );
    expect(delivered, 0);
  });

  test('critical ACK timeout triggers visible-fallback callback', () async {
    final fatal = Completer<Object>();
    final session = WebTranscriptSession(
      sendEncoded: (_) async {},
      onEvent: (_) {},
      onFatal: fatal.complete,
      ackTimeout: const Duration(milliseconds: 10),
    );
    addTearDown(session.dispose);
    session.startNewEpoch();
    final sent = session.send(
      'hello',
      const <String, Object?>{},
      fatalOnFailure: true,
    );
    await expectLater(sent, throwsA(isA<TimeoutException>()));
    expect(await fatal.future, isA<TimeoutException>());
  });
}
