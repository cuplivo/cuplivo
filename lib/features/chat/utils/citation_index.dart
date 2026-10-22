import 'dart:convert';

/// One tool call's name and its raw answer, which is all this scan reads.
///
/// A record rather than a UI part: the scan belongs to the export and renderer
/// alike, and a projection type the timeline owns would make every consumer
/// import the widget layer to ask which search result a citation names.
typedef CitationToolResult = ({String name, String? content});

/// The search results a message's tool calls hold, newest first.
///
/// A citation is resolved against these: the renderer reads the parts the
/// timeline projected, and an export that lays the same message out reads its
/// own projection of the same events — both then ask the functions below, so the
/// number a capsule shows is decided once.
List<Map<String, dynamic>> searchCitationItemsOf(
  Iterable<CitationToolResult> parts,
) {
  final out = <Map<String, dynamic>>[];
  final seen = <String>{};

  // Back to front so "latest" wins when two calls returned the same result.
  final ordered = parts.toList(growable: false);
  for (int i = ordered.length - 1; i >= 0; i--) {
    final p = ordered[i];
    if ((p.name != 'search_web' && p.name != 'builtin_search') ||
        (p.content?.isNotEmpty ?? false) == false) {
      continue;
    }
    try {
      final obj = jsonDecode(p.content!) as Map<String, dynamic>;
      final arr = obj['items'] as List? ?? const <dynamic>[];
      for (final it in arr) {
        if (it is! Map) continue;
        final m = it.cast<String, dynamic>();
        final key = (m['id'] ?? m['url'] ?? '')
            .toString(); // builtin_search no id
        if (key.isNotEmpty) {
          if (!seen.add(key)) continue;
        }
        out.add(m);
      }
    } catch (_) {
      // A broken tool payload contributes nothing rather than failing a render.
    }
  }
  return out;
}

/// The number each search result is cited by.
///
/// Built once per message so each citation marker only performs a map lookup.
/// Insert ids first so an exact id match wins over a legacy numeric index.
Map<String, String> citationIndexLookupOf(List<Map<String, dynamic>> items) {
  final lookup = <String, String>{};
  for (final item in items) {
    final id = item['id']?.toString() ?? '';
    final index = item['index']?.toString() ?? '';
    if (id.isNotEmpty && index.isNotEmpty) lookup[id] ??= index;
  }
  for (final item in items) {
    final index = item['index']?.toString() ?? '';
    if (index.isNotEmpty) lookup[index] ??= index;
  }
  return lookup;
}

/// The number [id] is cited by, following the legacy `index:id` shape too: a
/// marker that named the result by position alone still resolves.
String? resolveCitationIndex(String id, Map<String, String> lookup) {
  final key = id.trim();
  if (key.isEmpty) return null;
  final direct = lookup[key];
  if (direct != null) return direct;
  final asIndex = int.tryParse(key);
  return asIndex == null ? null : lookup[asIndex.toString()];
}
