import 'dart:convert';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_preferences_store.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/models/quick_instruction.dart';
import 'package:Cuplivo/core/models/quick_phrase.dart';
import 'package:Cuplivo/core/services/quick_instruction_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('QuickInstructionStore legacy migration', () {
    test('upgrades legacy injections and materializes empty titles', () async {
      final preferences = BusinessPreferences.memoryForTests({
        QuickInstructionStore.itemsKey: jsonEncode([
          {
            'id': 'legacy-learning',
            'title': '   ',
            'prompt': 'learning prompt',
            'group': '',
          },
          {
            'id': 'legacy-empty',
            'title': '',
            'prompt': 'other prompt',
            'group': 'Legacy',
          },
        ]),
      });
      final store = QuickInstructionStore(preferences);

      final items = await store.getAll();

      expect(items.map((item) => item.title), ['Learning Mode', 'Untitled']);
      expect(
        items.map((item) => item.placement),
        everyElement(QuickInstructionPlacement.systemPrompt),
      );
      expect(items.map((item) => item.toolPolicy.enabled), everyElement(false));
    });

    test(
      'merges global and assistant phrases with deterministic suffixes',
      () async {
        final preferences = BusinessPreferences.memoryForTests({
          QuickInstructionStore.itemsKey: jsonEncode([
            {
              'id': 'injection-1',
              'title': 'Focus',
              'prompt': 'system prompt',
              'group': 'Original',
            },
          ]),
          QuickInstructionStore.legacyQuickPhrasesKey: jsonEncode([
            const QuickPhrase(
              id: 'phrase-global',
              title: ' Focus ',
              content: 'global phrase',
            ).toJson(),
            const QuickPhrase(
              id: 'phrase-assistant',
              title: 'Focus',
              content: 'assistant phrase',
              isGlobal: false,
              assistantId: 'assistant-1',
            ).toJson(),
            const QuickPhrase(
              id: 'phrase-case-sensitive',
              title: 'focus',
              content: 'case-sensitive phrase',
            ).toJson(),
          ]),
        });
        final store = QuickInstructionStore(preferences);

        await store.migrateLegacyQuickPhrases(
          assistantNames: const {'assistant-1': 'Writer'},
        );
        final items = await store.getAll();

        expect(items.map((item) => item.title), [
          'Focus-Instruction Injection',
          'Focus-Global Quick Phrase',
          'Focus-(Writer) Quick Phrase',
          'focus',
        ]);
        expect(items.first.group, 'Original');
        expect(
          items.skip(1).map((item) => item.group),
          everyElement(QuickInstructionStore.migratedQuickPhraseGroup),
        );
        expect(
          items.skip(1).map((item) => item.placement),
          everyElement(QuickInstructionPlacement.inputBox),
        );
        expect(
          preferences.getBool(QuickInstructionStore.migrationReceiptKey),
          isTrue,
        );
        expect(
          preferences.getString(QuickInstructionStore.legacyQuickPhrasesKey),
          isNull,
        );

        final migratedIds = items.map((item) => item.id).toList();
        store.invalidateCache();
        await store.migrateLegacyQuickPhrases(
          assistantNames: const {'assistant-1': 'Writer'},
        );
        expect((await store.getAll()).map((item) => item.id), migratedIds);
      },
    );

    test(
      'failed source removal keeps legacy data and retry does not duplicate',
      () async {
        final backend = _FailingRemoveStore({
          QuickInstructionStore.itemsKey: jsonEncode([
            {
              'id': 'injection-1',
              'title': 'System',
              'prompt': 'system prompt',
              'group': '',
              'placement': QuickInstructionPlacement.systemPrompt.name,
            },
          ]),
          QuickInstructionStore.legacyQuickPhrasesKey: jsonEncode([
            const QuickPhrase(
              id: 'phrase-1',
              title: 'Insert',
              content: 'insert me',
            ).toJson(),
          ]),
        })..failedKey = QuickInstructionStore.legacyQuickPhrasesKey;
        final preferences = BusinessPreferences.open(backend);
        await preferences.load();
        final store = QuickInstructionStore(preferences);

        await expectLater(
          store.migrateLegacyQuickPhrases(),
          throwsA(isA<StateError>()),
        );
        expect(
          preferences.getString(QuickInstructionStore.legacyQuickPhrasesKey),
          isNotNull,
        );
        final firstAttempt = await store.getAll();
        expect(firstAttempt, hasLength(2));

        backend.failedKey = null;
        store.invalidateCache();
        await store.migrateLegacyQuickPhrases();
        final retry = await store.getAll();

        expect(retry, hasLength(2));
        expect(retry.map((item) => item.id).toSet(), {
          'injection-1',
          firstAttempt.last.id,
        });
        expect(
          preferences.getString(QuickInstructionStore.legacyQuickPhrasesKey),
          isNull,
        );
      },
    );

    test(
      'an old backup migrates again even when a prior receipt remains',
      () async {
        final preferences = BusinessPreferences.memoryForTests({
          QuickInstructionStore.migrationReceiptKey: true,
          QuickInstructionStore.itemsKey: jsonEncode([
            {
              'id': 'restored-injection',
              'title': 'Review',
              'prompt': 'restored system prompt',
              'group': 'Restored',
            },
          ]),
          QuickInstructionStore.legacyQuickPhrasesKey: jsonEncode([
            const QuickPhrase(
              id: 'restored-phrase',
              title: 'Review',
              content: 'restored phrase',
            ).toJson(),
          ]),
        });
        final store = QuickInstructionStore(preferences);

        await store.migrateLegacyQuickPhrases();

        expect((await store.getAll()).map((item) => item.title), [
          'Review-Instruction Injection',
          'Review-Global Quick Phrase',
        ]);
        expect(
          preferences.getString(QuickInstructionStore.legacyQuickPhrasesKey),
          isNull,
        );
      },
    );
  });
}

final class _FailingRemoveStore implements BusinessPreferencesStore {
  _FailingRemoveStore(Map<String, Object> seed)
    : _values = Map<String, Object>.of(seed);

  final Map<String, Object> _values;
  String? failedKey;

  @override
  Future<List<BusinessPreferenceEntry>> readAll() async {
    return <BusinessPreferenceEntry>[
      for (final entry in _values.entries)
        BusinessPreferenceEntry(
          key: entry.key,
          value: entry.value,
          updatedAt: 1,
        ),
    ];
  }

  @override
  Future<void> write(String key, Object value, {required int updatedAt}) async {
    _values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    if (key == failedKey) throw StateError('simulated remove failure');
    _values.remove(key);
  }

  @override
  Future<void> clear() async => _values.clear();
}
