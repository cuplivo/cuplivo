import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/models/assistant_memory.dart';
import 'package:Cuplivo/core/services/memory_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MemoryStore', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await MemoryStore.saveAll(<AssistantMemory>[]);
    });

    test(
      'parallel add() assigns unique ids without losing records (#478)',
      () async {
        final results = await Future.wait([
          MemoryStore.add(assistantId: 'a1', content: 'm1'),
          MemoryStore.add(assistantId: 'a1', content: 'm2'),
          MemoryStore.add(assistantId: 'a1', content: 'm3'),
          MemoryStore.add(assistantId: 'a1', content: 'm4'),
        ]);

        final ids = results.map((m) => m.id).toSet();
        expect(
          ids.length,
          results.length,
          reason: 'parallel adds must not share ids',
        );

        final all = await MemoryStore.getAll();
        final stored = all.where((m) => m.assistantId == 'a1').toList();
        expect(
          stored.length,
          results.length,
          reason: 'no record may be overwritten',
        );
        expect(stored.map((m) => m.id).toSet().length, results.length);
        expect(stored.map((m) => m.id), everyElement(isPositive));
      },
    );

    test('parallel add() continues from existing ids monotonically', () async {
      await MemoryStore.add(assistantId: 'a1', content: 'existing');

      final results = await Future.wait([
        MemoryStore.add(assistantId: 'a1', content: 'm1'),
        MemoryStore.add(assistantId: 'a1', content: 'm2'),
        MemoryStore.add(assistantId: 'a1', content: 'm3'),
      ]);

      final ids = results.map((m) => m.id).toSet();
      expect(ids.length, results.length);
      expect(ids, isNot(contains(1)));
    });

    test('parallel add and delete serialize without lost updates', () async {
      final first = await MemoryStore.add(assistantId: 'a1', content: 'm1');

      await Future.wait([
        MemoryStore.add(assistantId: 'a1', content: 'm2'),
        MemoryStore.delete(id: first.id),
      ]);

      final all = await MemoryStore.getAll();
      final stored = all.where((m) => m.assistantId == 'a1').toList();
      expect(
        stored.length,
        1,
        reason: 'exactly one record must survive either order',
      );
      expect(stored.single.content, 'm2');
    });
  });
}
