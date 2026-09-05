import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/backup/backup_activity_gate.dart';

void main() {
  group('BackupActivityGate', () {
    test('a later gated operation waits until the holder completes', () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final secondStarted = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });

      final first = BackupActivityGate.scoped(() async {
        started.complete();
        await release.future;
      });

      final second = BackupActivityGate.scoped(() async {
        secondStarted.complete();
      });

      await started.future;
      expect(secondStarted.isCompleted, isFalse, reason: 'must be exclusive');
      release.complete();
      await first;
      await second;
      expect(secondStarted.isCompleted, isTrue);
    });

    test('re-entrant call along the same chain does not deadlock', () async {
      late String order;
      final outer = BackupActivityGate.scoped(() async {
        order = 'outer-start';
        await BackupActivityGate.scoped(() async {
          order = '$order/nested';
        });
        order = '$order/outer-end';
      });
      await outer;
      expect(order, 'outer-start/nested/outer-end');
    });

    test('queued operations resume FIFO in arrival order', () async {
      final release = Completer<void>();
      final log = <int>[];

      final first = BackupActivityGate.scoped(() async {
        await release.future;
        log.add(1);
      });
      final second = BackupActivityGate.scoped(() async => log.add(2));
      final third = BackupActivityGate.scoped(() async => log.add(3));
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });

      await Future<void>.delayed(Duration.zero);
      release.complete();
      await Future.wait([first, second, third]);
      expect(log, [1, 2, 3]);
    });
  });
}
