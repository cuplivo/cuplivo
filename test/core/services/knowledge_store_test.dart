import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/knowledge.dart';
import 'package:Cuplivo/core/services/knowledge/knowledge_store.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late KnowledgeStore store;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    store = KnowledgeStore(db, BusinessPreferences.memoryForTests());
  });

  tearDown(() async {
    await db.close();
  });

  test('base CRUD round-trips with defaults', () async {
    final now = DateTime(2026, 9, 10, 12);
    await store.upsertBase(
      KnowledgeBase(id: 'kb1', name: 'Docs', createdAt: now, updatedAt: now),
    );

    final loaded = await store.getBase('kb1');
    expect(loaded, isNotNull);
    expect(loaded!.name, 'Docs');
    expect(loaded.description, '');
    expect(loaded.enabled, isTrue);
    expect(loaded.chunkSize, 512);
    expect(loaded.chunkOverlap, 64);

    await store.upsertBase(
      loaded.copyWith(name: 'Renamed', enabled: false, chunkSize: 256),
    );
    final updated = await store.getBase('kb1');
    expect(updated!.name, 'Renamed');
    expect(updated.enabled, isFalse);
    expect(updated.chunkSize, 256);

    await store.deleteBase('kb1');
    expect(await store.getBase('kb1'), isNull);
  });

  test(
    'document insert populates the FTS index and delete purges it',
    () async {
      await _seedBase(db, 'kb1');
      await store.insertDocumentWithChunks(
        _document(id: 'd1', baseId: 'kb1', content: 'hello world today'),
        [
          _chunk(
            id: 'c1',
            docId: 'd1',
            baseId: 'kb1',
            index: 0,
            text: 'hello world today',
          ),
          _chunk(
            id: 'c2',
            docId: 'd1',
            baseId: 'kb1',
            index: 1,
            text: 'second chunk body',
          ),
        ],
      );

      expect(await store.countDocuments('kb1'), 1);
      expect(await store.countChunks('kb1'), 2);
      expect((await store.getDocument('d1'))!.chunkTotal, 2);
      expect(
        (await store.getChunksForDocument('d1')).map((c) => c.chunkIndex),
        [0, 1],
      );
      expect(await _ftsChunkIds(db, 'second'), ['c2']);
      expect(await _ftsChunkIds(db, 'world'), ['c1']);

      await store.deleteDocument('d1');
      expect(await store.countDocuments('kb1'), 0);
      expect(await store.countChunks('kb1'), 0);
      expect(await _ftsChunkIds(db, 'second'), isEmpty);
      expect(await _ftsChunkIds(db, 'world'), isEmpty);
    },
  );

  test('deleteBase cascades documents/chunks, FTS rows and bindings', () async {
    await _seedBase(db, 'kb1');
    await _seedBase(db, 'kb2');
    await store.insertDocumentWithChunks(
      _document(id: 'd1', baseId: 'kb1', content: 'alpha beta gamma'),
      [
        _chunk(
          id: 'c1',
          docId: 'd1',
          baseId: 'kb1',
          index: 0,
          text: 'alpha beta gamma',
        ),
      ],
    );
    await store.setActiveBaseIds(['kb1', 'kb2'], assistantId: 'a1');
    await store.setActiveBaseIds(['kb2'], assistantId: null); // global entry

    await store.deleteBase('kb1');

    expect(await store.getBase('kb1'), isNull);
    expect(await store.countDocuments('kb1'), 0);
    expect(await store.countChunks('kb1'), 0);
    expect(await _ftsChunkIds(db, 'gamma'), isEmpty);
    expect(await store.getActiveBaseIds(assistantId: 'a1'), ['kb2']);
    // The global entry never referenced kb1 and must stay untouched.
    expect(await store.getActiveBaseIds(), ['kb2']);
  });

  test(
    'bindings fall back to the global entry and keep explicit empties',
    () async {
      await store.setActiveBaseIds(['kb1'], assistantId: null);
      expect(await store.getActiveBaseIds(assistantId: 'a1'), ['kb1']);
      expect(await store.getActiveBaseIds(), ['kb1']);

      await store.setActiveBaseIds(['kb2'], assistantId: 'a1');
      expect(await store.getActiveBaseIds(assistantId: 'a1'), ['kb2']);
      expect(await store.getActiveBaseIds(assistantId: 'a2'), ['kb1']);

      // An explicit empty list is an actual binding, not "fall back to global".
      await store.setActiveBaseIds(const [], assistantId: 'a1');
      expect(await store.getActiveBaseIds(assistantId: 'a1'), isEmpty);
      expect(
        (await store.getActiveBaseIdsByAssistant()).containsKey('a1'),
        isTrue,
      );
    },
  );

  test('findDocumentByHash is scoped to one base', () async {
    await _seedBase(db, 'kb1');
    await _seedBase(db, 'kb2');
    await store.insertDocumentWithChunks(
      _document(
        id: 'd1',
        baseId: 'kb1',
        content: 'same content',
        hash: 'hash-1',
      ),
      [
        _chunk(
          id: 'c1',
          docId: 'd1',
          baseId: 'kb1',
          index: 0,
          text: 'same content',
        ),
      ],
    );

    expect(await store.findDocumentByHash('kb1', 'hash-1'), isNotNull);
    expect(await store.findDocumentByHash('kb2', 'hash-1'), isNull);
    expect(await store.findDocumentByHash('kb1', 'other'), isNull);
  });

  test('clearAllData wipes knowledge tables and the FTS index', () async {
    await _seedBase(db, 'kb1');
    await store.insertDocumentWithChunks(
      _document(id: 'd1', baseId: 'kb1', content: 'wipe me please'),
      [
        _chunk(
          id: 'c1',
          docId: 'd1',
          baseId: 'kb1',
          index: 0,
          text: 'wipe me please',
        ),
      ],
    );

    await ChatDatabaseRepository(db).clearAllData();

    expect(await store.getAllBases(), isEmpty);
    expect(await store.countDocuments('kb1'), 0);
    expect(await _ftsChunkIds(db, 'wipe'), isEmpty);
  });

  test('raw FTS search filters by base partition', () async {
    await _seedBase(db, 'kb1');
    await _seedBase(db, 'kb2');
    await store.insertDocumentWithChunks(
      _document(id: 'd1', baseId: 'kb1', content: 'shared keyword one'),
      [
        _chunk(
          id: 'c1',
          docId: 'd1',
          baseId: 'kb1',
          index: 0,
          text: 'shared keyword one',
        ),
      ],
    );
    await store.insertDocumentWithChunks(
      _document(id: 'd2', baseId: 'kb2', content: 'shared keyword two'),
      [
        _chunk(
          id: 'c2',
          docId: 'd2',
          baseId: 'kb2',
          index: 0,
          text: 'shared keyword two',
        ),
      ],
    );

    final rows = await db
        .customSelect(
          "SELECT chunk_id FROM knowledge_fts "
          "WHERE knowledge_fts MATCH 'keyword' AND kb_id = ?",
          variables: [Variable.withString('kb1')],
        )
        .get();
    expect(rows.map((r) => r.read<String>('chunk_id')), ['c1']);
  });

  test('rebuildChunksForDocument re-chunks text and resyncs the FTS', () async {
    await _seedBase(db, 'kb1');
    final content = List.generate(
      40,
      (i) => 'paragraph $i body text',
    ).join('\n');
    await store.insertDocumentWithChunks(
      _document(id: 'd1', baseId: 'kb1', content: content),
      [
        _chunk(
          id: 'c1',
          docId: 'd1',
          baseId: 'kb1',
          index: 0,
          text: 'stale chunk',
        ),
      ],
    );
    expect(await _ftsChunkIds(db, 'stale'), ['c1']);

    final count = await store.rebuildChunksForDocument(
      'd1',
      chunkSize: 64,
      chunkOverlap: 8,
    );

    expect(count, greaterThan(1));
    expect((await store.getDocument('d1'))!.chunkTotal, count);
    expect(await store.countChunks('kb1'), count);
    expect(await _ftsChunkIds(db, 'stale'), isEmpty);
    expect(await _ftsChunkIds(db, 'paragraph'), isNotEmpty);
    final chunks = await store.getChunksForDocument('d1');
    expect(chunks.map((c) => c.chunkIndex), List.generate(count, (i) => i));
    expect(chunks.every((c) => c.content.length <= 64), isTrue);
  });

  test('rebuildChunksForDocument returns 0 for a missing document', () async {
    expect(
      await store.rebuildChunksForDocument(
        'missing',
        chunkSize: 64,
        chunkOverlap: 8,
      ),
      0,
    );
  });

  test('rebuildAllChunks re-chunks every document in the base', () async {
    await _seedBase(db, 'kb1');
    final content = List.generate(30, (i) => 'line $i some body').join('\n');
    for (final id in ['d1', 'd2']) {
      await store.insertDocumentWithChunks(
        _document(id: id, baseId: 'kb1', content: content, hash: id),
        [
          _chunk(
            id: 'c-$id',
            docId: id,
            baseId: 'kb1',
            index: 0,
            text: 'placeholder',
          ),
        ],
      );
    }

    await store.rebuildAllChunks('kb1', chunkSize: 48, chunkOverlap: 8);

    final d1 = (await store.getDocument('d1'))!;
    final d2 = (await store.getDocument('d2'))!;
    expect(d1.chunkTotal, greaterThan(1));
    expect(d2.chunkTotal, d1.chunkTotal);
    expect(await store.countChunks('kb1'), d1.chunkTotal + d2.chunkTotal);
  });

  test('FTS search filters by base and respects the limit', () async {
    await _seedBase(db, 'kb1');
    await _seedBase(db, 'kb2');
    await store.insertDocumentWithChunks(
      _document(id: 'd1', baseId: 'kb1', content: '中医药治疗脾胃虚弱'),
      [
        _chunk(
          id: 'c1',
          docId: 'd1',
          baseId: 'kb1',
          index: 0,
          text: '中医药治疗脾胃虚弱',
        ),
        _chunk(id: 'c2', docId: 'd1', baseId: 'kb1', index: 1, text: '中医药典籍总论'),
      ],
    );
    await store.insertDocumentWithChunks(
      _document(id: 'd2', baseId: 'kb2', content: '中医药'),
      [_chunk(id: 'c9', docId: 'd2', baseId: 'kb2', index: 0, text: '中医药')],
    );

    final kb1Only = await store.search(baseIds: ['kb1'], query: '中医药');
    expect(kb1Only.map((hit) => hit.chunk.id), containsAll(['c1', 'c2']));
    expect(kb1Only.every((hit) => hit.chunk.knowledgeBaseId == 'kb1'), isTrue);
    expect(kb1Only.first.documentName, 'd1.txt');
    expect(kb1Only.first.score.isFinite, isTrue);

    final limited = await store.search(
      baseIds: ['kb1', 'kb2'],
      query: '中医药',
      limit: 1,
    );
    expect(limited, hasLength(1));
  });

  test('short queries fall back to a LIKE scan', () async {
    await _seedBase(db, 'kb1');
    await store.insertDocumentWithChunks(
      _document(id: 'd1', baseId: 'kb1', content: '脾胃虚弱'),
      [_chunk(id: 'c1', docId: 'd1', baseId: 'kb1', index: 0, text: '脾胃虚弱')],
    );

    // "脾胃" is only 2 characters: the trigram index cannot serve it.
    final hits = await store.search(baseIds: ['kb1'], query: '脾胃');
    expect(hits.map((hit) => hit.chunk.id), ['c1']);
    expect(hits.first.score, 0.0);
  });

  test('CJK question hits a chunk containing only part of it', () async {
    await _seedBase(db, 'kb1');
    await store.insertDocumentWithChunks(
      _document(id: 'd1', baseId: 'kb1', content: '战争对经济的影响非常深远'),
      [
        _chunk(
          id: 'c1',
          docId: 'd1',
          baseId: 'kb1',
          index: 0,
          text: '战争对经济的影响非常深远',
        ),
      ],
    );

    // No whitespace: without trigram OR-expansion this whole sentence would be
    // one exact phrase and never match.
    final hits = await store.search(baseIds: ['kb1'], query: '战争对经济的影响有哪些？');
    expect(hits.map((hit) => hit.chunk.id), contains('c1'));
  });

  test('LIKE fallback escapes % so it does not match everything', () async {
    await _seedBase(db, 'kb1');
    await store.insertDocumentWithChunks(
      _document(id: 'd1', baseId: 'kb1', content: 'abc'),
      [_chunk(id: 'c1', docId: 'd1', baseId: 'kb1', index: 0, text: 'abc')],
    );
    await store.insertDocumentWithChunks(
      _document(id: 'd2', baseId: 'kb1', content: '100%real', hash: 'h2'),
      [
        _chunk(
          id: 'c2',
          docId: 'd2',
          baseId: 'kb1',
          index: 0,
          text: '100%real',
        ),
      ],
    );

    final hits = await store.search(baseIds: ['kb1'], query: '%');
    expect(hits.map((hit) => hit.chunk.id), ['c2']);
  });

  test(
    'search returns nothing for empty bases or non-positive limit',
    () async {
      await _seedBase(db, 'kb1');
      expect(await store.search(baseIds: const [], query: 'abc'), isEmpty);
      expect(
        await store.search(baseIds: ['kb1'], query: 'abc', limit: 0),
        isEmpty,
      );
    },
  );

  test('topK defaults to 5 with per-assistant / global fallback', () async {
    expect(await store.getTopK(), 5);

    await store.setTopK(3, assistantId: null); // global entry
    expect(await store.getTopK(assistantId: 'a1'), 3);

    await store.setTopK(8, assistantId: 'a1');
    expect(await store.getTopK(assistantId: 'a1'), 8);
    expect(await store.getTopK(assistantId: 'a2'), 3);

    await store.setTopK(0, assistantId: 'a1'); // below 1 clamps to default
    expect(await store.getTopK(assistantId: 'a1'), 5);
    expect((await store.getTopKMap())['a1'], 5);
  });
}

Future<void> _seedBase(AppDatabase db, String id) async {
  final now = DateTime(2026, 9, 10, 12);
  await db
      .into(db.knowledgeBaseRows)
      .insertOnConflictUpdate(
        KnowledgeBaseRowsCompanion.insert(
          id: id,
          name: id,
          createdAt: now,
          updatedAt: now,
        ),
      );
}

KnowledgeDocument _document({
  required String id,
  required String baseId,
  required String content,
  String hash = 'hash',
}) => KnowledgeDocument(
  id: id,
  knowledgeBaseId: baseId,
  name: '$id.txt',
  sourceType: 'txt',
  content: content,
  contentHash: hash,
  charCount: content.length,
  importedAt: DateTime(2026, 9, 10, 12),
);

KnowledgeChunk _chunk({
  required String id,
  required String docId,
  required String baseId,
  required int index,
  required String text,
}) => KnowledgeChunk(
  id: id,
  documentId: docId,
  knowledgeBaseId: baseId,
  chunkIndex: index,
  content: text,
  charCount: text.length,
);

Future<List<String>> _ftsChunkIds(AppDatabase db, String query) async {
  final rows = await db
      .customSelect(
        'SELECT chunk_id FROM knowledge_fts WHERE knowledge_fts MATCH ?',
        variables: [Variable.withString(query)],
      )
      .get();
  return rows.map((r) => r.read<String>('chunk_id')).toList(growable: false);
}
