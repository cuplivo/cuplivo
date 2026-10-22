import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/app_exit_flush.dart';

void main() {
  tearDown(() {
    AppExitFlush.debugReset();
    AppShutdown.debugReset();
  });

  test('flushAll invokes every registered handler in order', () async {
    final calls = <String>[];
    AppExitFlush.register(() async => calls.add('first'));
    AppExitFlush.register(() async => calls.add('second'));

    await AppExitFlush.flushAll();

    expect(calls, <String>['first', 'second']);
  });

  test('unregister removes a handler', () async {
    final calls = <String>[];
    Future<void> gone() async => calls.add('gone');
    AppExitFlush.register(gone);
    AppExitFlush.unregister(gone);

    await AppExitFlush.flushAll();
    expect(calls, isEmpty);
  });

  test('flushAll skips a failing handler and still runs the rest', () async {
    final calls = <String>[];
    AppExitFlush.register(() async => throw StateError('boom'));
    AppExitFlush.register(() async => calls.add('after'));

    await AppExitFlush.flushAll();

    expect(calls, <String>['after']);
  });

  // The two registries answer different questions: a flush drains writes and
  // also runs for a window that only hides (close to tray), while a shutdown
  // gives up process-owned resources. Keeping them apart is what stops a
  // hiding window from closing the LAN sync listener — that, and nothing else,
  // is #1036.
  group('AppShutdown', () {
    test('runs its handlers in order', () async {
      final calls = <String>[];
      AppShutdown.register(() async => calls.add('first'));
      AppShutdown.register(() async => calls.add('second'));

      await AppShutdown.runAll();

      expect(calls, <String>['first', 'second']);
    });

    test('skips a failing handler and still runs the rest', () async {
      final calls = <String>[];
      AppShutdown.register(() async => throw StateError('boom'));
      AppShutdown.register(() async => calls.add('after'));

      await AppShutdown.runAll();

      expect(calls, <String>['after']);
    });

    test('unregister removes a handler', () async {
      final calls = <String>[];
      Future<void> gone() async => calls.add('gone');
      AppShutdown.register(gone);
      AppShutdown.unregister(gone);

      await AppShutdown.runAll();

      expect(calls, isEmpty);
    });

    test('a flush does not run shutdown handlers', () async {
      final calls = <String>[];
      AppShutdown.register(() async => calls.add('shutdown'));

      await AppExitFlush.flushAll();

      expect(
        calls,
        isEmpty,
        reason: 'a hiding window flushes; it must not tear resources down',
      );
    });

    test('a shutdown does not run flush handlers', () async {
      final calls = <String>[];
      AppExitFlush.register(() async => calls.add('flush'));

      await AppShutdown.runAll();

      expect(calls, isEmpty);
    });
  });
}
