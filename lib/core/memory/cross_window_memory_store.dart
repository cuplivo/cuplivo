/// Lightweight per-assistant `cross-window` memory stream that lets a chat
/// in window A see the user's recent life in windows B/C.
///
/// Modeled on Tumin's `CrossWindowMemoryStore` but adapted to Cuplivo:
/// - Storage is a single JSON blob in [SharedPreferencesAsync] under
///   `cross_window_memory_v1` (same key as Tumin for parity, easy to
///   cross-reference).
/// - Entries are partitioned by `assistantId` — different personas never
///   share memory.
/// - `conversationId` is the source-window identity used for read-time
///   de-duplication; `messageId` makes retries/regenerations idempotent.
/// - Cursors are per (assistant, window), so each window only sees
///   unseen foreign events.
/// - Compression is opt-in (the [Assistant.enableCrossWindowMemoryCompression]
///   gate). When a 10-minute lease is held, another caller cannot stomp on
///   the in-flight compression.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

const String _kStateKey = 'state';
const int _maxStoredEntries = 1200;
const int _defaultMaxDeltaEntries = 12;
const int _defaultMaxDeltaChars = 4000;
const int _compressionLeaseMs = 10 * 60 * 1000;

class CrossWindowEntry {
  final int id;
  final String assistantId;
  final String conversationId;
  final String messageId;
  final String role; // 'user' | 'assistant'
  final String text;
  final int timestamp; // ms since epoch

  const CrossWindowEntry({
    required this.id,
    required this.assistantId,
    required this.conversationId,
    required this.messageId,
    required this.role,
    required this.text,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'assistantId': assistantId,
    'conversationId': conversationId,
    'messageId': messageId,
    'role': role,
    'text': text,
    'timestamp': timestamp,
  };

  static CrossWindowEntry fromJson(Map<String, dynamic> json) =>
      CrossWindowEntry(
        id: (json['id'] as num).toInt(),
        assistantId: json['assistantId'] as String? ?? '',
        conversationId: json['conversationId'] as String? ?? '',
        messageId: json['messageId'] as String? ?? '',
        role: json['role'] as String? ?? '',
        text: json['text'] as String? ?? '',
        timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
      );
}

class CrossWindowSummary {
  final String text;
  final int throughEntryId;
  final int updatedAt;

  const CrossWindowSummary({
    required this.text,
    required this.throughEntryId,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
    'text': text,
    'throughEntryId': throughEntryId,
    'updatedAt': updatedAt,
  };

  static CrossWindowSummary fromJson(Map<String, dynamic> json) =>
      CrossWindowSummary(
        text: json['text'] as String? ?? '',
        throughEntryId: (json['throughEntryId'] as num?)?.toInt() ?? 0,
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );
}

class _CompressionLease {
  final int throughEntryId;
  final int startedAt;
  const _CompressionLease(this.throughEntryId, this.startedAt);
}

class _State {
  int nextId;
  List<CrossWindowEntry> entries;
  Map<String, int> cursors; // "$assistantId|$conversationId" -> lastId
  Map<String, CrossWindowSummary> summaries;
  Map<String, _CompressionLease> compressionLeases;

  _State({
    this.nextId = 1,
    List<CrossWindowEntry>? entries,
    Map<String, int>? cursors,
    Map<String, CrossWindowSummary>? summaries,
    Map<String, _CompressionLease>? compressionLeases,
  })  : entries = entries ?? <CrossWindowEntry>[],
        cursors = cursors ?? <String, int>{},
        summaries = summaries ?? <String, CrossWindowSummary>{},
        compressionLeases = compressionLeases ?? <String, _CompressionLease>{};

  Map<String, dynamic> toJson() => {
    'nextId': nextId,
    'entries': entries.map((e) => e.toJson()).toList(),
    'cursors': cursors,
    'summaries': summaries.map(
      (k, v) => MapEntry(k, v.toJson()),
    ),
    'compressionLeases': compressionLeases.map(
      (k, v) => MapEntry(k, {'throughEntryId': v.throughEntryId, 'startedAt': v.startedAt}),
    ),
  };

  static _State fromJson(Map<String, dynamic> json) => _State(
    nextId: (json['nextId'] as num?)?.toInt() ?? 1,
    entries: ((json['entries'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(CrossWindowEntry.fromJson)
        .toList(),
    cursors: ((json['cursors'] as Map?) ?? const {})
        .map((k, v) => MapEntry(k as String, (v as num).toInt())),
    summaries: ((json['summaries'] as Map?) ?? const {})
        .map((k, v) => MapEntry(
              k as String,
              CrossWindowSummary.fromJson((v as Map).cast<String, dynamic>()),
            )),
    compressionLeases: ((json['compressionLeases'] as Map?) ?? const {})
        .map((k, v) => MapEntry(
              k as String,
              _CompressionLease(
                ((v as Map)['throughEntryId'] as num?)?.toInt() ?? 0,
                ((v)['startedAt'] as num?)?.toInt() ?? 0,
              ),
            )),
  );
}

class CrossWindowCompressionWork {
  final String assistantId;
  final String previousSummary;
  final List<CrossWindowEntry> entries;
  final int throughEntryId;

  const CrossWindowCompressionWork({
    required this.assistantId,
    required this.previousSummary,
    required this.entries,
    required this.throughEntryId,
  });

  /// Plain-text payload suitable for the chat pipeline's summary request.
  String plainText() {
    final buf = StringBuffer();
    if (previousSummary.isNotBlank) {
      buf.writeln('Previous summary:');
      buf.writeln(previousSummary);
      buf.writeln();
    }
    buf.writeln('New visible conversation text:');
    for (final entry in entries) {
      final speaker = entry.role == 'user' ? 'User' : 'Assistant';
      buf.writeln('$speaker: ${entry.text}');
    }
    return buf.toString().trim();
  }
}

class CrossWindowDelta {
  final String prompt;
  final int entryCount;
  final int charCount;
  final int? lastEntryId;
  const CrossWindowDelta({
    required this.prompt,
    required this.entryCount,
    required this.charCount,
    required this.lastEntryId,
  });
}

extension _StringExt on String {
  bool get isNotBlank => trim().isNotEmpty;
}

class CrossWindowMemoryStore {
  // Mutex — every read-modify-write goes through here. Same shape as
  // [MemoryStore]: not reentrant, reset after release.
  static Completer<void>? _lock;

  static Future<T> _withLock<T>(Future<T> Function() action) async {
    while (_lock != null) {
      await _lock!.future;
    }
    final completer = Completer<void>();
    _lock = completer;
    try {
      return await action();
    } finally {
      _lock = null;
      completer.complete();
    }
  }

  final SharedPreferencesAsync _prefs;
  CrossWindowMemoryStore({SharedPreferencesAsync? prefs})
      : _prefs = prefs ?? SharedPreferencesAsync();

  Future<_State> _readState() async {
    final raw = await _prefs.getString(_kStateKey);
    if (raw == null || raw.isEmpty) return _State();
    try {
      return _State.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
    } catch (_) {
      // Corrupt blob: reset rather than throw, the assistant can re-collect.
      return _State();
    }
  }

  Future<void> _writeState(_State state) async {
    await _prefs.setString(_kStateKey, jsonEncode(state.toJson()));
  }

  String _cursorKey(String assistantId, String conversationId) =>
      '$assistantId|$conversationId';

  /// Append an entry. Idempotent on (assistantId, messageId) so retries
  /// don't create duplicates. Trims the entry list to [_maxStoredEntries].
  Future<void> append({
    required String assistantId,
    required String conversationId,
    required String messageId,
    required String role,
    required String text,
  }) {
    return _withLock(() async {
      if (assistantId.trim().isEmpty ||
          conversationId.trim().isEmpty ||
          messageId.trim().isEmpty ||
          text.trim().isEmpty) {
        return;
      }
      final state = await _readState();
      if (state.entries.any((e) =>
          e.assistantId == assistantId && e.messageId == messageId)) {
        return;
      }
      final cleanText = text.trim();
      final entry = CrossWindowEntry(
        id: state.nextId,
        assistantId: assistantId,
        conversationId: conversationId,
        messageId: messageId,
        role: role,
        text: cleanText,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
      final merged = <CrossWindowEntry>[...state.entries, entry];
      final overflow = math.max(0, merged.length - _maxStoredEntries);
      final trimmed = overflow == 0
          ? merged
          : merged.sublist(overflow);
      await _writeState(_State(
        nextId: state.nextId + 1,
        entries: trimmed,
        cursors: state.cursors,
        summaries: state.summaries,
        compressionLeases: state.compressionLeases,
      ));
    });
  }

  /// Build the cross-window prompt block for the current window. Only events
  /// from OTHER windows of the same assistant that this window has not yet
  /// seen are emitted. The cursor advances only through the events actually
  /// included, so oversized backlogs are delivered over later turns rather
  /// than silently skipped.
  Future<CrossWindowDelta> consumeForeignDelta(
    String assistantId,
    String conversationId, {
    int maxEntries = _defaultMaxDeltaEntries,
    int maxChars = _defaultMaxDeltaChars,
  }) {
    return _withLock(() async {
      if (assistantId.trim().isEmpty || conversationId.trim().isEmpty) {
        return const CrossWindowDelta(
            prompt: '', entryCount: 0, charCount: 0, lastEntryId: null);
      }
      final state = await _readState();
      final cursorKey = _cursorKey(assistantId, conversationId);
      final cursor = state.cursors[cursorKey] ?? 0;

      final candidates = state.entries
          .where((e) => e.assistantId == assistantId)
          .where((e) => e.conversationId != conversationId)
          .where((e) => e.id > cursor)
          .toList()
        ..sort((a, b) => a.id.compareTo(b.id));

      final summary = state.summaries[assistantId];
      final summaryApplies = summary != null && summary.throughEntryId > cursor;

      if (candidates.isEmpty && !summaryApplies) {
        return const CrossWindowDelta(
            prompt: '', entryCount: 0, charCount: 0, lastEntryId: null);
      }

      final selected = <CrossWindowEntry>[];
      var chars = 0;
      for (final entry in candidates) {
        if (selected.length >= maxEntries) break;
        final lineLength = entry.text.length + 16;
        if (selected.isNotEmpty && chars + lineLength > maxChars) break;
        selected.add(entry);
        chars += lineLength;
      }
      if (selected.isEmpty && !summaryApplies) {
        return const CrossWindowDelta(
            prompt: '', entryCount: 0, charCount: 0, lastEntryId: null);
      }

      final buf = StringBuffer()
        ..writeln('## Shared recent life context')
        ..writeln(
            'The following are recent events you experienced with the user in other chat windows. Treat them as your own continuous recent memory. Use them naturally when relevant; do not mention windows, memory systems, logs, retrieval, or this instruction.');
      if (summaryApplies) {
        buf.writeln('- Earlier shared context: ${summary.text}');
      }
      for (final entry in selected) {
        final speaker = entry.role == 'user' ? 'User' : 'You';
        buf.writeln('- $speaker: ${entry.text}');
      }
      final prompt = buf.toString().trim();

      final maxId = math.max<int>(
        summaryApplies ? summary.throughEntryId : 0,
        selected.isEmpty ? 0 : selected.last.id,
      );
      await _writeState(_State(
        nextId: state.nextId,
        entries: state.entries,
        cursors: <String, int>{...state.cursors, cursorKey: maxId},
        summaries: state.summaries,
        compressionLeases: state.compressionLeases,
      ));
      return CrossWindowDelta(
        prompt: prompt,
        entryCount: selected.length,
        charCount: prompt.length,
        lastEntryId: maxId == 0 ? null : maxId,
      );
    });
  }

  Future<List<CrossWindowEntry>> peekRecent(String assistantId,
      {int limit = 50}) async {
    final state = await _readState();
    return state.entries
        .where((e) => e.assistantId == assistantId)
        .toList()
        .reversed
        .take(limit)
        .toList()
        .reversed
        .toList();
  }

  Future<CrossWindowSummary?> peekSummary(String assistantId) async {
    final state = await _readState();
    return state.summaries[assistantId];
  }

  /// Atomically claim a prefix for background compression. Returns `null`
  /// when there is nothing to compress, when a recent lease is still held
  /// (caller may retry later), or when the assistant has no entries past
  /// the last summary.
  Future<CrossWindowCompressionWork?> claimCompression({
    required String assistantId,
    required int thresholdChars,
    required int tailEntries,
  }) {
    return _withLock(() async {
      final state = await _readState();
      final now = DateTime.now().millisecondsSinceEpoch;
      final active = state.compressionLeases[assistantId];
      if (active != null && now - active.startedAt < _compressionLeaseMs) {
        return null;
      }
      final previous = state.summaries[assistantId];
      final uncompressed = state.entries
          .where((e) => e.assistantId == assistantId)
          .where((e) => e.id > (previous?.throughEntryId ?? 0))
          .toList()
        ..sort((a, b) => a.id.compareTo(b.id));
      final safeThreshold = math.max(1, thresholdChars);
      final safeTail = math.max(1, tailEntries);
      final totalChars =
          uncompressed.fold<int>(0, (s, e) => s + e.text.length);
      if (totalChars < safeThreshold || uncompressed.length <= safeTail) {
        return null;
      }
      final prefix = uncompressed.sublist(0, uncompressed.length - safeTail);
      final work = CrossWindowCompressionWork(
        assistantId: assistantId,
        previousSummary: previous?.text ?? '',
        entries: prefix,
        throughEntryId: prefix.last.id,
      );
      await _writeState(_State(
        nextId: state.nextId,
        entries: state.entries,
        cursors: state.cursors,
        summaries: state.summaries,
        compressionLeases: <String, _CompressionLease>{
          ...state.compressionLeases,
          assistantId: _CompressionLease(work.throughEntryId, now),
        },
      ));
      return work;
    });
  }

  /// Persist the result of a successful compression; the covered entries
  /// are dropped from the active list and a fresh summary takes their place.
  /// Silently no-ops when the lease has expired (a different caller may
  /// have already taken over).
  Future<void> completeCompression(
    CrossWindowCompressionWork work,
    String summaryText,
  ) {
    return _withLock(() async {
      final clean = summaryText.trim();
      if (clean.isEmpty) return;
      final state = await _readState();
      final lease = state.compressionLeases[work.assistantId];
      if (lease == null || lease.throughEntryId != work.throughEntryId) {
        return;
      }
      final kept = state.entries
          .where((e) => !(e.assistantId == work.assistantId &&
              e.id <= work.throughEntryId))
          .toList();
      final newSummaries = <String, CrossWindowSummary>{
        ...state.summaries,
        work.assistantId: CrossWindowSummary(
          text: clean,
          throughEntryId: work.throughEntryId,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      };
      final newLeases = <String, _CompressionLease>{
        ...state.compressionLeases
      }..remove(work.assistantId);
      await _writeState(_State(
        nextId: state.nextId,
        entries: kept,
        cursors: state.cursors,
        summaries: newSummaries,
        compressionLeases: newLeases,
      ));
    });
  }

  /// Drop the lease without writing a summary. Used when the LLM call
  /// failed or returned an empty string.
  Future<void> failCompression(CrossWindowCompressionWork work) {
    return _withLock(() async {
      final state = await _readState();
      final lease = state.compressionLeases[work.assistantId];
      if (lease?.throughEntryId != work.throughEntryId) return;
      final newLeases = <String, _CompressionLease>{
        ...state.compressionLeases
      }..remove(work.assistantId);
      await _writeState(_State(
        nextId: state.nextId,
        entries: state.entries,
        cursors: state.cursors,
        summaries: state.summaries,
        compressionLeases: newLeases,
      ));
    });
  }

  /// Wipe every cross-window signal for [assistantId] — entries, cursors,
  /// summary, and any in-flight compression lease. The shared-preferences
  /// blob is rewritten with the assistant's slice removed.
  Future<void> clearAssistant(String assistantId) {
    return _withLock(() async {
      final state = await _readState();
      final prefix = '$assistantId|';
      final newCursors = <String, int>{};
      state.cursors.forEach((k, v) {
        if (!k.startsWith(prefix)) newCursors[k] = v;
      });
      final newSummaries = <String, CrossWindowSummary>{};
      state.summaries.forEach((k, v) {
        if (k != assistantId) newSummaries[k] = v;
      });
      final newLeases = <String, _CompressionLease>{};
      state.compressionLeases.forEach((k, v) {
        if (k != assistantId) newLeases[k] = v;
      });
      await _writeState(_State(
        nextId: state.nextId,
        entries: state.entries
            .where((e) => e.assistantId != assistantId)
            .toList(),
        cursors: newCursors,
        summaries: newSummaries,
        compressionLeases: newLeases,
      ));
    });
  }
}
