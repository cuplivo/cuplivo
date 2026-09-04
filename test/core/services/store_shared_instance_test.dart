import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/assistant_memory.dart';
import 'package:Cuplivo/core/models/world_book.dart';
import 'package:Cuplivo/core/services/memory_store.dart';
import 'package:Cuplivo/core/services/quick_instruction_store.dart';
import 'package:Cuplivo/core/services/world_book_store.dart';

/// The stores bind their static `shared` instance to the FIRST facade they
/// see; a reused facade would leak object caches across tests, so every test
/// here must pass a freshly created `BusinessPreferences.memoryForTests()`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Business store shared accessor', () {
    test('WorldBookStore.shared is bound to one facade per isolate', () {
      final prefs = BusinessPreferences.memoryForTests();
      expect(
        identical(WorldBookStore.shared(prefs), WorldBookStore.shared(prefs)),
        isTrue,
      );

      final otherPrefs = BusinessPreferences.memoryForTests();
      expect(
        identical(
          WorldBookStore.shared(prefs),
          WorldBookStore.shared(otherPrefs),
        ),
        isFalse,
      );
    });

    test('MemoryStore.shared is bound to one facade per isolate', () {
      final prefs = BusinessPreferences.memoryForTests();
      expect(
        identical(MemoryStore.shared(prefs), MemoryStore.shared(prefs)),
        isTrue,
      );

      final otherPrefs = BusinessPreferences.memoryForTests();
      expect(
        identical(MemoryStore.shared(prefs), MemoryStore.shared(otherPrefs)),
        isFalse,
      );
    });

    test('QuickInstructionStore.shared is bound to one facade per isolate', () {
      final prefs = BusinessPreferences.memoryForTests();
      expect(
        identical(
          QuickInstructionStore.shared(prefs),
          QuickInstructionStore.shared(prefs),
        ),
        isTrue,
      );

      final otherPrefs = BusinessPreferences.memoryForTests();
      expect(
        identical(
          QuickInstructionStore.shared(prefs),
          QuickInstructionStore.shared(otherPrefs),
        ),
        isFalse,
      );
    });

    test(
      'deletion through one shared reference cannot be resurrected by another',
      () async {
        final prefs = BusinessPreferences.memoryForTests();
        final store = WorldBookStore.shared(prefs);
        await store.save(const [
          WorldBook(id: 'w1', name: 'w1'),
          WorldBook(id: 'w2', name: 'w2'),
        ]);

        // "Provider" and "trash-coordinator" views: same shared instance.
        final providerView = WorldBookStore.shared(prefs);
        await providerView.delete('w2');

        // Restoring another book must not write back the stale snapshot.
        await store.add(const WorldBook(id: 'w3', name: 'w3'));

        final all = await WorldBookStore.shared(prefs).getAll();
        expect(all.map((e) => e.id), containsAll(['w1', 'w3']));
        expect(all.map((e) => e.id), isNot(contains('w2')));
      },
    );

    test('memory add ids never duplicate across consumers', () async {
      final prefs = BusinessPreferences.memoryForTests();
      final sharedStore = MemoryStore.shared(prefs);

      final results = await Future.wait([
        sharedStore.add(assistantId: 'a1', content: 'm1'),
        sharedStore.add(assistantId: 'a1', content: 'm2'),
        sharedStore.add(assistantId: 'a1', content: 'm3'),
      ]);

      final ids = results.map((m) => m.id).toSet();
      expect(ids.length, results.length);
      expect((await MemoryStore.shared(prefs).getAll()).length, results.length);
    });

    test('saveAll (restore) and add serialize without corrupt state', () async {
      final prefs = BusinessPreferences.memoryForTests();
      final store = MemoryStore.shared(prefs);
      await store.saveAll(const [
        AssistantMemory(id: 1, assistantId: 'a1', content: 'existing'),
      ]);

      await Future.wait([
        store.saveAll(const [
          AssistantMemory(id: 1, assistantId: 'a1', content: 'existing'),
          AssistantMemory(id: 2, assistantId: 'a1', content: 'restored'),
        ]),
        store.add(assistantId: 'a1', content: 'added'),
      ]);

      final all = await store.getAll();
      // Either order is legal (restore-after-add drops the added record), but
      // the mutation lock must never leave duplicate ids or a partial list.
      expect(all.map((m) => m.id).toSet().length, all.length);
      expect(all.map((m) => m.content), contains('restored'));
      expect(all.every((m) => m.id > 0), isTrue);
      expect(all.length, inInclusiveRange(2, 3));
    });
  });
}
