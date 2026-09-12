/// Appends retrieved knowledge chunks to a message list (issue #389).
///
/// The block goes to the tail of the latest user message — the ADR-0006
/// cache-neutral volatile position, so per-turn retrieval never invalidates the
/// cached system-prompt prefix. Chunks are ephemeral and never persisted.
library;

import 'knowledge_store.dart';

class KnowledgePromptInjector {
  const KnowledgePromptInjector._();

  static const String _fallbackSource = 'document';

  /// Returns true when a block was appended. No-op for empty [hits] or a
  /// message list without a user turn.
  static bool inject({
    required List<Map<String, dynamic>> messages,
    required List<KnowledgeSearchHit> hits,
  }) {
    if (hits.isEmpty) return false;
    final index = messages.lastIndexWhere(
      (message) => (message['role'] ?? '').toString() == 'user',
    );
    if (index < 0) return false;

    final buffer = StringBuffer()
      ..writeln()
      ..writeln('<knowledge>');
    for (final hit in hits) {
      final source = hit.documentName.trim().isEmpty
          ? _fallbackSource
          : hit.documentName.trim();
      buffer
        ..writeln('<excerpt source="${_escapeAttribute(source)}">')
        ..writeln(hit.chunk.content.trim())
        ..writeln('</excerpt>');
    }
    buffer.write('</knowledge>');

    final existing = (messages[index]['content'] ?? '').toString();
    messages[index]['content'] = '$existing$buffer';
    return true;
  }

  static String _escapeAttribute(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('"', '&quot;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
