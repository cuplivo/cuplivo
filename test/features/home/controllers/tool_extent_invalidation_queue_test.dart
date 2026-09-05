import 'package:Cuplivo/features/home/controllers/tool_extent_invalidation_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('enqueue keeps work pending while detached', () {
    final queue = ToolExtentInvalidationQueue();

    expect(queue.enqueue('m1'), isTrue);
    expect(queue.hasPending, isTrue);
    expect(queue.pendingIds, ['m1']);

    // The controller is still detached: the queue must keep the id and tell
    // the caller to poll again instead of losing it.
    final result = queue.takeForFlush(isAttached: false, isLocked: false);
    expect(result.ids, isEmpty);
    expect(result.reschedule, isTrue);
    expect(queue.hasPending, isTrue);
  });

  test('locked layout keeps work pending until unlocked', () {
    final queue = ToolExtentInvalidationQueue();
    queue.enqueue('m1');
    queue.enqueue('m2');

    final locked = queue.takeForFlush(isAttached: true, isLocked: true);
    expect(locked.ids, isEmpty);
    expect(locked.reschedule, isTrue);
    expect(queue.hasPending, isTrue);

    var unlocked = queue.takeForFlush(isAttached: true, isLocked: false);
    expect(unlocked.reschedule, isFalse);
    expect(unlocked.ids, ['m1', 'm2']);
    expect(queue.hasPending, isFalse);

    // Nothing left: an idle poll must not ask for another round.
    final idle = queue.takeForFlush(isAttached: true, isLocked: false);
    expect(idle.ids, isEmpty);
    expect(idle.reschedule, isFalse);
  });

  test('duplicate enqueue coalesces and drops the redundant flush', () {
    final queue = ToolExtentInvalidationQueue();

    expect(queue.enqueue('m1'), isTrue);
    expect(queue.enqueue('m1'), isFalse);
    expect(queue.pendingIds, ['m1']);

    final drained = queue.takeForFlush(isAttached: true, isLocked: false);
    expect(drained.ids, ['m1']);
  });

  test('drain order follows enqueue order', () {
    final queue = ToolExtentInvalidationQueue();
    queue.enqueue('a');
    queue.enqueue('b');
    queue.enqueue('c');

    final result = queue.takeForFlush(isAttached: true, isLocked: false);
    expect(result.ids, ['a', 'b', 'c']);
  });

  test('clear drops everything without error', () {
    final queue = ToolExtentInvalidationQueue();
    queue.enqueue('m1');
    queue.clear();

    expect(queue.hasPending, isFalse);
    final result = queue.takeForFlush(isAttached: true, isLocked: false);
    expect(result.ids, isEmpty);
    expect(result.reschedule, isFalse);
  });
}
