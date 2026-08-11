import 'package:flutter/painting.dart';

import '../../../core/models/chat_message.dart';

/// Q/A pairing of one user message with the assistant reply that follows it.
class MiniMapQaPair {
  const MiniMapQaPair({this.user, this.assistant});

  final ChatMessage? user;
  final ChatMessage? assistant;
}

/// Groups messages into user/assistant Q/A pairs for the mini map bird's-eye
/// view. An assistant message without a preceding user message becomes an
/// orphan on the assistant side; a trailing user message without an assistant
/// reply stays as a user-only pair.
List<MiniMapQaPair> buildMiniMapPairs(List<ChatMessage> messages) {
  final pairs = <MiniMapQaPair>[];
  ChatMessage? pendingUser;
  for (final m in messages) {
    if (m.role == 'user') {
      if (pendingUser != null) {
        pairs.add(MiniMapQaPair(user: pendingUser, assistant: null));
      }
      pendingUser = m;
    } else if (m.role == 'assistant') {
      if (pendingUser != null) {
        pairs.add(MiniMapQaPair(user: pendingUser, assistant: m));
        pendingUser = null;
      } else {
        pairs.add(MiniMapQaPair(user: null, assistant: m));
      }
    }
  }
  if (pendingUser != null) {
    pairs.add(MiniMapQaPair(user: pendingUser, assistant: null));
  }
  return pairs;
}

/// Flattens message content to a single line for mini map display bubbles.
/// Strips vendor inline reasoning/thought blocks, `[image:]` / `[file:]`
/// markers, collapses newlines and repeated whitespace. Unlike
/// [miniMapHitSnippet], stripped regions are removed entirely — this is the
/// DISPLAY text, while search matches against the raw content.
String miniMapOneLine(String s) {
  var t = s
      .replaceAll(
        RegExp(
          r'<(?:think|thought)>[\s\S]*?<\/(?:think|thought)>',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(
        RegExp(r'<reasoning>[\s\S]*?<\/reasoning>', caseSensitive: false),
        '',
      )
      .replaceAll(RegExp(r"\[image:[^\]]+\]"), "")
      .replaceAll(RegExp(r"\[file:[^\]]+\]"), "")
      .replaceAll('\n', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return t;
}

/// Splits a search query into whitespace-separated lowercase tokens,
/// mirroring the global search tokenizer.
List<String> miniMapSearchTokens(String query) {
  return query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
}

/// Message-level search: every token must hit the RAW content of the message
/// (AND semantics). Only user/assistant messages participate, consistent with
/// the Q/A pair view. Order follows the original message order.
List<ChatMessage> filterMiniMapMessages(
  List<ChatMessage> messages,
  List<String> tokens,
) {
  if (tokens.isEmpty) return const <ChatMessage>[];
  final out = <ChatMessage>[];
  for (final m in messages) {
    if (m.role != 'user' && m.role != 'assistant') continue;
    final lower = m.content.toLowerCase();
    var allHit = true;
    for (final t in tokens) {
      if (!lower.contains(t)) {
        allHit = false;
        break;
      }
    }
    if (allHit) out.add(m);
  }
  return out;
}

final RegExp _vendorBlockRe = RegExp(
  r'<(?:think|thought|reasoning)>[\s\S]*?<\/(?:think|thought|reasoning)>',
  caseSensitive: false,
);

/// `[image:...]` / `[file:...]` inline markers.
final RegExp _markerRe = RegExp(r'\[(?:image|file):[^\]]*\]');

/// Keeps the inner text of a matched block but removes the tag markup.
String _flattenBlock(Match m) {
  return m[0]!.replaceAll(RegExp(r'<\/?[^>]+>'), ' ');
}

/// Keeps the marker's inner text but removes `[image:` / `]` markup.
String _flattenMarker(Match m) {
  final raw = m[0]!;
  final colon = raw.indexOf(':');
  if (colon < 0) return ' ';
  return raw.substring(colon + 1, raw.length - 1);
}

/// Hit-centered snippet extracted from the RAW content with tag-flattening:
/// `<think>/<thought>/<reasoning>` and `[image:]`/`[file:]` markers keep their
/// inner text but lose their markup, so a hit inside a stripped region stays
/// visible and explainable. Markdown syntax symbols are left untouched.
String miniMapHitSnippet(
  String content,
  List<String> tokens, {
  int maxChars = 140,
}) {
  if (content.isEmpty || tokens.isEmpty) return '';

  final lower = content.toLowerCase();
  var hit = -1;
  for (final t in tokens) {
    final idx = lower.indexOf(t);
    if (idx >= 0 && (hit < 0 || idx < hit)) hit = idx;
  }

  var start = 0;
  var end = content.length;
  var hasBefore = false;
  var hasAfter = false;
  if (content.length > maxChars) {
    if (hit >= 0) {
      final anchor = (maxChars * 0.45).round();
      start = (hit - anchor).clamp(0, content.length - maxChars);
    }
    end = (start + maxChars).clamp(0, content.length);
    hasBefore = start > 0;
    hasAfter = end < content.length;
  }

  var frag = content.substring(start, end);
  frag = frag.replaceAllMapped(_vendorBlockRe, _flattenBlock);
  frag = frag.replaceAllMapped(_markerRe, _flattenMarker);
  // A window cut mid-block leaves a stray open/close tag that never matched
  // _vendorBlockRe; scrub bare vendor tags so snippets never show raw markup.
  frag = frag.replaceAll(
    RegExp(r'<\/?(?:think|thought|reasoning)>', caseSensitive: false),
    ' ',
  );
  // Likewise, a cut mid-marker leaves an unterminated `[image:`/`[file:`
  // prefix; drop the prefix (its inner text survives the window).
  frag = frag.replaceAll(RegExp(r'\[(?:image|file):'), ' ');
  frag = frag.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (hasBefore) frag = '... $frag';
  if (hasAfter) frag = '$frag ...';
  return frag;
}

/// Splits [text] into a span sequence where token occurrences receive the
/// [highlight] style and everything else the [base] style. Same algorithm as
/// the global search result highlighting.
List<TextSpan> buildMiniMapHighlightSpans(
  String text,
  List<String> tokens,
  TextStyle base,
  TextStyle highlight,
) {
  if (tokens.isEmpty || text.isEmpty) {
    return [TextSpan(text: text, style: base)];
  }
  final spans = <TextSpan>[];
  final lower = text.toLowerCase();
  int pos = 0;
  while (pos < text.length) {
    int earliest = -1;
    int earliestLen = 0;
    for (final t in tokens) {
      final idx = lower.indexOf(t, pos);
      if (idx >= 0 && (earliest < 0 || idx < earliest)) {
        earliest = idx;
        earliestLen = t.length;
      }
    }
    if (earliest < 0) {
      spans.add(TextSpan(text: text.substring(pos), style: base));
      break;
    }
    if (earliest > pos) {
      spans.add(TextSpan(text: text.substring(pos, earliest), style: base));
    }
    spans.add(
      TextSpan(
        text: text.substring(earliest, earliest + earliestLen),
        style: highlight,
      ),
    );
    pos = earliest + earliestLen;
  }
  return spans;
}
