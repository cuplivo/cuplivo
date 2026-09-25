import 'dart:convert';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_data.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/memory_entry.dart';
import 'package:Cuplivo/core/services/memory/memory_repository.dart';
import 'package:Cuplivo/core/services/memory/memory_tokenizer.dart';
import 'package:drift/drift.dart' show Variable, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase database;
  late BusinessRepository businessRepository;
  late BusinessPreferences preferences;
  late ChatDatabaseRepository chatRepository;
  late MemoryRepository memoryRepository;

  setUp(() async {
    database = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) => raw.execute('PRAGMA foreign_keys = ON;'),
      ),
    );
    businessRepository = BusinessRepository(database);
    preferences = BusinessPreferences(businessRepository);
    chatRepository = ChatDatabaseRepository(database);
    memoryRepository = MemoryRepository(preferences);
    await chatRepository.ensureReady();
    await preferences.load();
  });

  tearDown(() => database.close());

  /// Seeds via preferences so assistant_rows and the entity blob stay aligned.
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

  /// Direct typed-row seed for controlled timestamps (read path only after).
  Future<void> putEntry({
    required String id,
    MemoryScope scope = MemoryScope.global,
    String? assistantId,
    MemoryType type = MemoryType.identity,
    MemoryStatus status = MemoryStatus.active,
    required String content,
    List<String> relatedIds = const [],
    int? createdAt,
    int? updatedAt,
  }) {
    final created =
        createdAt ?? DateTime.utc(2026, 8, 1).microsecondsSinceEpoch;
    final updated = updatedAt ?? created;
    return businessRepository.upsertEntity(
      BusinessEntityKind.memoryEntry,
      BusinessEntityValue(
        id: id,
        sortOrder: 0,
        payload: jsonEncode({
          'id': id,
          'scope': MemoryEntry.scopeToString(scope),
          'assistantId': assistantId,
          'type': MemoryEntry.typeToString(type),
          'status': MemoryEntry.statusToString(status),
          'content': content,
          'source': 'manual',
          'relatedIds': relatedIds,
          'createdAt': created,
          'updatedAt': updated,
        }),
      ),
    );
  }

  group('§18.1 item 15 relatedIds', () {
    test('linkBidirectional is idempotent', () async {
      final a = await memoryRepository.create(
        scope: MemoryScope.global,
        type: MemoryType.identity,
        content: 'Alpha identity',
        source: MemorySource.manual,
      );
      final b = await memoryRepository.create(
        scope: MemoryScope.global,
        type: MemoryType.identity,
        content: 'Beta identity',
        source: MemorySource.manual,
      );

      await memoryRepository.linkBidirectional(a.id, b.id);
      await memoryRepository.linkBidirectional(a.id, b.id);
      await memoryRepository.linkBidirectional(b.id, a.id);

      final loaded = await chatRepository.memoriesByIds([a.id, b.id]);
      final byId = {for (final e in loaded) e.id: e};
      expect(byId[a.id]!.relatedIds, [b.id]);
      expect(byId[b.id]!.relatedIds, [a.id]);
    });

    test('archive strips reverse relatedIds in one write', () async {
      final a = await memoryRepository.create(
        scope: MemoryScope.global,
        type: MemoryType.workflow,
        content: 'Keep me',
        source: MemorySource.manual,
      );
      final b = await memoryRepository.create(
        scope: MemoryScope.global,
        type: MemoryType.workflow,
        content: 'Archive me',
        source: MemorySource.manual,
        relatedIds: [a.id],
      );
      await memoryRepository.linkBidirectional(a.id, b.id);

      final ok = await memoryRepository.archive(b.id);
      expect(ok, isTrue);

      final kept = (await chatRepository.memoriesByIds([a.id])).single;
      expect(kept.relatedIds, isEmpty);
      expect(kept.status, MemoryStatus.active);

      final archived = (await chatRepository.memoriesByIds([b.id])).single;
      expect(archived.status, MemoryStatus.archived);
    });

    test('hardDelete strips reverse relatedIds', () async {
      final a = await memoryRepository.create(
        scope: MemoryScope.global,
        type: MemoryType.voice,
        content: 'Survivor',
        source: MemorySource.manual,
      );
      final b = await memoryRepository.create(
        scope: MemoryScope.global,
        type: MemoryType.voice,
        content: 'Doomed',
        source: MemorySource.manual,
      );
      await memoryRepository.linkBidirectional(a.id, b.id);

      expect(await memoryRepository.hardDelete(b.id), isTrue);
      final kept = (await chatRepository.memoriesByIds([a.id])).single;
      expect(kept.relatedIds, isEmpty);
      expect(await chatRepository.memoriesByIds([b.id]), isEmpty);
    });

    test('dangling relatedIds are dropped on read', () async {
      await putEntry(
        id: 'mem_alive001',
        content: 'Has dangling link',
        relatedIds: const ['mem_missing1', 'mem_gone000'],
      );

      final loaded = await chatRepository.memoriesByIds(const ['mem_alive001']);
      expect(loaded, hasLength(1));
      expect(loaded.single.relatedIds, isEmpty);

      final visible = await chatRepository.queryVisibleMemories(
        assistantId: null,
      );
      expect(visible.single.relatedIds, isEmpty);
    });
  });

  group('MemoryRepository writes', () {
    test('create sets createdAt == updatedAt and rejects bad scope', () async {
      final entry = await memoryRepository.create(
        scope: MemoryScope.global,
        type: MemoryType.instruction,
        content: 'Prefer concise answers',
        source: MemorySource.tool,
      );
      expect(entry.createdAt, entry.updatedAt);
      expect(entry.id, startsWith('mem_'));
      expect(entry.status, MemoryStatus.active);

      await expectLater(
        memoryRepository.create(
          scope: MemoryScope.assistant,
          type: MemoryType.identity,
          content: 'missing assistant',
          source: MemorySource.manual,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('createMany deduplicates and persists migration receipts', () async {
      final existing = await memoryRepository.create(
        scope: MemoryScope.global,
        type: MemoryType.identity,
        content: 'Already saved',
        source: MemorySource.manual,
      );

      final result = await memoryRepository.createMany(const [
        MemoryCreateDraft(
          scope: MemoryScope.global,
          type: MemoryType.identity,
          content: ' already   SAVED ',
          source: MemorySource.extracted,
          migrationId: 'legacy:1',
        ),
        MemoryCreateDraft(
          scope: MemoryScope.global,
          type: MemoryType.workflow,
          content: 'New memory',
          source: MemorySource.extracted,
          migrationId: 'legacy:2',
        ),
        MemoryCreateDraft(
          scope: MemoryScope.global,
          type: MemoryType.workflow,
          content: 'NEW MEMORY',
          source: MemorySource.extracted,
          migrationId: 'legacy:3',
        ),
      ]);

      expect(result.created, 1);
      expect(result.skipped, 2);
      final entries = await memoryRepository.readAll();
      expect(entries, hasLength(2));
      expect(
        entries.firstWhere((entry) => entry.id == existing.id).migrationIds,
        ['legacy:1'],
      );
      expect(
        entries.firstWhere((entry) => entry.id != existing.id).migrationIds,
        ['legacy:2', 'legacy:3'],
      );
    });

    test('createMany validates the whole batch before writing', () async {
      await expectLater(
        memoryRepository.createMany(const [
          MemoryCreateDraft(
            scope: MemoryScope.global,
            type: MemoryType.identity,
            content: 'Would otherwise be written',
            source: MemorySource.extracted,
          ),
          MemoryCreateDraft(
            scope: MemoryScope.assistant,
            type: MemoryType.identity,
            content: 'Missing assistant',
            source: MemorySource.extracted,
          ),
        ]),
        throwsA(isA<ArgumentError>()),
      );
      expect(await memoryRepository.readAll(), isEmpty);
    });

    test('updateContent refreshes updatedAt and leaves scope/type', () async {
      final created = await memoryRepository.create(
        scope: MemoryScope.global,
        type: MemoryType.workflow,
        content: 'Old content',
        source: MemorySource.extracted,
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final updated = await memoryRepository.updateContent(
        created.id,
        'New content',
      );
      expect(updated, isNotNull);
      expect(updated!.content, 'New content');
      expect(updated.type, MemoryType.workflow);
      expect(updated.scope, MemoryScope.global);
      expect(
        updated.updatedAt.microsecondsSinceEpoch,
        greaterThan(created.updatedAt.microsecondsSinceEpoch),
      );
    });

    test('updateType round-trips and refreshes updatedAt', () async {
      final created = await memoryRepository.create(
        scope: MemoryScope.global,
        type: MemoryType.workflow,
        content: 'Typed content',
        source: MemorySource.extracted,
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final updated = await memoryRepository.updateType(
        created.id,
        MemoryType.voice,
      );
      expect(updated, isNotNull);
      expect(updated!.type, MemoryType.voice);
      expect(updated.content, 'Typed content');
      expect(updated.scope, MemoryScope.global);
      expect(
        updated.updatedAt.microsecondsSinceEpoch,
        greaterThan(created.updatedAt.microsecondsSinceEpoch),
      );
      final loaded = (await chatRepository.memoriesByIds([created.id])).single;
      expect(loaded.type, MemoryType.voice);
      expect(loaded.content, 'Typed content');
    });

    test('restore flips archived to active', () async {
      final entry = await memoryRepository.create(
        scope: MemoryScope.global,
        type: MemoryType.identity,
        content: 'Restorable',
        source: MemorySource.manual,
      );
      await memoryRepository.archive(entry.id);
      expect(await memoryRepository.restore(entry.id), isTrue);
      final loaded = (await chatRepository.memoriesByIds([entry.id])).single;
      expect(loaded.status, MemoryStatus.active);
    });

    test(
      'deleteOrphanAssistantMemories cleans orphans and reverse refs',
      () async {
        await seedAssistant('assistant-alive');
        final global = await memoryRepository.create(
          scope: MemoryScope.global,
          type: MemoryType.identity,
          content: 'Global note',
          source: MemorySource.manual,
        );
        final alive = await memoryRepository.create(
          scope: MemoryScope.assistant,
          assistantId: 'assistant-alive',
          type: MemoryType.voice,
          content: 'Alive assistant note',
          source: MemorySource.manual,
        );
        final orphan = await memoryRepository.create(
          scope: MemoryScope.assistant,
          assistantId: 'assistant-deleted',
          type: MemoryType.voice,
          content: 'Orphan note',
          source: MemorySource.manual,
        );
        await memoryRepository.linkBidirectional(global.id, orphan.id);

        expect(await chatRepository.countOrphanAssistantMemories(), 1);
        expect(await memoryRepository.deleteOrphanAssistantMemories(), 1);
        expect(await chatRepository.countOrphanAssistantMemories(), 0);

        final remaining = await chatRepository.memoriesByIds([
          global.id,
          alive.id,
          orphan.id,
        ]);
        expect(remaining.map((e) => e.id).toSet(), {global.id, alive.id});
        expect(
          remaining.firstWhere((e) => e.id == global.id).relatedIds,
          isEmpty,
        );
      },
    );

    test(
      '§5.2 typed columns match payload after MemoryRepository write',
      () async {
        final entry = await memoryRepository.create(
          scope: MemoryScope.global,
          type: MemoryType.workflow,
          content: '  User   likes\nFlutter  ',
          source: MemorySource.extracted,
        );

        final row = await database
            .customSelect(
              'SELECT scope, assistant_id, type, status, content, '
              'content_normalized, entry_created_at, entry_updated_at, payload '
              'FROM memory_entry_rows WHERE id = ?;',
              variables: [Variable<String>(entry.id)],
            )
            .getSingle();

        expect(row.read<String>('scope'), 'global');
        expect(row.data['assistant_id'], isNull);
        expect(row.read<String>('type'), 'workflow');
        expect(row.read<String>('status'), 'active');
        expect(row.read<String>('content'), '  User   likes\nFlutter  ');
        expect(
          row.read<String>('content_normalized'),
          MemoryEntry.normalizeContent('  User   likes\nFlutter  '),
        );
        expect(
          row.read<int>('entry_created_at'),
          entry.createdAt.microsecondsSinceEpoch,
        );
        expect(
          row.read<int>('entry_updated_at'),
          entry.updatedAt.microsecondsSinceEpoch,
        );
        final payload = (jsonDecode(row.read<String>('payload')) as Map)
            .cast<String, dynamic>();
        expect(payload.containsKey('contentNormalized'), isFalse);
        expect(payload['content'], '  User   likes\nFlutter  ');
        expect(payload['source'], 'extracted');
      },
    );
  });

  group('profile fields', () {
    test(
      'put/remove round-trip; invalid key rejected; clear removes row',
      () async {
        await memoryRepository.putProfileField(
          'preferred_name',
          'Psyche',
          MemorySource.tool,
        );
        await memoryRepository.putProfileField(
          'custom.company',
          'Kelivo',
          MemorySource.manual,
        );

        var fields = await chatRepository.readProfileFields();
        expect(fields.map((f) => f.key).toSet(), {
          'preferred_name',
          'custom.company',
        });
        expect(
          fields.firstWhere((f) => f.key == 'preferred_name').value,
          'Psyche',
        );

        await expectLater(
          memoryRepository.putProfileField(
            'not_a_key',
            'x',
            MemorySource.manual,
          ),
          throwsA(isA<ArgumentError>()),
        );
        await expectLater(
          memoryRepository.putProfileField(
            'preferred_name',
            '   ',
            MemorySource.manual,
          ),
          throwsA(isA<ArgumentError>()),
        );

        expect(
          await memoryRepository.removeProfileField('preferred_name'),
          isTrue,
        );
        fields = await chatRepository.readProfileFields();
        expect(fields.map((f) => f.key), ['custom.company']);

        final rows = await database
            .customSelect("SELECT id FROM user_profile_field_rows ORDER BY id;")
            .get();
        expect(rows.map((r) => r.read<String>('id')), ['custom.company']);
      },
    );
  });

  group('searchMemories', () {
    test(
      'AND semantics, OR hits ordering, LIKE literals, CJK substring',
      () async {
        const t0 = 1786012880106000;
        const t1 = 1786099280106000;
        const t2 = 1786185680106000;

        await putEntry(
          id: 'mem_flutter1',
          type: MemoryType.workflow,
          content: 'User develops Flutter apps carefully',
          updatedAt: t1,
          createdAt: t0,
        );
        await putEntry(
          id: 'mem_flutter2',
          type: MemoryType.workflow,
          content: 'Flutter performance and lists',
          updatedAt: t2,
          createdAt: t0,
        );
        await putEntry(
          id: 'mem_dartonly',
          type: MemoryType.workflow,
          content: 'Prefers Dart over Kotlin',
          updatedAt: t2,
          createdAt: t0,
        );
        await putEntry(
          id: 'mem_cjk00001',
          type: MemoryType.identity,
          content: '用户喜欢跨平台开发',
          updatedAt: t1,
          createdAt: t0,
        );
        await putEntry(
          id: 'mem_likechar',
          type: MemoryType.instruction,
          content: r'pattern 100%_complete\path',
          updatedAt: t1,
          createdAt: t0,
        );

        // AND: both tokens must match (§5.9)
        final andHits = await chatRepository.searchMemories(
          assistantId: null,
          tokens: ['flutter', 'performance'],
          matchAll: true,
        );
        expect(andHits.map((e) => e.id), ['mem_flutter2']);

        // OR + hits ordering (§12.6): ties break by entry_updated_at DESC, id ASC
        final orHits = await chatRepository.searchMemories(
          assistantId: null,
          tokens: ['flutter', 'dart'],
          type: MemoryType.workflow,
          matchAll: false,
          limit: 10,
        );
        expect(orHits.map((e) => e.id).toList(), [
          'mem_dartonly',
          'mem_flutter2',
          'mem_flutter1',
        ]);

        // Higher hits first
        final ranked = await chatRepository.searchMemories(
          assistantId: null,
          tokens: ['flutter', 'apps'],
          type: MemoryType.workflow,
          matchAll: false,
        );
        expect(ranked.first.id, 'mem_flutter1'); // hits=2
        expect(ranked.map((e) => e.id), contains('mem_flutter2')); // hits=1

        // LIKE special characters match literally
        final likeEscaped = [
          MemoryTokenizer.escapeLike('100%'),
          MemoryTokenizer.escapeLike('_complete'),
          MemoryTokenizer.escapeLike(r'\path'),
        ];
        final literal = await chatRepository.searchMemories(
          assistantId: null,
          tokens: likeEscaped,
          matchAll: true,
        );
        expect(literal.map((e) => e.id), ['mem_likechar']);

        // CJK substring
        final cjk = await chatRepository.searchMemories(
          assistantId: null,
          tokens: ['跨平台'],
          matchAll: true,
        );
        expect(cjk.map((e) => e.id), ['mem_cjk00001']);
      },
    );
  });

  group('queryVisibleMemories visibility and ordering', () {
    test('global vs assistant matrix and §7.2 order', () async {
      await seedAssistant('asst-a');
      await seedAssistant('asst-b');
      const t0 = 1786012880106000;
      const t1 = 1786012880106001;
      const t2 = 1786012880106002;

      await putEntry(
        id: 'mem_g_later',
        content: 'Global later created',
        createdAt: t2,
        updatedAt: t2,
      );
      await putEntry(
        id: 'mem_g_early',
        content: 'Global early created',
        createdAt: t0,
        updatedAt: t0,
      );
      await putEntry(
        id: 'mem_a_asst',
        scope: MemoryScope.assistant,
        assistantId: 'asst-a',
        content: 'Assistant A note',
        createdAt: t1,
        updatedAt: t1,
      );
      await putEntry(
        id: 'mem_b_asst',
        scope: MemoryScope.assistant,
        assistantId: 'asst-b',
        content: 'Assistant B note',
        createdAt: t0,
        updatedAt: t0,
      );
      await putEntry(
        id: 'mem_archiv01',
        content: 'Archived global',
        status: MemoryStatus.archived,
        createdAt: t0,
        updatedAt: t0,
      );

      final globalOnly = await chatRepository.queryVisibleMemories(
        assistantId: null,
      );
      expect(globalOnly.map((e) => e.id).toList(), [
        'mem_g_early',
        'mem_g_later',
      ]);

      final forA = await chatRepository.queryVisibleMemories(
        assistantId: 'asst-a',
      );
      // scope_rank: global first (by createdAt), then assistant
      expect(forA.map((e) => e.id).toList(), [
        'mem_g_early',
        'mem_g_later',
        'mem_a_asst',
      ]);

      final forB = await chatRepository.queryVisibleMemories(
        assistantId: 'asst-b',
      );
      expect(forB.map((e) => e.id).toSet(), {
        'mem_g_early',
        'mem_g_later',
        'mem_b_asst',
      });

      final withArchived = await chatRepository.queryVisibleMemories(
        assistantId: null,
        includeArchived: true,
      );
      expect(withArchived.map((e) => e.id), contains('mem_archiv01'));
    });
  });

  group('prompt freeze and conversation columns', () {
    test(
      'put/get/anyPromptCarriesMemorySnapshot and setConversation*',
      () async {
        final now = DateTime.utc(2026, 8, 8);
        await database
            .into(database.conversationRows)
            .insert(
              ConversationRowsCompanion.insert(
                id: 'c1',
                title: 'Chat',
                createdAt: now,
                updatedAt: now,
              ),
            );
        await database
            .into(database.messageRows)
            .insert(
              MessageRowsCompanion.insert(
                id: 'm1',
                conversationId: 'c1',
                role: 'user',
                timestamp: now,
                messageOrder: 0,
              ),
            );
        await database
            .into(database.messageRows)
            .insert(
              MessageRowsCompanion.insert(
                id: 'm2',
                conversationId: 'c1',
                role: 'user',
                timestamp: now,
                messageOrder: 1,
              ),
            );

        await chatRepository.putMessagePrompt(
          revisionId: 'm1',
          conversationId: 'c1',
          payload: 'frozen with snapshot',
          carriesMemorySnapshot: true,
        );
        await chatRepository.putMessagePrompt(
          revisionId: 'm2',
          conversationId: 'c1',
          payload: 'frozen without',
          carriesMemorySnapshot: false,
        );

        final prompt = await chatRepository.getMessagePrompt('m1');
        expect(prompt, isNotNull);
        expect(prompt!.payload, 'frozen with snapshot');
        expect(prompt.carriesMemorySnapshot, isTrue);

        expect(
          await chatRepository.anyPromptCarriesMemorySnapshot(['m2']),
          isFalse,
        );
        expect(
          await chatRepository.anyPromptCarriesMemorySnapshot(['m2', 'm1']),
          isTrue,
        );
        expect(
          await chatRepository.anyPromptCarriesMemorySnapshot(const []),
          isFalse,
        );

        await chatRepository.setConversationInjectedMemoryHash('c1', 'abc123');
        await chatRepository.setConversationLastMemoryExtractedOrder('c1', 7);
        var conversation = await chatRepository.getConversation('c1');
        expect(conversation!.injectedMemoryHash, 'abc123');
        expect(conversation.lastMemoryExtractedOrder, 7);

        await chatRepository.setConversationInjectedMemoryHash('c1', null);
        conversation = await chatRepository.getConversation('c1');
        expect(conversation!.injectedMemoryHash, isNull);
      },
    );
  });

  group('findExactMemory and counts', () {
    test('exact match and countVisibleMemoriesByType', () async {
      await seedAssistant('asst-a');
      await putEntry(
        id: 'mem_exact001',
        content: 'Exact Duplicate Content',
        type: MemoryType.identity,
      );
      await putEntry(
        id: 'mem_work0001',
        content: 'Workflow A',
        type: MemoryType.workflow,
      );
      await putEntry(
        id: 'mem_work_asst',
        scope: MemoryScope.assistant,
        assistantId: 'asst-a',
        content: 'Workflow B',
        type: MemoryType.workflow,
      );

      final found = await chatRepository.findExactMemory(
        assistantId: null,
        type: MemoryType.identity,
        contentNormalized: MemoryEntry.normalizeContent(
          'Exact Duplicate Content',
        ),
      );
      expect(found?.id, 'mem_exact001');

      final counts = await chatRepository.countVisibleMemoriesByType(
        assistantId: 'asst-a',
      );
      expect(counts[MemoryType.identity], 1);
      expect(counts[MemoryType.workflow], 2);
      expect(counts[MemoryType.voice], 0);
    });
  });
}
