part of '../chat_api_service.dart';

/// Placeholder thought signature accepted by the Gemini API when the original
/// signature is unavailable (e.g. legacy history persisted before signatures
/// were captured). Google once documented this value and its own Gemini CLI
/// still sends it; the current docs no longer list it, but the API keeps
/// accepting it.
const String _geminiDummyThoughtSignature =
    'context_engineering_is_the_way_to_go';

/// Wraps a bare payload (as produced by [encodeGeminiThoughtSignature]) in the
/// legacy transport comment that travels inside the streamed content until the
/// capture layer strips and normalizes it.
String _wrapGeminiThoughtSigComment(String payload) {
  if (payload.isEmpty) return '';
  return '\n<!-- $geminiThoughtSignatureTag:$payload -->';
}

// YouTube URL regex: watch, shorts, embed, youtu.be (with optional timestamps)
final RegExp _youtubeUrlRegex = RegExp(
  r'(https?://(?:www\.)?(?:youtube\.com/(?:watch\?v=|shorts/|embed/)|youtu\.be/)[a-zA-Z0-9_-]+(?:[?&][^\s<>()]*)?)',
  caseSensitive: false,
);

List<String> _extractYouTubeUrls(String text) {
  final out = <String>[];
  final seen = <String>{};
  for (final m in _youtubeUrlRegex.allMatches(text)) {
    var url = (m.group(1) ?? '').trim();
    if (url.isEmpty) continue;
    // Trim common trailing punctuation from markdown/parentheses
    while (url.isNotEmpty && '.,;:!?)"]}'.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    if (url.isEmpty) continue;
    if (seen.add(url)) out.add(url);
  }
  return out;
}

void _applyGeminiThoughtSignatures(
  GeminiSignatureMeta meta,
  List<Map<String, dynamic>> parts, {
  bool attachDummyWhenMissing = false,
}) {
  if (meta.hasAny) {
    if (meta.hasText) {
      for (final part in parts) {
        if (part.containsKey('text')) {
          part[meta.textKey!] = meta.textValue;
          break;
        }
      }
    }
    if (meta.hasImages) {
      int idx = 0;
      for (final part in parts) {
        if (idx >= meta.images.length) break;
        if (part.containsKey('inline_data') || part.containsKey('inlineData')) {
          final sig = meta.images[idx];
          final k = (sig['k'] ?? '').toString();
          final v = sig['v'];
          if (k.isNotEmpty && v != null) {
            part[k] = v;
          }
          idx++;
        }
      }
    }
  } else if (attachDummyWhenMissing) {
    const dummy = _geminiDummyThoughtSignature;
    bool inlineFound = false;
    bool textTagged = false;
    for (final part in parts) {
      final hasText = part.containsKey('text');
      final hasInline =
          part.containsKey('inline_data') || part.containsKey('inlineData');
      if (hasInline) {
        inlineFound = true;
        part.putIfAbsent('thoughtSignature', () => dummy);
      }
      if (hasText && hasInline && !textTagged) {
        part.putIfAbsent('thoughtSignature', () => dummy);
        textTagged = true;
      }
    }
    if (inlineFound && !textTagged) {
      for (final part in parts) {
        if (part.containsKey('text')) {
          part.putIfAbsent('thoughtSignature', () => dummy);
          break;
        }
      }
    }
  }
}

String collectGeminiThoughtSignatureFromParts(List<dynamic> parts) {
  String? textKey;
  dynamic textVal;
  final images = <Map<String, dynamic>>[];
  for (final p in parts) {
    if (p is! Map) continue;
    String? sigKey;
    dynamic sigVal;
    if (p.containsKey('thoughtSignature')) {
      sigKey = 'thoughtSignature';
      sigVal = p['thoughtSignature'];
    } else if (p.containsKey('thought_signature')) {
      sigKey = 'thought_signature';
      sigVal = p['thought_signature'];
    }
    final hasInline =
        p['inlineData'] is Map ||
        p['inline_data'] is Map ||
        p['fileData'] is Map ||
        p['file_data'] is Map;
    // Gemini 3 hangs the turn's signature on a trailing text part whose text
    // may be empty, so the text guard must not require a body. The first
    // signed text part is the turn's, as in the streaming decoder.
    final isText =
        !hasInline && p['thought'] != true && p['functionCall'] is! Map;
    if (isText && sigKey != null && sigVal != null && textKey == null) {
      textKey = sigKey;
      textVal = sigVal;
    }
    if (hasInline && sigKey != null && sigVal != null) {
      images.add({'k': sigKey, 'v': sigVal});
    }
  }
  return encodeGeminiThoughtSignature(
    textKey: textKey,
    textValue: textVal,
    imageSigs: images,
  );
}

Stream<ChatStreamChunk> _sendGoogleGeminiStream(
  http.Client client,
  ProviderConfig config,
  String modelId,
  List<Map<String, dynamic>> messages, {
  List<String>? userMediaPaths,
  int? thinkingBudget,
  double? temperature,
  double? topP,
  int? maxTokens,
  List<Map<String, dynamic>>? tools,
  ToolCallHandler? onToolCall,
  Map<String, String>? extraHeaders,
  Map<String, dynamic>? extraBody,
  bool stream = true,
}) {
  final cfg = config.copyWith(vertexAI: false);
  return _sendGoogleStream(
    client,
    cfg,
    modelId,
    messages,
    userMediaPaths: userMediaPaths,
    thinkingBudget: thinkingBudget,
    temperature: temperature,
    topP: topP,
    maxTokens: maxTokens,
    tools: tools,
    onToolCall: onToolCall,
    extraHeaders: extraHeaders,
    extraBody: extraBody,
    stream: stream,
  );
}
