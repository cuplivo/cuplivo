/// The visible content and serialized Gemini thought signature extracted from
/// an assistant response.
class GeminiThoughtSignatureExtraction {
  const GeminiThoughtSignatureExtraction({
    required this.content,
    this.signature,
  });

  final String content;
  final String? signature;
}

final RegExp _geminiThoughtSignatureComment = RegExp(
  r'<!--\s*gemini_thought_signatures:.*?-->',
  dotAll: true,
);

/// Removes Gemini's internal thought-signature comments from [content].
///
/// The complete last comment is returned unchanged because that is the format
/// persisted and replayed by the chat pipeline.
GeminiThoughtSignatureExtraction extractGeminiThoughtSignature(String content) {
  if (content.isEmpty) {
    return const GeminiThoughtSignatureExtraction(content: '');
  }
  final matches = _geminiThoughtSignatureComment.allMatches(content).toList();
  if (matches.isEmpty) {
    return GeminiThoughtSignatureExtraction(content: content);
  }
  final signature = matches.last.group(0);
  return GeminiThoughtSignatureExtraction(
    content: content.replaceAll(_geminiThoughtSignatureComment, '').trimRight(),
    signature: signature == null || signature.isEmpty ? null : signature,
  );
}

/// Reattaches a persisted Gemini thought signature for an API history turn.
String appendGeminiThoughtSignature(String content, String? signature) {
  if (signature == null ||
      signature.isEmpty ||
      content.contains('gemini_thought_signatures:')) {
    return content;
  }
  if (content.isEmpty) return signature;
  return '$content\n$signature';
}
