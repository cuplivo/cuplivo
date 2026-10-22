import 'dart:convert';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_data.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/memory_entry.dart';
import 'package:Cuplivo/core/services/memory/memory_prompts.dart';
import 'package:Cuplivo/core/services/memory/memory_repository.dart';
import 'package:Cuplivo/core/services/memory/memory_smart_add.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase database;
  late BusinessPreferences preferences;
  late ChatDatabaseRepository chatRepository;
  late MemoryRepository memoryRepository;
  late MemorySmartAdd smartAdd;

  setUp(() async {
    database = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) => raw.execute('PRAGMA foreign_keys = ON;'),
      ),
    );
    final businessRepository = BusinessRepository(database);
    preferences = BusinessPreferences(businessRepository);
    chatRepository = ChatDatabaseRepository(database);
    memoryRepository = MemoryRepository(preferences);
    smartAdd = MemorySmartAdd(
      repository: memoryRepository,
      chatRepository: chatRepository,
    );
    await chatRepository.ensureReady();
    await preferences.load();
  });

  tearDown(() => database.close());

  Future<void> seedAssistant(String id) async {
    final raw = preferences.getString(BusinessEntityKind.assistant.sourceKey);
    final list = <Map<String, dynamic>>[
      if (raw != null && raw.isNotEmpty)
        for (final item in jsonDecode(raw) as List)
          (item as Map).cast<String, dynamic>(),
    ];
    if (!list.any((item) => item['id'] == id)) {
      list.add({'id': id, 'name': id});
    }
    await preferences.setString(
      BusinessEntityKind.assistant.sourceKey,
      jsonEncode(list),
    );
  }

  group('normalizeDecision (§18.1 item 12)', () {
    test('targetId not in candidates → NEW', () {
      final d = MemorySmartAdd.normalizeDecision(
        const SmartAddDecision(
          action: SmartAddAction.merge,
          targetId: 'mem_missing',
          mergedContent: 'merged',
        ),
        {'mem_a1b2c3d4'},
      );
      expect(d.action, SmartAddAction.neu);
    });

    test('MERGE with empty mergedContent → SKIP', () {
      final d = MemorySmartAdd.normalizeDecision(
        const SmartAddDecision(
          action: SmartAddAction.merge,
          targetId: 'mem_a1b2c3d4',
          mergedContent: '   ',
        ),
        {'mem_a1b2c3d4'},
      );
      expect(d.action, SmartAddAction.skip);
    });

    test('relatedIds outside candidate set are dropped', () {
      final d = MemorySmartAdd.normalizeDecision(
        const SmartAddDecision(
          action: SmartAddAction.neu,
          relatedIds: ['mem_a1b2c3d4', 'mem_ghost000'],
        ),
        {'mem_a1b2c3d4'},
      );
      expect(d.relatedIds, ['mem_a1b2c3d4']);
    });

    test('MERGE target outside mergeableIds degrades to NEW', () {
      final d = MemorySmartAdd.normalizeDecision(
        const SmartAddDecision(
          action: SmartAddAction.merge,
          targetId: 'mem_global01',
          mergedContent: 'merged',
          relatedIds: ['mem_global01'],
        ),
        {'mem_global01'},
        mergeableIds: const <String>{},
      );
      expect(d.action, SmartAddAction.neu);
      expect(d.targetId, isNull);
      expect(d.relatedIds, ['mem_global01']);
    });
  });

  group('parse batch / per-item (§18.1 item 12)', () {
    test('bad JSON → null (caller degrades)', () {
      expect(MemorySmartAdd.parsePerItem('not json'), isNull);
      expect(MemorySmartAdd.parseBatch('```\nbad\n```', 2), isNull);
    });

    test('batched missing index left null', () {
      final parsed = MemorySmartAdd.parseBatch(
        jsonEncode({
          'results': [
            {'index': 1, 'action': 'NEW', 'relatedIds': []},
          ],
        }),
        2,
      );
      expect(parsed, isNotNull);
      expect(parsed![0]!.action, SmartAddAction.neu);
      expect(parsed[1], isNull);
    });

    test('tolerates prose and fences', () {
      const raw = '''
Sure:
```json
{"action":"SKIP","targetId":null,"mergedContent":null,"relatedIds":[]}
```
''';
      final d = MemorySmartAdd.parsePerItem(raw);
      expect(d?.action, SmartAddAction.skip);
    });
  });

  group('candidatesFor (§18.1 item 11)', () {
    test('pads to 5 with recent same-type entries', () async {
      await seedAssistant('a1');
      // One hit via token, four fillers with no shared tokens.
      await memoryRepository.create(
        scope: MemoryScope.global,
        type: MemoryType.workflow,
        content: '用户开发 Flutter 应用时重视跨平台。',
        source: MemorySource.manual,
      );
      for (var i = 0; i < 6; i++) {
        await memoryRepository.create(
          scope: MemoryScope.global,
          type: MemoryType.workflow,
          content: '完全无关的工作习惯条目编号 $i',
          source: MemorySource.manual,
        );
      }
      // Different type must not pad.
      await memoryRepository.create(
        scope: MemoryScope.global,
        type: MemoryType.voice,
        content: '用户偏好简短回复。',
        source: MemorySource.manual,
      );

      final cands = await smartAdd.candidatesFor(
        assistantId: 'a1',
        type: MemoryType.workflow,
        newInfo: '用户开发 Flutter 项目时优先考虑兼容性。',
      );
      expect(cands, hasLength(5));
      expect(cands.every((e) => e.type == MemoryType.workflow), isTrue);
    });
  });

  group('applyDecision NEW/MERGE/CONFLICT/SKIP', () {
    test(
      'NEW links bidirectionally; MERGE does not; CONFLICT archives',
      () async {
        await seedAssistant('a1');
        final existing = await memoryRepository.create(
          scope: MemoryScope.global,
          type: MemoryType.identity,
          content: '用户住在上海。',
          source: MemorySource.manual,
        );
        final related = await memoryRepository.create(
          scope: MemoryScope.global,
          type: MemoryType.identity,
          content: '用户在华东工作。',
          source: MemorySource.manual,
        );
        final candidateIds = {existing.id, related.id};

        final neu = await smartAdd.applyDecision(
          item: const SmartAddItem(
            type: MemoryType.identity,
            content: '用户是软件工程师。',
            scope: MemoryScope.global,
          ),
          decision: SmartAddDecision(
            action: SmartAddAction.neu,
            relatedIds: [related.id, 'mem_ghost00'],
          ),
          candidateIds: candidateIds,
          source: MemorySource.extracted,
        );
        expect(neu.action, SmartAddAction.neu);
        final neuEntry = (await chatRepository.memoriesByIds([neu.id!])).single;
        expect(neuEntry.relatedIds, [related.id]);
        final relatedAfter = (await chatRepository.memoriesByIds([
          related.id,
        ])).single;
        expect(relatedAfter.relatedIds, contains(neu.id));

        final merged = await smartAdd.applyDecision(
          item: const SmartAddItem(
            type: MemoryType.identity,
            content: 'ignored',
            scope: MemoryScope.global,
          ),
          decision: SmartAddDecision(
            action: SmartAddAction.merge,
            targetId: existing.id,
            mergedContent: '用户住在上海，偶尔去杭州。',
            relatedIds: [related.id],
          ),
          candidateIds: candidateIds,
          source: MemorySource.extracted,
        );
        expect(merged.action, SmartAddAction.merge);
        final afterMerge = (await chatRepository.memoriesByIds([
          existing.id,
        ])).single;
        expect(afterMerge.content, '用户住在上海，偶尔去杭州。');
        // MERGE must not attach relatedIds (D-25).
        expect(afterMerge.relatedIds, isEmpty);

        final conflict = await smartAdd.applyDecision(
          item: const SmartAddItem(
            type: MemoryType.identity,
            content: '用户住在北京。',
            scope: MemoryScope.global,
          ),
          decision: SmartAddDecision(
            action: SmartAddAction.conflict,
            targetId: existing.id,
            relatedIds: const [],
          ),
          candidateIds: candidateIds,
          source: MemorySource.extracted,
        );
        expect(conflict.action, SmartAddAction.conflict);
        final archived = (await chatRepository.memoriesByIds([
          existing.id,
        ])).single;
        expect(archived.status, MemoryStatus.archived);
        final fresh = (await chatRepository.memoriesByIds([
          conflict.id!,
        ])).single;
        expect(fresh.content, '用户住在北京。');
        expect(fresh.relatedIds, contains(existing.id));

        final skip = await smartAdd.applyDecision(
          item: const SmartAddItem(
            type: MemoryType.identity,
            content: 'x',
            scope: MemoryScope.global,
          ),
          decision: SmartAddDecision(
            action: SmartAddAction.skip,
            targetId: related.id,
          ),
          candidateIds: candidateIds,
          source: MemorySource.extracted,
        );
        expect(skip.action, SmartAddAction.skip);
        expect(skip.id, related.id);
      },
    );

    test('exact duplicate fast-path SKIP without LLM', () async {
      await seedAssistant('a1');
      final e = await memoryRepository.create(
        scope: MemoryScope.global,
        type: MemoryType.voice,
        content: '用户偏好直接说明。',
        source: MemorySource.manual,
      );
      final r = await smartAdd.addOne(
        item: const SmartAddItem(
          type: MemoryType.voice,
          content: '用户偏好直接说明。',
          scope: MemoryScope.global,
        ),
        visibilityAssistantId: 'a1',
        source: MemorySource.tool,
        lang: MemoryPromptLang.zh,
        llmCall: (_) async => throw StateError('should not call'),
      );
      expect(r.action, SmartAddAction.skip);
      expect(r.id, e.id);
    });

    test('JSON failure degrades to NEW when not duplicate', () async {
      await seedAssistant('a1');
      final r = await smartAdd.addOne(
        item: const SmartAddItem(
          type: MemoryType.instruction,
          content: '用户要求回复使用中文。',
          scope: MemoryScope.global,
        ),
        visibilityAssistantId: 'a1',
        source: MemorySource.tool,
        lang: MemoryPromptLang.zh,
        llmCall: (_) async => 'totally broken',
      );
      expect(r.action, SmartAddAction.neu);
      expect(r.id, isNotNull);
    });

    test(
      'assistant-scoped item does not MERGE into a global candidate',
      () async {
        await seedAssistant('a1');
        final global = await memoryRepository.create(
          scope: MemoryScope.global,
          type: MemoryType.identity,
          content: '用户住在上海。',
          source: MemorySource.manual,
        );
        final r = await smartAdd.addOne(
          item: const SmartAddItem(
            type: MemoryType.identity,
            content: '用户住在杭州。',
            scope: MemoryScope.assistant,
            assistantId: 'a1',
          ),
          visibilityAssistantId: 'a1',
          source: MemorySource.tool,
          lang: MemoryPromptLang.zh,
          llmCall: (_) async => jsonEncode({
            'action': 'MERGE',
            'targetId': global.id,
            'mergedContent': '用户住在上海和杭州。',
            'relatedIds': <String>[],
          }),
        );
        expect(r.action, SmartAddAction.neu);
        expect(r.id, isNot(global.id));
        final afterGlobal = (await chatRepository.memoriesByIds([
          global.id,
        ])).single;
        expect(afterGlobal.content, '用户住在上海。');
        expect(afterGlobal.scope, MemoryScope.global);
        final created = (await chatRepository.memoriesByIds([r.id!])).single;
        expect(created.scope, MemoryScope.assistant);
        expect(created.assistantId, 'a1');
        expect(created.content, '用户住在杭州。');
      },
    );
  });
}
