/// Memory bank service: a typed view of the `memory_bank_rows` table used by
/// the browse / filter / delete UI. Mirrors Tumin's `MemoryBankService`
/// (typed queries + LIKE keyword search + 6-axis stats + no-op vector
/// indexer), adapted to Cuplivo's drift + provider conventions.
///
/// Vector operations stay no-ops for parity with Tumin's
/// `// No-op: vector index removed` / `// No-op: vector processing removed`
/// markers. The `embedding` column is reserved for a future embedding
/// pipeline; until then, the consumer side falls back to keyword search.
library;

import 'dart:async';

import 'package:drift/drift.dart';

import '../database/app_database.dart';

class MemoryStats {
  final int total;
  final int messageCount;
  final int summaryCount;
  final int manualCount;
  final int vectorizedCount;
  final int pendingCount;
  final int failedCount;

  const MemoryStats({
    this.total = 0,
    this.messageCount = 0,
    this.summaryCount = 0,
    this.manualCount = 0,
    this.vectorizedCount = 0,
    this.pendingCount = 0,
    this.failedCount = 0,
  });
}

class MemoryBankService {
  final AppDatabase _db;
  MemoryBankService(this._db);

  static const int recallCount = 3;

  /// All five `type` values the memory bank distinguishes. Kept in sync
  /// with the column default (`'message'`) and the UI's filter chip row.
  static const List<String> typeValues = <String>[
    'message',
    'phase_summary',
    'daily_summary',
    'manual',
    'auto_summary',
  ];

  Future<List<String>> getAssistantIds() async {
    final query = _db.selectOnly(_db.memoryBankRows)
      ..addColumns(<Expression<Object>>[_db.memoryBankRows.assistantId])
      ..where(_db.memoryBankRows.assistantId.isNotNull())
      ..groupBy(<Expression<Object>>[_db.memoryBankRows.assistantId]);
    final rows = await query.get();
    final ids = <String>[];
    for (final row in rows) {
      final id = row.read(_db.memoryBankRows.assistantId);
      if (id != null && id.isNotEmpty && !ids.contains(id)) ids.add(id);
    }
    return ids;
  }

  Future<MemoryStats> getStats(String? assistantId) async {
    final summaryTypes = <String>{'phase_summary', 'daily_summary'};
    return MemoryStats(
      total: await _count(
        assistantId: assistantId,
      ),
      messageCount: await _count(
        assistantId: assistantId,
        type: 'message',
      ),
      summaryCount: await _countByTypes(
        summaryTypes,
        assistantId: assistantId,
      ),
      manualCount: await _count(
        assistantId: assistantId,
        type: 'manual',
      ),
      // Vector counts are aggregate stats (not per-assistant) — match the
      // original Tumin behavior so the stats card stays stable across
      // assistant filters.
      vectorizedCount: assistantId == null
          ? await _countByVectorStatus('done')
          : 0,
      pendingCount: assistantId == null
          ? await _countByVectorStatus('pending')
          : 0,
      failedCount: assistantId == null
          ? await _countByVectorStatus('failed')
          : 0,
    );
  }

  Future<int> _count({String? assistantId, String? type}) async {
    final q = _db.selectOnly(_db.memoryBankRows)
      ..addColumns(<Expression<Object>>[_db.memoryBankRows.id.count()]);
    if (assistantId != null) {
      q.where(_db.memoryBankRows.assistantId.equals(assistantId));
    }
    if (type != null) {
      q.where(_db.memoryBankRows.type.equals(type));
    }
    final row = await q.getSingleOrNull();
    return row?.read(_db.memoryBankRows.id.count()) ?? 0;
  }

  Future<int> _countByTypes(
    Set<String> types, {
    String? assistantId,
  }) async {
    final q = _db.selectOnly(_db.memoryBankRows)
      ..addColumns(<Expression<Object>>[_db.memoryBankRows.id.count()])
      ..where(_db.memoryBankRows.type.isIn(types));
    if (assistantId != null) {
      q.where(_db.memoryBankRows.assistantId.equals(assistantId));
    }
    final row = await q.getSingleOrNull();
    return row?.read(_db.memoryBankRows.id.count()) ?? 0;
  }

  Future<int> _countByVectorStatus(String status, {String? assistantId}) async {
    final q = _db.selectOnly(_db.memoryBankRows)
      ..addColumns(<Expression<Object>>[_db.memoryBankRows.id.count()])
      ..where(_db.memoryBankRows.vectorStatus.equals(status));
    if (assistantId != null) {
      q.where(_db.memoryBankRows.assistantId.equals(assistantId));
    }
    final row = await q.getSingleOrNull();
    return row?.read(_db.memoryBankRows.id.count()) ?? 0;
  }

  /// Today's phase summaries (type=phase_summary, date_group=today).
  Future<List<MemoryBankRow>> getTodayPhaseSummaries(String? assistantId) {
    return _getByDateGroup('phase_summary', assistantId);
  }

  /// Today's daily summaries (type=daily_summary, date_group=today).
  Future<List<MemoryBankRow>> getDailySummaries(String? assistantId) {
    return _getByDateGroup('daily_summary', assistantId);
  }

  Future<List<MemoryBankRow>> _getByDateGroup(
    String type,
    String? assistantId,
  ) async {
    final today = _todayYyyyMmDd();
    final q = _db.select(_db.memoryBankRows)
      ..where((r) => r.type.equals(type) & r.dateGroup.equals(today))
      ..orderBy([(r) => OrderingTerm.desc(r.createdAt)]);
    if (assistantId != null) {
      q.where((r) => r.assistantId.equals(assistantId));
    }
    return q.get();
  }

  String _todayYyyyMmDd() {
    final now = DateTime.now();
    final mm = now.month.toString().padLeft(2, '0');
    final dd = now.day.toString().padLeft(2, '0');
    return '${now.year}-$mm-$dd';
  }

  /// Search by keyword and/or type. When neither is set, returns the most
  /// recent [limit] entries.
  Future<List<MemoryBankRow>> searchMemories({
    String keyword = '',
    String type = '',
    int limit = 100,
    String? assistantId,
  }) async {
    final q = _db.select(_db.memoryBankRows)
      ..orderBy([(r) => OrderingTerm.desc(r.createdAt)])
      ..limit(limit);
    if (keyword.isNotEmpty && type.isNotEmpty) {
      q.where((r) => r.content.like('%$keyword%') & r.type.equals(type));
    } else if (keyword.isNotEmpty) {
      q.where((r) => r.content.like('%$keyword%'));
    } else if (type.isNotEmpty && assistantId != null) {
      q.where((r) => r.type.equals(type) & r.assistantId.equals(assistantId));
    } else if (type.isNotEmpty) {
      q.where((r) => r.type.equals(type));
    }
    return q.get();
  }

  Future<void> deleteMemoryById(int id) async {
    await (_db.delete(_db.memoryBankRows)
          ..where((r) => r.id.equals(id)))
        .go();
  }

  /// No-op stub for parity with Tumin's `rebuildIndex` button. The vector
  /// pipeline is intentionally absent in the initial migration; the UI
  /// still surfaces the action so users see a known affordance. Re-implement
  /// when a real embedding pipeline lands.
  Future<void> rebuildIndex() async {}

  /// No-op stub for parity with Tumin's `processPendingVectors` button.
  /// See [rebuildIndex] for the rationale.
  Future<void> processPendingVectors() async {}

  /// Insert a `manual` memory (e.g. "User prefers Chinese replies").
  /// Returns the new row with the generated id.
  Future<MemoryBankRow> saveManualMemory(String content) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await _db.into(_db.memoryBankRows).insert(
      MemoryBankRowsCompanion.insert(
        content: Value(content),
        type: const Value('manual'),
        createdAt: now,
      ),
    );
    return (await (_db.select(_db.memoryBankRows)
              ..where((r) => r.id.equals(id)))
            .getSingle());
  }

  /// Insert a `message` memory — used by the chat pipeline to log a
  /// single user/assistant turn into the bank. Returns the new row, or
  /// `null` when the insert silently failed (drift's `.go()` returns 0).
  Future<MemoryBankRow?> saveChatMessage({
    required String content,
    required String role,
    String? assistantId,
    String? conversationId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await _db.into(_db.memoryBankRows).insert(
      MemoryBankRowsCompanion.insert(
        content: Value(content),
        type: const Value('message'),
        role: Value(role),
        assistantId: Value(assistantId),
        conversationId: Value(conversationId),
        createdAt: now,
        dateGroup: Value(_todayYyyyMmDd()),
        vectorStatus: const Value('skipped'),
      ),
    );
    if (id == 0) return null;
    return (await (_db.select(_db.memoryBankRows)
              ..where((r) => r.id.equals(id)))
            .getSingle());
  }

  /// Insert a `phase_summary` or `auto_summary` memory — used by the
  /// background summary pipeline (Phase 2 / Phase 3 reserved interface).
  Future<MemoryBankRow?> saveSummary({
    required String content,
    required String type,
    String? assistantId,
    String? conversationId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await _db.into(_db.memoryBankRows).insert(
      MemoryBankRowsCompanion.insert(
        content: Value(content),
        type: Value(type),
        assistantId: Value(assistantId),
        conversationId: Value(conversationId),
        createdAt: now,
        dateGroup: Value(_todayYyyyMmDd()),
        vectorStatus: const Value('skipped'),
      ),
    );
    if (id == 0) return null;
    return (await (_db.select(_db.memoryBankRows)
              ..where((r) => r.id.equals(id)))
            .getSingle());
  }

  /// Keyword recall — used by the chat pipeline's long-term memory
  /// injection (the vector path returns `null` and the caller falls back
  /// to keyword recall in that case).
  Future<List<MemoryBankRow>> recallMemories({
    required String query,
    required int count,
    String? assistantId,
  }) async {
    if (query.trim().isEmpty) {
      final q = _db.select(_db.memoryBankRows)
        ..orderBy([(r) => OrderingTerm.desc(r.createdAt)])
        ..limit(count);
      if (assistantId != null) {
        q.where((r) => r.assistantId.equals(assistantId));
      }
      return q.get();
    }
    return searchMemories(
      keyword: query,
      limit: count,
      assistantId: assistantId,
    );
  }

  /// Vector recall — no-op for now (the embedding pipeline is reserved).
  /// Returns the keyword-fallback results so the chat pipeline can keep
  /// moving forward without branching on the vector availability.
  Future<List<MemoryBankRow>> vectorRecall({
    required List<double> queryEmbedding,
    String? assistantId,
    int count = recallCount,
  }) async {
    return recallMemories(query: '', count: count, assistantId: assistantId);
  }
}
