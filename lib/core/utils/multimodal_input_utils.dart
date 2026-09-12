import '../models/chat_input_data.dart';

const String multimodalInternalMediaPathsKey = '_kelivo_media_paths';

/// Provider state stored against an assistant message and carried into the
/// next request under an internal key, which every provider strips before
/// anything reaches the wire.
const String multimodalInternalGeminiThoughtSignatureKey =
    '_kelivo_gemini_thought_signature';

bool isImageMime(String mime) => mime.toLowerCase().startsWith('image/');

bool isAudioMime(String mime) => mime.toLowerCase().startsWith('audio/');

bool isVideoMime(String mime) => mime.toLowerCase().startsWith('video/');

const _officeMimePrefixes = [
  'application/msword',
  'application/vnd.ms-powerpoint',
  'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument',
];

bool isOfficeDocumentMime(String mime) {
  final lower = mime.toLowerCase();
  return _officeMimePrefixes.any((p) => lower.startsWith(p));
}

bool isLongCatOmniModelId(String upstreamModelId) {
  final normalized = upstreamModelId.trim().toLowerCase();
  return normalized.startsWith('longcat-flash-omni') ||
      normalized.contains('/longcat-flash-omni');
}

String inferMediaMimeFromSource(String source, {String fallbackMime = ''}) {
  final lower = source.toLowerCase();
  if (lower.startsWith('data:')) {
    final start = lower.indexOf(':');
    final semi = lower.indexOf(';');
    if (start >= 0 && semi > start) {
      return lower.substring(start + 1, semi);
    }
  }
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
    return 'image/jpeg';
  }
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.bmp')) return 'image/bmp';
  if (lower.endsWith('.tif') || lower.endsWith('.tiff')) return 'image/tiff';
  if (lower.endsWith('.heic')) return 'image/heic';
  if (lower.endsWith('.heif')) return 'image/heif';
  if (lower.endsWith('.avif')) return 'image/avif';
  if (lower.endsWith('.wav')) return 'audio/wav';
  if (lower.endsWith('.mp3')) return 'audio/mpeg';
  if (lower.endsWith('.pcm16')) return 'audio/pcm16';
  if (lower.endsWith('.pcm')) return 'audio/pcm';
  if (lower.endsWith('.mp4')) return 'video/mp4';
  if (lower.endsWith('.mpeg') || lower.endsWith('.mpg')) return 'video/mpeg';
  if (lower.endsWith('.mov')) return 'video/quicktime';
  if (lower.endsWith('.avi')) return 'video/x-msvideo';
  if (lower.endsWith('.mkv')) return 'video/x-matroska';
  if (lower.endsWith('.flv')) return 'video/x-flv';
  if (lower.endsWith('.wmv')) return 'video/x-ms-wmv';
  if (lower.endsWith('.webm')) return 'video/webm';
  if (lower.endsWith('.3gp') || lower.endsWith('.3gpp')) return 'video/3gpp';
  // office documents
  if (lower.endsWith('.pdf')) return 'application/pdf';
  if (lower.endsWith('.doc')) return 'application/msword';
  if (lower.endsWith('.docx')) {
    return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
  }
  if (lower.endsWith('.ppt')) return 'application/vnd.ms-powerpoint';
  if (lower.endsWith('.pptx')) {
    return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
  }
  if (lower.endsWith('.xls')) return 'application/vnd.ms-excel';
  if (lower.endsWith('.xlsx')) {
    return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  }
  return fallbackMime;
}

/// Sniffs the leading bytes of a raster image and returns its MIME type, or
/// `null` when the signature is not recognized.
///
/// Used for IME-inserted content whose declared MIME is a wildcard
/// (`image/*`) or otherwise unknown.
String? sniffImageMimeFromBytes(List<int> bytes) {
  bool startsWith(List<int> signature, {int offset = 0}) {
    if (bytes.length < offset + signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[offset + i] != signature[i]) return false;
    }
    return true;
  }

  if (startsWith(const [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (startsWith(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (startsWith(const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (startsWith(const [0x42, 0x4D])) return 'image/bmp';
  // TIFF: little-endian II*\0 / big-endian MM\0*
  if (startsWith(const [0x49, 0x49, 0x2A, 0x00]) ||
      startsWith(const [0x4D, 0x4D, 0x00, 0x2A])) {
    return 'image/tiff';
  }
  // RIFF....WEBP
  if (startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
      startsWith(const [0x57, 0x45, 0x42, 0x50], offset: 8)) {
    return 'image/webp';
  }
  // ISO BMFF: ....ftyp<brand>
  if (startsWith(const [0x66, 0x74, 0x79, 0x70], offset: 4) &&
      bytes.length >= 12) {
    final brand = String.fromCharCodes(bytes.sublist(8, 12));
    return switch (brand) {
      'heic' || 'heix' || 'hevc' || 'hevx' => 'image/heic',
      'heif' || 'mif1' || 'msf1' => 'image/heif',
      'avif' || 'avis' => 'image/avif',
      _ => null,
    };
  }
  return null;
}

/// Returns the lowercase file extension (no dot) for an IME-inserted image.
///
/// The MIME subtype is trusted when known; the literal `image/*` wildcard and
/// unrecognized subtypes fall back to magic-byte sniffing, then to `png`.
String inferImageExtension(String mimeType, List<int> bytes) {
  final subtype = mimeType
      .toLowerCase()
      .split(';')
      .first
      .split('/')
      .last
      .trim();
  final known = switch (subtype) {
    'jpeg' || 'jpg' => 'jpg',
    'png' => 'png',
    'gif' => 'gif',
    'webp' => 'webp',
    'bmp' => 'bmp',
    'tiff' || 'tif' => 'tiff',
    'heic' => 'heic',
    'heif' => 'heif',
    'avif' => 'avif',
    _ => null,
  };
  if (known != null) return known;
  final sniffed = sniffImageMimeFromBytes(bytes);
  if (sniffed != null) return inferImageExtension(sniffed, const []);
  return 'png';
}

String resolveMediaAttachmentMime({
  required String explicitMime,
  required String fileName,
  required String path,
}) {
  final normalizedExplicit = explicitMime.trim().toLowerCase();
  if (isImageMime(normalizedExplicit) ||
      isAudioMime(normalizedExplicit) ||
      isVideoMime(normalizedExplicit) ||
      isOfficeDocumentMime(normalizedExplicit)) {
    return normalizedExplicit;
  }

  final byName = inferMediaMimeFromSource(fileName);
  if (byName.isNotEmpty) return byName;

  final byPath = inferMediaMimeFromSource(path);
  if (byPath.isNotEmpty) return byPath;

  return normalizedExplicit;
}

String resolveDocumentAttachmentMime(DocumentAttachment attachment) {
  return resolveMediaAttachmentMime(
    explicitMime: attachment.mime,
    fileName: attachment.fileName,
    path: attachment.path,
  );
}
