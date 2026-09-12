part of '../chat_api_service.dart';

/// The wire shape a provider expects when an image reference is encoded into a
/// request.
///
/// PR1 ships only the Gemini style; the Claude / Vertex-Claude styles land with
/// their marker-source migration (ADR-0064, PR2). OpenAI-family providers use
/// [_imageRefSourceUrl] directly because their part construction is bound to
/// their per-message de-dup; LongCat keeps its own attachment builder.
enum _ImageWireStyle {
  /// Google Gemini / Vertex generateContent: `{"inline_data":{...}}` — base64
  /// only; remote URLs degrade to a text reference because this path cannot
  /// fetch them.
  gemini,
}

/// Normalizes a media source for de-duplication: remote/data URLs pass through
/// unchanged, local paths are resolved through the sandbox.
String _normalizeMediaSource(String source) {
  if (source.startsWith('http') || source.startsWith('data:')) return source;
  try {
    return SandboxPathResolver.fix(source);
  } catch (_) {
    return source;
  }
}

/// Builds the plain-text content part for [style].
Map<String, dynamic> _imageStyleTextPart(_ImageWireStyle style, String text) {
  switch (style) {
    case _ImageWireStyle.gemini:
      return {'text': text};
  }
}

/// Resolves the URL/data-URL that OpenAI-family providers send for an image
/// ref: data URLs pass through, local files become `data:` URLs, remote URLs
/// pass through unchanged.
Future<String> _imageRefSourceUrl(_ImageRef ref) async {
  if (ref.kind == 'data') return ref.src;
  if (ref.kind == 'path') return _encodeBase64File(ref.src, withPrefix: true);
  return ref.src;
}

/// Encodes one parsed image reference into zero or more provider wire parts.
///
/// De-duplication is deliberately left to the caller: providers keep one
/// `seenSources` set across marker-derived refs and supplemental media,
/// preserving their existing order and de-dup semantics byte-for-byte.
Future<List<Map<String, dynamic>>> _encodeImageRefParts(
  _ImageRef ref, {
  required _ImageWireStyle style,
}) async {
  switch (style) {
    case _ImageWireStyle.gemini:
      if (ref.kind == 'data') {
        final idx = ref.src.indexOf('base64,');
        if (idx > 0) {
          return [
            {
              'inline_data': {
                'mime_type': _mimeFromDataUrl(ref.src),
                'data': ref.src.substring(idx + 7),
              },
            },
          ];
        }
        return [
          {'text': ref.src},
        ];
      }
      if (ref.kind == 'path') {
        return [
          {
            'inline_data': {
              'mime_type': _mimeFromPath(ref.src),
              'data': await _encodeBase64File(ref.src, withPrefix: false),
            },
          },
        ];
      }
      return [
        {'text': '(image) ${ref.src}'},
      ];
  }
}
