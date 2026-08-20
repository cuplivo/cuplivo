/// `Fixed memory` is the per-assistant block that the user marks as
/// `won't forget` (relationships, agreements, stable preferences). It is
/// embedded in [Assistant.systemPrompt] between two HTML-comment sentinels
/// so the regular character prompt and the rest of the system prompt stay
/// untouched.
///
/// The marker prefix is `CUPLIVO_FIXED_MEMORY_` (not the upstream
/// `TUMIN_FIXED_MEMORY_`) so it does not collide with other in-prompt
/// comments already used by Cuplivo (e.g. `<!-- tool ... -->`).
library;

const String _begin = '<!-- CUPLIVO_FIXED_MEMORY_BEGIN -->';
const String _end = '<!-- CUPLIVO_FIXED_MEMORY_END -->';

/// Pull the user-managed fixed memory out of [systemPrompt].
///
/// Returns the trimmed content between the begin/end sentinels, or an empty
/// string when the block is missing / malformed. The function tolerates a
/// block whose end sentinel precedes the begin (treated as missing) and an
/// empty body (treated as `''` rather than throwing).
String extractFixedMemory(String systemPrompt) {
  final start = systemPrompt.indexOf(_begin);
  final end = systemPrompt.indexOf(_end);
  if (start < 0 || end < 0 || end <= start) return '';
  return systemPrompt.substring(start + _begin.length, end).trim();
}

/// Insert (or replace) the fixed-memory block in [systemPrompt].
///
/// Pass an empty [memory] to strip the block. The rest of the prompt is
/// preserved verbatim; the function does not normalize surrounding
/// whitespace beyond removing the old block's trailing newline.
String withFixedMemory(String systemPrompt, String memory) {
  final clean = memory.trim();
  final start = systemPrompt.indexOf(_begin);
  final end = systemPrompt.indexOf(_end);
  final base = (start >= 0 && end > start)
      ? systemPrompt.replaceRange(start, end + _end.length, '').trimRight()
      : systemPrompt.trimRight();
  if (clean.isEmpty) return base;
  final block = StringBuffer()
    ..writeln(_begin)
    ..writeln('## Fixed memory')
    ..writeln(
      'Treat the following as stable user-approved memory. Keep it consistent unless the user explicitly changes it.',
    )
    ..writeln(clean)
    ..write(_end);
  return base.isEmpty ? block.toString() : '$base\n\n${block.toString()}';
}
