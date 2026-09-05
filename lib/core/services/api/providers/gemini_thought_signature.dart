import 'dart:convert';

/// Legacy tag used by comment-based Gemini thought signature storage
/// (messages saved before the payload format existed); still decoded for old
/// data.
const String geminiThoughtSignatureTag = 'gemini_thought_signatures';

final RegExp _geminiThoughtSigComment = RegExp(
  r'<!--\s*gemini_thought_signatures:(.*?)-->',
  dotAll: true,
);

/// Parsed Gemini thought signatures of one model turn.
class GeminiSignatureMeta {
  final String cleanedText;
  final String? textKey;
  final dynamic textValue;
  final List<Map<String, dynamic>> images;

  const GeminiSignatureMeta({
    required this.cleanedText,
    this.textKey,
    this.textValue,
    this.images = const <Map<String, dynamic>>[],
  });

  bool get hasText => (textKey ?? '').isNotEmpty && textValue != null;
  bool get hasImages => images.isNotEmpty;
  bool get hasAny => hasText || hasImages;
}

/// Encodes a turn's thought signatures as the artifact payload: a bare JSON
/// object `{"text": {"k", "v"}, "images": [{"k", "v"}]}`. Returns '' when
/// there is nothing to keep.
///
/// Payloads written before the payload format existed wrapped the same JSON in
/// an HTML comment that travelled inside the message text;
/// [decodeGeminiThoughtSignature] still reads those.
String encodeGeminiThoughtSignature({
  String? textKey,
  dynamic textValue,
  List<Map<String, dynamic>> imageSigs = const <Map<String, dynamic>>[],
}) {
  final imgs = imageSigs
      .where((e) => (e['k'] ?? '').toString().isNotEmpty && e.containsKey('v'))
      .toList();
  final hasText = (textKey ?? '').isNotEmpty && textValue != null;
  if (!hasText && imgs.isEmpty) return '';
  final payload = <String, dynamic>{};
  if (hasText) payload['text'] = {'k': textKey, 'v': textValue};
  if (imgs.isNotEmpty) payload['images'] = imgs;
  return jsonEncode(payload);
}

/// Decodes an artifact payload written by [encodeGeminiThoughtSignature] or by
/// the legacy comment format, paired with [cleanedText]. Null when [payload]
/// holds no signature.
GeminiSignatureMeta? decodeGeminiThoughtSignature(
  Object? payload, {
  String cleanedText = '',
}) {
  if (payload is! String) return null;
  final trimmed = payload.trim();
  if (trimmed.isEmpty) return null;
  String json = trimmed;
  if (!trimmed.startsWith('{')) {
    final legacy = _geminiThoughtSigComment.firstMatch(trimmed);
    if (legacy == null) return null;
    json = (legacy.group(1) ?? '').trim();
  }
  final meta = _geminiMetaFromJson(json, cleanedText: cleanedText);
  return meta.hasAny ? meta : null;
}

/// Splits a legacy message text that still carries the signature comment into
/// the clean text and the signatures.
GeminiSignatureMeta extractGeminiThoughtMeta(String raw) {
  final m = _geminiThoughtSigComment.firstMatch(raw);
  if (m == null) return GeminiSignatureMeta(cleanedText: raw);
  final cleaned = raw.replaceRange(m.start, m.end, '').trimRight();
  return _geminiMetaFromJson((m.group(1) ?? '').trim(), cleanedText: cleaned);
}

GeminiSignatureMeta _geminiMetaFromJson(
  String json, {
  required String cleanedText,
}) {
  Map<String, dynamic> data = const <String, dynamic>{};
  try {
    data = (jsonDecode(json) as Map).cast<String, dynamic>();
  } catch (_) {
    return GeminiSignatureMeta(cleanedText: cleanedText);
  }
  String? textKey;
  dynamic textVal;
  final text = data['text'];
  if (text is Map) {
    textKey = (text['k'] ?? text['key'])?.toString();
    textVal = text['v'] ?? text['val'];
    if (textKey != null && textKey.trim().isEmpty) {
      textKey = null;
    }
  }
  final images = <Map<String, dynamic>>[];
  final imgList = data['images'];
  if (imgList is List) {
    for (final e in imgList) {
      if (e is! Map) continue;
      final k = (e['k'] ?? e['key'])?.toString() ?? '';
      final v = e['v'] ?? e['val'];
      if (k.isEmpty || v == null) continue;
      images.add({'k': k, 'v': v});
    }
  }
  return GeminiSignatureMeta(
    cleanedText: cleanedText,
    textKey: textKey,
    textValue: textVal,
    images: images,
  );
}
