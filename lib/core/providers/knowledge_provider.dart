import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../database/business_preferences.dart';
import '../models/knowledge.dart';
import '../services/chat/chat_service.dart';
import '../services/knowledge/knowledge_import_service.dart';
import '../services/knowledge/knowledge_store.dart';

/// Aggregate counts shown on the knowledge base list card.
class KnowledgeBaseStats {
  final int documents;
  final int chunks;

  const KnowledgeBaseStats({required this.documents, required this.chunks});
}

/// Knowledge base UI state (issue #389). Storage access is delegated to
/// [KnowledgeStore]; this provider owns the loaded base list and the binding
/// map so the management pages and the assistant settings tab can rebuild from
/// one source.
class KnowledgeProvider extends ChangeNotifier {
  KnowledgeProvider({required this._preferences, this.chatService});

  final BusinessPreferences _preferences;
  final ChatService? chatService;

  KnowledgeStore? _store;
  List<KnowledgeBase> _bases = const <KnowledgeBase>[];
  Map<String, List<String>> _activeIdsByAssistant =
      const <String, List<String>>{};
  Map<String, int> _topKByAssistant = const <String, int>{};
  Map<String, KnowledgeBaseStats> _statsByBase =
      const <String, KnowledgeBaseStats>{};
  Map<String, List<KnowledgeSearchHit>> _hitsByConversation =
      <String, List<KnowledgeSearchHit>>{};
  bool _initialized = false;

  bool _importing = false;
  int _importCompleted = 0;
  int _importTotal = 0;
  String? _importCurrentName;
  bool _rebuilding = false;

  List<KnowledgeBase> get bases => List<KnowledgeBase>.unmodifiable(_bases);
  bool get initialized => _initialized;

  bool get importing => _importing;
  bool get rebuilding => _rebuilding;
  int get importCompleted => _importCompleted;
  int get importTotal => _importTotal;
  String? get importCurrentName => _importCurrentName;

  KnowledgeBase? getById(String id) {
    for (final base in _bases) {
      if (base.id == id) return base;
    }
    return null;
  }

  List<String> activeBaseIdsFor(String? assistantId) {
    final key = KnowledgeStore.assistantKey(assistantId);
    if (_activeIdsByAssistant.containsKey(key)) {
      return List<String>.unmodifiable(_activeIdsByAssistant[key]!);
    }
    final fallback =
        _activeIdsByAssistant[KnowledgeStore.assistantKey(null)] ??
        const <String>[];
    return List<String>.unmodifiable(fallback);
  }

  bool isBaseActive(String id, {String? assistantId}) =>
      activeBaseIdsFor(assistantId).contains(id);

  /// True when at least one assistant (explicit or the `__global__` fallback)
  /// binds [baseId]. An unbound base can never be retrieved — the list surfaces
  /// this so a silent non-injection is visible at a glance.
  bool isBaseBoundToAnyAssistant(String baseId) {
    for (final ids in _activeIdsByAssistant.values) {
      if (ids.contains(baseId)) return true;
    }
    return false;
  }

  /// Assistant-level max injected chunks, with `__global__` fallback.
  int topKFor(String? assistantId) {
    final key = KnowledgeStore.assistantKey(assistantId);
    return _topKByAssistant[key] ??
        _topKByAssistant[KnowledgeStore.assistantKey(null)] ??
        KnowledgeStore.defaultTopK;
  }

  /// The most recent lexical retrieval result for [conversationId], for the
  /// session-scoped LivePanel pill. Never persisted.
  List<KnowledgeSearchHit> retrievalHitsFor(String? conversationId) {
    if (conversationId == null) return const <KnowledgeSearchHit>[];
    return _hitsByConversation[conversationId] ?? const <KnowledgeSearchHit>[];
  }

  /// Records the hits of the generation that just ran for [conversationId]. An
  /// empty result clears the entry so a stale pill disappears.
  void reportRetrieval(String? conversationId, List<KnowledgeSearchHit> hits) {
    debugPrint(
      '[Knowledge] reportRetrieval: '
      'conversationId=${conversationId ?? '(null)'} hits=${hits.length}',
    );
    if (conversationId == null) return;
    if (hits.isEmpty) {
      if (_hitsByConversation.remove(conversationId) != null) {
        notifyListeners();
      }
      return;
    }
    _hitsByConversation[conversationId] = List<KnowledgeSearchHit>.unmodifiable(
      hits,
    );
    notifyListeners();
  }

  /// Lazily opens storage through [ChatService] (single shared [AppDatabase]).
  Future<KnowledgeStore> ensureStore() async {
    final existing = _store;
    if (existing != null) return existing;
    final service = chatService;
    if (service == null) {
      throw StateError(
        'KnowledgeProvider requires a ChatService to open knowledge storage',
      );
    }
    await service.init();
    return _store ??= KnowledgeStore(service.repo.db, _preferences);
  }

  Future<void> initialize() async {
    if (_initialized) return;
    await loadAll();
  }

  Future<void> loadAll() async {
    final store = await ensureStore();
    _bases = await store.getAllBases();
    _activeIdsByAssistant = await store.getActiveBaseIdsByAssistant();
    _topKByAssistant = await store.getTopKMap();
    final stats = <String, KnowledgeBaseStats>{};
    for (final base in _bases) {
      stats[base.id] = KnowledgeBaseStats(
        documents: await store.countDocuments(base.id),
        chunks: await store.countChunks(base.id),
      );
    }
    _statsByBase = stats;
    // The index may have changed; a previously reported pill is now stale.
    _hitsByConversation = <String, List<KnowledgeSearchHit>>{};
    _initialized = true;
    notifyListeners();
  }

  KnowledgeBaseStats statsForSync(String baseId) =>
      _statsByBase[baseId] ?? const KnowledgeBaseStats(documents: 0, chunks: 0);

  Future<KnowledgeBase> createBase({
    required String name,
    String description = '',
    int chunkSize = 512,
    int chunkOverlap = 64,
  }) async {
    final store = await ensureStore();
    final now = DateTime.now();
    final base = KnowledgeBase(
      id: const Uuid().v4(),
      name: name.trim(),
      description: description.trim(),
      chunkSize: chunkSize,
      chunkOverlap: chunkOverlap,
      createdAt: now,
      updatedAt: now,
    );
    await store.upsertBase(base);
    await loadAll();
    return base;
  }

  Future<void> updateBase(KnowledgeBase base) async {
    final store = await ensureStore();
    final previous = getById(base.id);
    final chunkChanged =
        previous != null &&
        (previous.chunkSize != base.chunkSize ||
            previous.chunkOverlap != base.chunkOverlap);
    await store.upsertBase(base.copyWith(updatedAt: DateTime.now()));
    if (chunkChanged) {
      _rebuilding = true;
      notifyListeners();
      try {
        await store.rebuildAllChunks(
          base.id,
          chunkSize: base.chunkSize,
          chunkOverlap: base.chunkOverlap,
        );
      } finally {
        _rebuilding = false;
        notifyListeners();
      }
    }
    await loadAll();
  }

  Future<void> deleteBase(String id) async {
    final store = await ensureStore();
    await store.deleteBase(id);
    await loadAll();
  }

  Future<void> setActiveBaseIds(List<String> ids, {String? assistantId}) async {
    final store = await ensureStore();
    await store.setActiveBaseIds(ids, assistantId: assistantId);
    await loadAll();
  }

  Future<void> setTopK(int value, {String? assistantId}) async {
    final store = await ensureStore();
    await store.setTopK(value, assistantId: assistantId);
    _topKByAssistant = await store.getTopKMap();
    notifyListeners();
  }

  // --- Document management (detail page) ---

  Future<List<KnowledgeDocument>> documents(String baseId) async =>
      (await ensureStore()).getDocuments(baseId);

  Future<List<KnowledgeChunk>> chunksForDocument(String documentId) async =>
      (await ensureStore()).getChunksForDocument(documentId);

  Future<void> deleteDocument(String documentId) async {
    final store = await ensureStore();
    await store.deleteDocument(documentId);
    await loadAll();
  }

  /// Imports [files] into [baseId] sequentially, exposing per-file progress.
  /// A single bad file does not abort the batch; it is reported as failed.
  Future<List<KnowledgeImportResult>> importFiles(
    String baseId,
    List<KnowledgeImportFile> files,
  ) async {
    if (files.isEmpty) return const <KnowledgeImportResult>[];
    final base = getById(baseId);
    if (base == null) {
      throw StateError('Knowledge base not found: $baseId');
    }
    final store = await ensureStore();
    final service = KnowledgeImportService(store: store);
    _importing = true;
    _importCompleted = 0;
    _importTotal = files.length;
    _importCurrentName = null;
    notifyListeners();

    final results = <KnowledgeImportResult>[];
    try {
      for (final file in files) {
        _importCurrentName = file.name;
        notifyListeners();
        try {
          results.add(
            await service.importPath(
              base: base,
              path: file.path,
              fileName: file.name,
            ),
          );
        } catch (e) {
          debugPrint('KnowledgeProvider: import failed for ${file.name}: $e');
          results.add(
            KnowledgeImportResult(
              fileName: file.name,
              status: KnowledgeImportStatus.failed,
              detail: '$e',
            ),
          );
        }
        _importCompleted++;
        notifyListeners();
      }
    } finally {
      _importing = false;
      _importCurrentName = null;
      notifyListeners();
    }
    await loadAll();
    return results;
  }
}
