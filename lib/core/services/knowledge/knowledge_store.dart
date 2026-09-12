import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../database/app_database.dart';
import '../../database/business_preferences.dart';
import '../../models/knowledge.dart';
import 'knowledge_chunker.dart';
import 'knowledge_query.dart';

/// A ranked retrieval result: the matching chunk plus its citation source.
class KnowledgeSearchHit {
  final KnowledgeChunk chunk;
  final String documentName;
  final double score;

  const KnowledgeSearchHit({
    required this.chunk,
    required this.documentName,
    required this.score,
  });
}

/// Data access for the knowledge base feature (issue #389).
///
/// Owns the three typed tables plus the hand-managed `knowledge_fts` FTS5
/// index (created by [AppDatabase]'s schema heal). Document text is the source
/// of truth; chunks and the FTS index are derived data kept in sync by
/// [insertDocumentWithChunks] / [deleteDocument] / [deleteBase].
///
/// Assistant binding lives in the `preference_rows` KV map
/// ([activeIdsByAssistantKey]), mirroring WorldBook — deliberately not a join
/// table.
class KnowledgeStore {
  KnowledgeStore(this._db, this._preferences);

  final AppDatabase _db;
  final BusinessPreferences _preferences;

  static const String activeIdsByAssistantKey =
      'knowledge_base_ids_by_assistant_v1';
  static const String topKByAssistantKey = 'knowledge_top_k_by_assistant_v1';
  static const int defaultTopK = 5;
  static const String _defaultAssistantKey = '__global__';

  static String assistantKey(String? assistantId) {
    final id = (assistantId ?? '').trim();
    return id.isEmpty ? _defaultAssistantKey : id;
  }

  // --- Knowledge bases ---

  Future<List<KnowledgeBase>> getAllBases() async {
    final rows = await (_db.select(
      _db.knowledgeBaseRows,
    )..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).get();
    return rows.map(_baseFromRow).toList(growable: false);
  }

  Future<KnowledgeBase?> getBase(String id) async {
    final row = await (_db.select(
      _db.knowledgeBaseRows,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _baseFromRow(row);
  }

  Future<void> upsertBase(KnowledgeBase base) async {
    await _db
        .into(_db.knowledgeBaseRows)
        .insertOnConflictUpdate(
          KnowledgeBaseRowsCompanion.insert(
            id: base.id,
            name: base.name,
            createdAt: base.createdAt,
            updatedAt: base.updatedAt,
            description: Value(base.description),
            enabled: Value(base.enabled),
            chunkSize: Value(base.chunkSize),
            chunkOverlap: Value(base.chunkOverlap),
          ),
        );
  }

  /// Deletes a base plus all owned documents/chunks and its FTS rows, then
  /// purges the id from every assistant binding.
  Future<void> deleteBase(String id) async {
    await _db.transaction(() async {
      await _db.customStatement('DELETE FROM knowledge_fts WHERE kb_id = ?', [
        id,
      ]);
      await (_db.delete(
        _db.knowledgeChunkRows,
      )..where((t) => t.knowledgeBaseId.equals(id))).go();
      await (_db.delete(
        _db.knowledgeDocumentRows,
      )..where((t) => t.knowledgeBaseId.equals(id))).go();
      await (_db.delete(
        _db.knowledgeBaseRows,
      )..where((t) => t.id.equals(id))).go();
    });
    await _removeBaseFromBindings(id);
  }

  Future<int> countDocuments(String knowledgeBaseId) {
    return _db.knowledgeDocumentRows
        .count(where: (t) => t.knowledgeBaseId.equals(knowledgeBaseId))
        .getSingle();
  }

  Future<int> countChunks(String knowledgeBaseId) {
    return _db.knowledgeChunkRows
        .count(where: (t) => t.knowledgeBaseId.equals(knowledgeBaseId))
        .getSingle();
  }

  // --- Documents & chunks ---

  Future<List<KnowledgeDocument>> getDocuments(String knowledgeBaseId) async {
    final rows =
        await (_db.select(_db.knowledgeDocumentRows)
              ..where((t) => t.knowledgeBaseId.equals(knowledgeBaseId))
              ..orderBy([(t) => OrderingTerm.asc(t.importedAt)]))
            .get();
    return rows.map(_documentFromRow).toList(growable: false);
  }

  Future<KnowledgeDocument?> getDocument(String id) async {
    final row = await (_db.select(
      _db.knowledgeDocumentRows,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _documentFromRow(row);
  }

  /// Per-base duplicate detection: the same content may be imported into a
  /// different base, but not twice into the same one.
  Future<KnowledgeDocument?> findDocumentByHash(
    String knowledgeBaseId,
    String contentHash,
  ) async {
    final row =
        await (_db.select(_db.knowledgeDocumentRows)..where(
              (t) =>
                  t.knowledgeBaseId.equals(knowledgeBaseId) &
                  t.contentHash.equals(contentHash),
            ))
            .getSingleOrNull();
    return row == null ? null : _documentFromRow(row);
  }

  /// Inserts the document and its chunks atomically, keeping the FTS index in
  /// sync (one FTS row per chunk).
  Future<void> insertDocumentWithChunks(
    KnowledgeDocument document,
    List<KnowledgeChunk> chunks,
  ) async {
    await _db.transaction(() async {
      await _db
          .into(_db.knowledgeDocumentRows)
          .insert(
            KnowledgeDocumentRowsCompanion.insert(
              id: document.id,
              knowledgeBaseId: document.knowledgeBaseId,
              name: document.name,
              sourceType: document.sourceType,
              content: document.content,
              contentHash: document.contentHash,
              charCount: document.charCount,
              importedAt: document.importedAt,
              chunkTotal: Value(chunks.length),
            ),
          );
      await _insertChunksAndFts(chunks);
    });
  }

  /// Rebuilds chunks and the FTS index for [documentId] from the stored text
  /// (the source of truth). Returns the new chunk count, or 0 when the document
  /// no longer exists. Chunk IDs are regenerated.
  Future<int> rebuildChunksForDocument(
    String documentId, {
    required int chunkSize,
    required int chunkOverlap,
  }) async {
    final document = await getDocument(documentId);
    if (document == null) return 0;
    final pieces = KnowledgeChunker.chunk(
      document.content,
      chunkSize: chunkSize,
      chunkOverlap: chunkOverlap,
    );
    final chunks = <KnowledgeChunk>[
      for (var i = 0; i < pieces.length; i++)
        KnowledgeChunk(
          id: const Uuid().v4(),
          documentId: documentId,
          knowledgeBaseId: document.knowledgeBaseId,
          chunkIndex: i,
          content: pieces[i],
          charCount: pieces[i].length,
        ),
    ];
    await _db.transaction(() async {
      await _deleteChunksAndFtsForDocument(documentId);
      await _insertChunksAndFts(chunks);
      await (_db.update(
        _db.knowledgeDocumentRows,
      )..where((t) => t.id.equals(documentId))).write(
        KnowledgeDocumentRowsCompanion(chunkTotal: Value(chunks.length)),
      );
    });
    return chunks.length;
  }

  /// Rebuilds every document in [baseId] after its chunk parameters changed.
  Future<void> rebuildAllChunks(
    String baseId, {
    required int chunkSize,
    required int chunkOverlap,
  }) async {
    final documents = await getDocuments(baseId);
    for (final document in documents) {
      await rebuildChunksForDocument(
        document.id,
        chunkSize: chunkSize,
        chunkOverlap: chunkOverlap,
      );
    }
  }

  Future<void> deleteDocument(String documentId) async {
    await _db.transaction(() async {
      await _deleteChunksAndFtsForDocument(documentId);
      await (_db.delete(
        _db.knowledgeDocumentRows,
      )..where((t) => t.id.equals(documentId))).go();
    });
  }

  /// Wipes every base/document/chunk plus the FTS index (backup overwrite).
  Future<void> deleteAll() async {
    await _db.transaction(() async {
      await _db.customStatement('DELETE FROM knowledge_fts');
      await _db.delete(_db.knowledgeChunkRows).go();
      await _db.delete(_db.knowledgeDocumentRows).go();
      await _db.delete(_db.knowledgeBaseRows).go();
    });
  }

  /// Every document across all bases, for backup export.
  Future<List<KnowledgeDocument>> getAllDocuments() async {
    final rows = await (_db.select(
      _db.knowledgeDocumentRows,
    )..orderBy([(t) => OrderingTerm.asc(t.importedAt)])).get();
    return rows.map(_documentFromRow).toList(growable: false);
  }

  /// Inserts a document restored from a backup: chunks are rebuilt from the
  /// stored text with the owning base's parameters (chunks/FTS are derived and
  /// never travel in the backup).
  Future<void> restoreDocument(
    KnowledgeDocument document, {
    required int chunkSize,
    required int chunkOverlap,
  }) async {
    final pieces = KnowledgeChunker.chunk(
      document.content,
      chunkSize: chunkSize,
      chunkOverlap: chunkOverlap,
    );
    final chunks = <KnowledgeChunk>[
      for (var i = 0; i < pieces.length; i++)
        KnowledgeChunk(
          id: const Uuid().v4(),
          documentId: document.id,
          knowledgeBaseId: document.knowledgeBaseId,
          chunkIndex: i,
          content: pieces[i],
          charCount: pieces[i].length,
        ),
    ];
    await insertDocumentWithChunks(document, chunks);
  }

  Future<void> _insertChunksAndFts(List<KnowledgeChunk> chunks) async {
    for (final chunk in chunks) {
      await _db
          .into(_db.knowledgeChunkRows)
          .insert(
            KnowledgeChunkRowsCompanion.insert(
              id: chunk.id,
              documentId: chunk.documentId,
              knowledgeBaseId: chunk.knowledgeBaseId,
              chunkIndex: chunk.chunkIndex,
              content: chunk.content,
              charCount: chunk.charCount,
            ),
          );
      await _db.customStatement(
        'INSERT INTO knowledge_fts(content, kb_id, chunk_id) VALUES (?, ?, ?)',
        [chunk.content, chunk.knowledgeBaseId, chunk.id],
      );
    }
  }

  Future<void> _deleteChunksAndFtsForDocument(String documentId) async {
    await _db.customStatement(
      'DELETE FROM knowledge_fts WHERE chunk_id IN '
      '(SELECT id FROM knowledge_chunk_rows WHERE document_id = ?)',
      [documentId],
    );
    await (_db.delete(
      _db.knowledgeChunkRows,
    )..where((t) => t.documentId.equals(documentId))).go();
  }

  /// Chunks of one document in reading order (preview / acceptance surface).
  Future<List<KnowledgeChunk>> getChunksForDocument(String documentId) async {
    final rows =
        await (_db.select(_db.knowledgeChunkRows)
              ..where((t) => t.documentId.equals(documentId))
              ..orderBy([(t) => OrderingTerm.asc(t.chunkIndex)]))
            .get();
    return rows.map(_chunkFromRow).toList(growable: false);
  }

  // --- Retrieval (lexical channel: FTS5 with a short-query LIKE fallback) ---

  /// Ranks chunks in [baseIds] against [query]. Uses FTS5 `MATCH` + `bm25` when
  /// a term is indexable, otherwise falls back to a `LIKE` scan (trigram cannot
  /// tokenize terms shorter than 3 characters).
  Future<List<KnowledgeSearchHit>> search({
    required List<String> baseIds,
    required String query,
    int limit = defaultTopK,
  }) async {
    final ids = baseIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (ids.isEmpty || limit <= 0) return const <KnowledgeSearchHit>[];

    final match = KnowledgeQuery.buildFtsMatch(query);
    if (match != null) {
      return _searchFts(match, ids, limit);
    }
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const <KnowledgeSearchHit>[];
    return _searchLike(trimmed, ids, limit);
  }

  Future<List<KnowledgeSearchHit>> _searchFts(
    String match,
    List<String> baseIds,
    int limit,
  ) async {
    final placeholders = List.filled(baseIds.length, '?').join(', ');
    final rows = await _db
        .customSelect(
          'SELECT c.id AS chunk_id, c.document_id, c.knowledge_base_id, '
          'c.chunk_index, c.content, c.char_count, d.name AS document_name, '
          'bm25(knowledge_fts) AS score '
          'FROM knowledge_fts '
          'JOIN knowledge_chunk_rows c ON c.id = knowledge_fts.chunk_id '
          'JOIN knowledge_document_rows d ON d.id = c.document_id '
          'WHERE knowledge_fts MATCH ? '
          'AND knowledge_fts.kb_id IN ($placeholders) '
          'ORDER BY score ASC, c.chunk_index ASC '
          'LIMIT ?',
          variables: [
            Variable.withString(match),
            ...baseIds.map(Variable.withString),
            Variable.withInt(limit),
          ],
        )
        .get();
    return rows.map(_hitFromRow).toList(growable: false);
  }

  Future<List<KnowledgeSearchHit>> _searchLike(
    String query,
    List<String> baseIds,
    int limit,
  ) async {
    final placeholders = List.filled(baseIds.length, '?').join(', ');
    final rows = await _db
        .customSelect(
          'SELECT c.id AS chunk_id, c.document_id, c.knowledge_base_id, '
          'c.chunk_index, c.content, c.char_count, d.name AS document_name, '
          '0.0 AS score '
          'FROM knowledge_chunk_rows c '
          'JOIN knowledge_document_rows d ON d.id = c.document_id '
          'WHERE c.knowledge_base_id IN ($placeholders) '
          "AND c.content LIKE ? ESCAPE '\\' "
          'ORDER BY c.knowledge_base_id ASC, c.document_id ASC, '
          'c.chunk_index ASC '
          'LIMIT ?',
          variables: [
            ...baseIds.map(Variable.withString),
            Variable.withString(KnowledgeQuery.likePattern(query)),
            Variable.withInt(limit),
          ],
        )
        .get();
    return rows.map(_hitFromRow).toList(growable: false);
  }

  static KnowledgeSearchHit _hitFromRow(QueryRow row) => KnowledgeSearchHit(
    chunk: KnowledgeChunk(
      id: row.read<String>('chunk_id'),
      documentId: row.read<String>('document_id'),
      knowledgeBaseId: row.read<String>('knowledge_base_id'),
      chunkIndex: row.read<int>('chunk_index'),
      content: row.read<String>('content'),
      charCount: row.read<int>('char_count'),
    ),
    documentName: row.read<String>('document_name'),
    score: row.read<double>('score'),
  );

  // --- Assistant bindings (KV map, WorldBook pattern) ---

  Future<Map<String, List<String>>> getActiveBaseIdsByAssistant() async {
    return _decodeBindings(_preferences.getString(activeIdsByAssistantKey));
  }

  Future<List<String>> getActiveBaseIds({String? assistantId}) async {
    final map = await getActiveBaseIdsByAssistant();
    final direct = map[assistantKey(assistantId)];
    if (direct != null) return List<String>.from(direct);
    return List<String>.from(map[_defaultAssistantKey] ?? const <String>[]);
  }

  Future<void> setActiveBaseIds(List<String> ids, {String? assistantId}) async {
    final map = await getActiveBaseIdsByAssistant();
    map[assistantKey(assistantId)] = _cleanIds(ids);
    await setActiveBaseIdsMap(map);
  }

  Future<void> setActiveBaseIdsMap(Map<String, List<String>> map) async {
    final next = <String, List<String>>{};
    map.forEach((key, value) {
      final id = key.trim();
      if (id.isEmpty) return;
      next[id] = _cleanIds(value);
    });
    await _preferences.setString(activeIdsByAssistantKey, jsonEncode(next));
  }

  static List<String> _cleanIds(Iterable<Object?> ids) => ids
      .map((e) => e.toString().trim())
      .where((e) => e.isNotEmpty)
      .toSet()
      .toList(growable: false);

  // --- Assistant-level retrieval knob (topK) ---

  Future<int> getTopK({String? assistantId}) async {
    final map = _decodeTopK(_preferences.getString(topKByAssistantKey));
    final value = map[assistantKey(assistantId)] ?? map[_defaultAssistantKey];
    return value == null || value < 1 ? defaultTopK : value;
  }

  Future<Map<String, int>> getTopKMap() async => Map<String, int>.from(
    _decodeTopK(_preferences.getString(topKByAssistantKey)),
  );

  Future<void> setTopK(int value, {String? assistantId}) async {
    final map = _decodeTopK(_preferences.getString(topKByAssistantKey));
    map[assistantKey(assistantId)] = value < 1 ? defaultTopK : value;
    await _preferences.setString(topKByAssistantKey, jsonEncode(map));
  }

  Map<String, int> _decodeTopK(String? raw) {
    final map = <String, int>{};
    if (raw == null || raw.isEmpty) return map;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        decoded.forEach((key, value) {
          final parsed = value is num ? value.toInt() : int.tryParse('$value');
          if (parsed != null) map[key.toString()] = parsed;
        });
      }
    } catch (e) {
      debugPrint('KnowledgeStore: failed to decode topK settings: $e');
    }
    return map;
  }

  Map<String, List<String>> _decodeBindings(String? raw) {
    final map = <String, List<String>>{};
    if (raw == null || raw.isEmpty) return map;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        decoded.forEach((key, value) {
          final list = value is List ? value : const <Object?>[];
          map[key.toString()] = _cleanIds(list);
        });
      }
    } catch (e) {
      debugPrint('KnowledgeStore: failed to decode assistant bindings: $e');
    }
    return map;
  }

  Future<void> _removeBaseFromBindings(String baseId) async {
    final map = await getActiveBaseIdsByAssistant();
    var changed = false;
    final next = <String, List<String>>{};
    map.forEach((key, value) {
      final filtered = value.where((e) => e != baseId).toList(growable: false);
      if (filtered.length != value.length) changed = true;
      next[key] = filtered;
    });
    if (changed) await setActiveBaseIdsMap(next);
  }

  // --- Row mappers ---

  static KnowledgeBase _baseFromRow(KnowledgeBaseRow row) => KnowledgeBase(
    id: row.id,
    name: row.name,
    description: row.description,
    enabled: row.enabled,
    chunkSize: row.chunkSize,
    chunkOverlap: row.chunkOverlap,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );

  static KnowledgeDocument _documentFromRow(KnowledgeDocumentRow row) =>
      KnowledgeDocument(
        id: row.id,
        knowledgeBaseId: row.knowledgeBaseId,
        name: row.name,
        sourceType: row.sourceType,
        content: row.content,
        contentHash: row.contentHash,
        charCount: row.charCount,
        chunkTotal: row.chunkTotal,
        importedAt: row.importedAt,
      );

  static KnowledgeChunk _chunkFromRow(KnowledgeChunkRow row) => KnowledgeChunk(
    id: row.id,
    documentId: row.documentId,
    knowledgeBaseId: row.knowledgeBaseId,
    chunkIndex: row.chunkIndex,
    content: row.content,
    charCount: row.charCount,
  );
}
