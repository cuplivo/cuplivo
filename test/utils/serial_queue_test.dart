import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/utils/serial_queue.dart';

void main() {
  test(
    'tasks for one key run in submission order, never overlapping',
    () async {
      final queue = SerialQueue();
      final log = <String>[];
      var active = 0;
      var peak = 0;

      Future<void> task(String name) async {
        active += 1;
        peak = active > peak ? active : peak;
        log.add('start $name');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        log.add('end $name');
        active -= 1;
      }

      // The read-modify-write shape this exists for: without the chain, both
      // tasks would read the same pre-image.
      await Future.wait([
        queue.run('m1', () => task('a')),
        queue.run('m1', () => task('b')),
        queue.run('m1', () => task('c')),
      ]);

      expect(log, ['start a', 'end a', 'start b', 'end b', 'start c', 'end c']);
      expect(peak, 1, reason: 'two tasks must never be in flight for one key');
    },
  );

  test('different keys do not wait for each other', () async {
    final queue = SerialQueue();
    final gate = Completer<void>();
    final log = <String>[];

    final blocked = queue.run('m1', () async {
      await gate.future;
      log.add('m1 done');
    });
    final free = queue.run('m2', () async => log.add('m2 done'));

    await free;
    expect(log, ['m2 done'], reason: 'm2 must not queue behind m1');
    gate.complete();
    await blocked;
    expect(log, ['m2 done', 'm1 done']);
  });

  test(
    'a failing task reports to its caller and the chain keeps going',
    () async {
      final queue = SerialQueue();
      final log = <String>[];

      final failing = queue.run('m1', () async {
        log.add('first');
        throw StateError('boom');
      });
      final after = queue.run('m1', () async => log.add('second'));

      await expectLater(failing, throwsStateError);
      await after;
      expect(log, ['first', 'second']);
    },
  );

  test('the tail is dropped once a key is idle', () async {
    final queue = SerialQueue();
    await queue.run('m1', () async {});
    // The map is private; the observable contract is that the key can be reused
    // and still runs in order after the tail settles.
    final log = <String>[];
    await queue.run('m1', () async => log.add('again'));
    expect(log, ['again']);
  });
}
