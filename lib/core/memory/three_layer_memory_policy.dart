/// Coordinates the three memory layers — fixed memory (system prompt),
/// cross-window recent life (SharedPreferences), and long-term memories
/// (per-assistant list, ranked by relevance) — without introducing a new
/// persistence format on top of [MemoryStore] / [CrossWindowMemoryStore].
///
/// `selectLongTermMemories` is a pure, allocation-light bag-of-words ranker
/// (latin tokens + CJK 2-gram windows) used to pick the N most relevant
/// memories to inject for a given query. `shouldInjectRecentChats` decides
/// whether the chat pipeline should fall back to recent chats as a stand-in
/// for cross-window context.
library;

import 'dart:math' as math;

import '../models/assistant.dart';
import '../models/assistant_memory.dart';

class ThreeLayerMemoryPolicy {
  const ThreeLayerMemoryPolicy._();

  /// Rank [memories] for the given [query] and pick at most [limit] entries
  /// that fit within [maxChars] characters total. Returns an empty list when
  /// inputs are degenerate (blank query, empty memory list, non-positive
  /// budget).
  static List<AssistantMemory> selectLongTermMemories({
    required List<AssistantMemory> memories,
    required String query,
    required int limit,
    required int maxChars,
  }) {
    if (query.trim().isEmpty ||
        memories.isEmpty ||
        limit <= 0 ||
        maxChars <= 0) {
      return const <AssistantMemory>[];
    }
    final queryTerms = _terms(query);
    if (queryTerms.isEmpty) return const <AssistantMemory>[];

    final queryLower = query.toLowerCase();
    final ranked = <(AssistantMemory, int)>[];
    for (final mem in memories) {
      final content = mem.content.trim();
      if (content.isEmpty) continue;
      final contentTerms = _terms(content);
      var overlap = 0;
      for (final t in queryTerms) {
        if (contentTerms.contains(t)) overlap++;
      }
      final phraseBonus =
          content.toLowerCase().contains(queryLower.trim()) ? 4 : 0;
      final score = overlap + phraseBonus;
      if (score > 0) ranked.add((mem, score));
    }
    ranked.sort((a, b) {
      final byScore = b.$2.compareTo(a.$2);
      if (byScore != 0) return byScore;
      // Tie-breaker: newer id first so the same match doesn't churn.
      return b.$1.id.compareTo(a.$1.id);
    });

    final selected = <AssistantMemory>[];
    var chars = 0;
    for (final (mem, _) in ranked) {
      if (selected.length >= limit) break;
      final nextChars = mem.content.length;
      if (selected.isNotEmpty && chars + nextChars > maxChars) break;
      if (selected.isEmpty && nextChars > maxChars) {
        // Single oversized memory: take a truncated slice so the user at
        // least sees something instead of dropping the only candidate.
        selected.add(
          AssistantMemory(
            id: mem.id,
            assistantId: mem.assistantId,
            content: mem.content.substring(
              0,
              math.min(maxChars, mem.content.length),
            ),
          ),
        );
        break;
      }
      selected.add(mem);
      chars += nextChars;
    }
    return selected;
  }

  /// Mirror of the Tumin decision table:
  /// - No `enableRecentChatsReference` → never inject.
  /// - 3-layer off → inject (compatibility path: 3-layer is the new master
  ///   switch; if it's off, fall back to legacy recent-chats behavior).
  /// - 3-layer on → only when fallback is on AND cross-window is off.
  static bool shouldInjectRecentChats(Assistant assistant) {
    if (!assistant.enableRecentChatsReference) return false;
    if (!assistant.enableThreeLayerMemory) return true;
    return assistant.useRecentChatsAsFallback &&
        !assistant.enableCrossWindowMemory;
  }

  /// Tokenize [text] into a set of normalized terms. Latin / digit / underscore
  /// runs of length ≥ 2 are kept whole; CJK characters are emitted as
  /// sliding 2-character windows (bigrams) so a query like `用户偏好` can
  /// match `记录用户偏好`. Punctuation is dropped.
  static Set<String> _terms(String text) {
    final normalized = text.toLowerCase();
    final tokens = <String>{};
    final latinRe = RegExp(r'[\p{L}\p{N}_]{2,}', unicode: true);
    for (final m in latinRe.allMatches(normalized)) {
      final tok = m.group(0)!;
      // Drop tokens that are entirely CJK — we already emit them as bigrams.
      if (!_isCjkOnly(tok)) tokens.add(tok);
    }
    final cjk = StringBuffer();
    for (final r in normalized.runes) {
      final ch = String.fromCharCode(r);
      if (_isCjk(ch)) {
        cjk.write(ch);
      } else {
        cjk.write(' ');
      }
    }
    final cjkStr = cjk.toString();
    if (cjkStr.replaceAll(' ', '').length >= 2) {
      final parts = cjkStr.split(' ').where((s) => s.isNotEmpty);
      for (final part in parts) {
        if (part.length < 2) continue;
        for (var i = 0; i + 2 <= part.length; i++) {
          tokens.add(part.substring(i, i + 2));
        }
      }
    }
    return tokens;
  }

  static bool _isCjk(String ch) {
    final code = ch.codeUnitAt(0);
    return code >= 0x4E00 && code <= 0x9FFF;
  }

  static bool _isCjkOnly(String s) {
    for (final r in s.runes) {
      if (!_isCjk(String.fromCharCode(r))) return false;
    }
    return true;
  }
}
