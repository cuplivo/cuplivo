/// Adapters that actually draw the picture.
///
/// Two wire shapes exist and neither is universal:
///
/// * `/images/generations` — the model *is* an image model
///   ([ModelType.image]). The reply carries the bytes inline (`b64_json`) or a
///   `url` to download.
/// * chat-completions — an ordinary chat model whose reply is prose with the
///   picture in it. Gemini's image models answer this way, and so do most
///   aggregators: the body holds a Markdown image link, possibly to a host.
///
/// Every parser here is a pure function, so both wire shapes are tested without
/// a network. The backends themselves are thin: build the request, hand the
/// decoded body to the parser, materialize the bytes.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../../../core/models/model_spec.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_helpers.dart';
import '../../../core/services/model_spec/model_spec_resolver.dart';
import '../../../core/services/api/stream/stream_chunk.dart'
    show mimeTypeFromImageUri;
import '../../../core/services/custom_request_merger.dart';
import '../../../utils/app_directories.dart';
import '../../../utils/sandbox_path_resolver.dart';

/// A picture the job carries into generation: "keep editing this one".
final class ImageReference {
  const ImageReference({required this.uri, this.mime});

  /// Local path, remote URL or `data:` URL — whatever the conversation holds.
  final String uri;
  final String? mime;

  bool get isRemote => uri.startsWith('http://') || uri.startsWith('https://');
  bool get isData => uri.startsWith('data:');
}

/// Everything a backend is allowed to know about one picture.
final class ImageGenerationRequest {
  const ImageGenerationRequest({
    required this.prompt,
    this.aspectRatio,
    this.references = const <ImageReference>[],
  });

  /// Everything the image model sees. There is no other channel.
  final String prompt;

  /// `auto`, `1:1`, `3:2`, `2:3` or `16:9`. `null` means the same as `auto`:
  /// the backend decides, which is the right answer most of the time.
  final String? aspectRatio;

  final List<ImageReference> references;

  bool get hasReferences => references.isNotEmpty;

  bool get wantsAutoRatio => aspectRatio == null || aspectRatio == 'auto';
}

/// The bytes, plus what they are.
final class ImageGenerationResult {
  const ImageGenerationResult({required this.bytes, required this.mime});

  final Uint8List bytes;
  final String mime;
}

/// Why a backend could not produce bytes.
enum ImageBackendFailure {
  /// A reply arrived, but it contained no picture.
  noImage,

  /// HTTP / transport / provider-level failure.
  providerError,

  /// Something arrived that cannot be turned into bytes.
  badPayload,
}

final class ImageBackendException implements Exception {
  const ImageBackendException(this.failure, this.message, {this.statusCode});

  final ImageBackendFailure failure;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'ImageBackendException(${failure.name}): $message';
}

/// Draws one picture. The only asynchronous edge in the job.
abstract interface class ImageBackend {
  Future<ImageGenerationResult> generate(ImageGenerationRequest request);
}

// ---------------------------------------------------------------------------
// Wire shapes (pure)
// ---------------------------------------------------------------------------

/// What one entry of an images-API `data` array turned out to be.
sealed class ImagePayload {
  const ImagePayload(this.mime);

  final String mime;
}

final class InlineImagePayload extends ImagePayload {
  const InlineImagePayload(this.base64, String mime) : super(mime);

  final String base64;
}

final class RemoteImagePayload extends ImagePayload {
  const RemoteImagePayload(this.url, String mime) : super(mime);

  final String url;
}

/// First usable picture in an `/images/generations` (or `/images/edits`) body.
///
/// Returns `null` for an empty `data` array, a malformed body, or entries that
/// carry neither field — all of which mean "no image" to the caller, never a
/// crash.
ImagePayload? parseImagesGenerationResponse(
  Object? decoded, {
  String fallbackMime = 'image/png',
}) {
  if (decoded is! Map) return null;
  final data = decoded['data'];
  if (data is! List) return null;
  for (final entry in data) {
    if (entry is! Map) continue;
    final b64 = (entry['b64_json'] ?? '').toString().trim();
    if (b64.isNotEmpty) {
      // Providers that echo their own mime win; PNG is the documented default.
      final declared = (entry['mime_type'] ?? entry['output_format'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      final mime = declared.isEmpty
          ? fallbackMime
          : _mimeFromFormat(declared) ?? fallbackMime;
      return InlineImagePayload(b64, mime);
    }
    final url = (entry['url'] ?? '').toString().trim();
    if (url.isNotEmpty) {
      return RemoteImagePayload(url, mimeTypeFromImageUri(url) ?? fallbackMime);
    }
  }
  return null;
}

/// The plain text of a chat-completions `message.content`.
///
/// Providers send either a string or a list of typed parts; only text parts
/// are prose, everything else is decoration we cannot read.
String chatReplyText(Object? content) {
  if (content is String) return content.trim();
  if (content is! List) return '';
  final buffer = StringBuffer();
  for (final part in content) {
    if (part is String) {
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(part);
      continue;
    }
    if (part is! Map) continue;
    final type = (part['type'] ?? '').toString();
    if (type.isNotEmpty && type != 'text' && type != 'output_text') continue;
    final text = (part['text'] ?? '').toString();
    if (text.isEmpty) continue;
    if (buffer.isNotEmpty) buffer.write('\n');
    buffer.write(text);
  }
  return buffer.toString().trim();
}

/// First Markdown image link in a chat reply.
///
/// This is the whole contract of a chat-shaped image model: the picture is a
/// link in the prose, so the prose is where we look. Returns `null` when there
/// is none — a text-only answer is `noImage`, never something to invent bytes
/// from.
String? firstMarkdownImageUrl(String? text) {
  if (text == null || text.isEmpty) return null;
  for (final match in _markdownImage.allMatches(text)) {
    var url = (match.group(1) ?? '').trim();
    if (url.isEmpty) continue;
    // `<https://…>` is valid Markdown for "this link, no title".
    if (url.startsWith('<') && url.endsWith('>')) {
      url = url.substring(1, url.length - 1).trim();
    }
    if (url.isEmpty) continue;
    return url;
  }
  return null;
}

/// The destination of an image link: everything up to whitespace or `)`.
///
/// Stopping at whitespace is what keeps a CommonMark title out of the URL —
/// `![](x.png "a title")` used to arrive as `x.png "a title"`, which asked for a
/// picture at a path that does not exist. The three title spellings (`"…"`,
/// `'…'`, `(…)`) all sit behind that space, so none of them needs parsing.
final RegExp _markdownImage = RegExp(r'!\[[^\]]*\]\(\s*(<[^>]*>|[^)\s]+)');

String? _mimeFromFormat(String format) {
  switch (format) {
    case 'png':
    case 'image/png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
    case 'image/jpeg':
      return 'image/jpeg';
    case 'webp':
    case 'image/webp':
      return 'image/webp';
    default:
      return null;
  }
}

// ---------------------------------------------------------------------------
// Shared plumbing
// ---------------------------------------------------------------------------

abstract class _HttpImageBackend implements ImageBackend {
  _HttpImageBackend({
    required this.baseUrl,
    required this.modelId,
    required this.headers,
    this.client,
    this.extraBody = const <String, dynamic>{},
  });

  final String baseUrl;
  final String modelId;

  /// Already merged: auth, provider auto headers, and the model's own rows.
  final Map<String, String> headers;

  /// The model's custom body rows; applied last so a user who pins `size` or
  /// `quality` in the provider config wins over our defaults.
  final Map<String, dynamic> extraBody;

  /// Injected by tests. `null` means "open one for this request and close it",
  /// which is the right lifetime for a single picture.
  final http.Client? client;

  Future<T> _withClient<T>(Future<T> Function(http.Client client) body) async {
    final injected = client;
    if (injected != null) return body(injected);
    final owned = http.Client();
    try {
      return await body(owned);
    } finally {
      owned.close();
    }
  }

  Uri endpoint(String path) {
    var base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return Uri.parse('$base$path');
  }

  Map<String, String> jsonHeaders() => {
    ...headers,
    'Content-Type': 'application/json',
  };

  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) {
    return _withClient((client) async {
      final response = await client.post(
        endpoint(path),
        headers: jsonHeaders(),
        body: jsonEncode(body),
      );
      return _decodeObject(response);
    });
  }

  /// Bytes of a remote picture, or of a `data:` URL (no request needed).
  Future<ImageGenerationResult> fetchImage(String url) async {
    final inline = decodeDataUrl(url);
    if (inline != null) return inline;
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw ImageBackendException(
        ImageBackendFailure.badPayload,
        'Not a fetchable image URL: $url',
      );
    }
    return _withClient((client) async {
      final response = await client.get(uri);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ImageBackendException(
          ImageBackendFailure.providerError,
          'Image download failed with HTTP ${response.statusCode}.',
          statusCode: response.statusCode,
        );
      }
      final bytes = response.bodyBytes;
      if (bytes.isEmpty) {
        throw const ImageBackendException(
          ImageBackendFailure.badPayload,
          'Image download returned no bytes.',
        );
      }
      final declared = response.headers['content-type']?.split(';').first;
      final mime =
          _mimeFromFormat((declared ?? '').trim().toLowerCase()) ??
          mimeTypeFromImageUri(url) ??
          'image/png';
      return ImageGenerationResult(bytes: bytes, mime: mime);
    });
  }

  Map<String, dynamic> _decodeObject(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ImageBackendException(
        ImageBackendFailure.providerError,
        _providerMessage(response),
        statusCode: response.statusCode,
      );
    }
    final decoded = _tryJson(response.body);
    if (decoded is! Map) {
      throw const ImageBackendException(
        ImageBackendFailure.badPayload,
        'Provider returned a non-object body.',
      );
    }
    return decoded.cast<String, dynamic>();
  }

  String _providerMessage(http.Response response) {
    final decoded = _tryJson(response.body);
    if (decoded is Map) {
      final error = decoded['error'];
      if (error is Map) {
        final message = (error['message'] ?? '').toString().trim();
        if (message.isNotEmpty) return message;
      }
      final message = (decoded['message'] ?? '').toString().trim();
      if (message.isNotEmpty) return message;
    }
    final body = response.body.trim();
    return body.isEmpty
        ? 'Provider returned HTTP ${response.statusCode}.'
        : 'HTTP ${response.statusCode}: ${body.length > 300 ? '${body.substring(0, 300)}…' : body}';
  }
}

Object? _tryJson(String body) {
  try {
    return jsonDecode(body);
  } catch (_) {
    return null;
  }
}

/// Turn a `data:` URL into bytes, or `null` when [value] is not one.
ImageGenerationResult? decodeDataUrl(String value) {
  if (!value.startsWith('data:')) return null;
  final comma = value.indexOf(',');
  if (comma <= 5) return null;
  final header = value.substring(5, comma);
  final isBase64 = header.toLowerCase().contains(';base64');
  final mime = header.split(';').first.trim();
  final payload = value.substring(comma + 1);
  try {
    final bytes = isBase64
        ? _decodeBase64(payload)
        : Uint8List.fromList(utf8.encode(Uri.decodeComponent(payload)));
    if (bytes.isEmpty) return null;
    return ImageGenerationResult(
      bytes: bytes,
      mime: mime.isEmpty ? 'image/png' : mime,
    );
  } catch (_) {
    return null;
  }
}

/// Both alphabets occur in the wild; a stray newline is not a failure.
Uint8List _decodeBase64(String value) {
  final cleaned = value.replaceAll(RegExp(r'\s'), '');
  if (cleaned.contains('-') || cleaned.contains('_')) {
    return base64Url.decode(cleaned);
  }
  return base64Decode(cleaned);
}

// ---------------------------------------------------------------------------
// Shape 1: /images/generations (+ /images/edits when there are references)
// ---------------------------------------------------------------------------

final class ImagesApiBackend extends _HttpImageBackend {
  ImagesApiBackend({
    required super.baseUrl,
    required super.modelId,
    required super.headers,
    this.supportsEdits = true,
    super.client,
    super.extraBody,
  });

  /// Whether this model takes input images at all. The rule is the app's own
  /// (`providers/openai_images.dart` `_supportsOpenAIImageEdits`: the spec's
  /// `input` contains `Modality.image`), passed in here instead of guessed from
  /// the model id — a text-to-image-only model (`dall-e-3`) answers `/images/edits`
  /// with a 400, and the honest outcome is our refusal, not the provider's error.
  final bool supportsEdits;

  @override
  Future<ImageGenerationResult> generate(ImageGenerationRequest request) async {
    if (request.hasReferences && !supportsEdits) {
      throw const ImageBackendException(
        ImageBackendFailure.badPayload,
        'This drawing model cannot take reference images; ask for the picture '
        'without them.',
      );
    }
    final body = request.hasReferences
        ? await _postEdits(request)
        : await _postGenerations(request);
    final payload = parseImagesGenerationResponse(body);
    if (payload == null) {
      throw const ImageBackendException(
        ImageBackendFailure.noImage,
        'The images API returned no image data.',
      );
    }
    return switch (payload) {
      InlineImagePayload(:final base64, :final mime) => ImageGenerationResult(
        bytes: _decodeBase64(base64),
        mime: mime,
      ),
      RemoteImagePayload(:final url) => await fetchImage(url),
    };
  }

  Map<String, dynamic> _baseBody(ImageGenerationRequest request) {
    // No `size`, deliberately: the accepted enum is per model (dall-e-3 refuses
    // `1536x1024`, gpt-image-1 accepts it), so a model-blind table here turned a
    // working picture into a 400 — and the app's own images client sends no size
    // either. The ratio still travels, in the only place both shapes understand:
    // the instruction (see `promptWithRatio`).
    final body = <String, dynamic>{
      'model': modelId,
      'prompt': promptWithRatio(request.prompt, request.aspectRatio),
    };
    CustomRequestMerger.applyBody(body, extraBody);
    return body;
  }

  Future<Map<String, dynamic>> _postGenerations(
    ImageGenerationRequest request,
  ) {
    return postJson('/images/generations', _baseBody(request));
  }

  Future<Map<String, dynamic>> _postEdits(ImageGenerationRequest request) {
    final form = http.MultipartRequest('POST', endpoint('/images/edits'));
    final headers = Map<String, String>.from(this.headers)
      ..removeWhere((key, _) => key.toLowerCase() == 'content-type');
    form.headers.addAll(headers);

    final fields = <String, String>{};
    final body = _baseBody(request);
    for (final entry in body.entries) {
      final value = entry.value;
      if (value == null) continue;
      fields[entry.key] = value is String ? value : jsonEncode(value);
    }
    form.fields.addAll(fields);

    return _withClient((client) async {
      var attached = 0;
      for (final reference in request.references) {
        final file = await _multipartFile(reference);
        if (file == null) continue;
        form.files.add(file);
        attached += 1;
      }
      if (attached == 0) {
        throw const ImageBackendException(
          ImageBackendFailure.badPayload,
          'No reference image could be read.',
        );
      }
      final streamed = await client.send(form);
      return _decodeObject(await http.Response.fromStream(streamed));
    });
  }

  Future<http.MultipartFile?> _multipartFile(ImageReference reference) async {
    try {
      final Uint8List bytes;
      final String mime;
      if (reference.isData) {
        final inline = decodeDataUrl(reference.uri);
        if (inline == null) return null;
        bytes = inline.bytes;
        mime = reference.mime ?? inline.mime;
      } else if (reference.isRemote) {
        final downloaded = await fetchImage(reference.uri);
        bytes = downloaded.bytes;
        mime = reference.mime ?? downloaded.mime;
      } else {
        final resolved = SandboxPathResolver.resolveForIo(reference.uri);
        if (resolved == null) return null;
        final file = File(resolved);
        if (!await file.exists()) return null;
        bytes = await file.readAsBytes();
        mime = reference.mime ?? mimeFromPath(resolved);
      }
      final normalized = mime.trim().toLowerCase();
      final mediaType =
          normalized == 'image/jpeg' ||
              normalized == 'image/png' ||
              normalized == 'image/webp'
          ? MediaType.parse(normalized)
          : MediaType('image', 'png');
      return http.MultipartFile.fromBytes(
        'image[]',
        bytes,
        filename: 'image.${AppDirectories.extFromMime(mediaType.mimeType)}',
        contentType: mediaType,
      );
    } catch (_) {
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Shape 2: chat-completions whose reply contains the picture
// ---------------------------------------------------------------------------

final class ChatImageBackend extends _HttpImageBackend {
  ChatImageBackend({
    required super.baseUrl,
    required super.modelId,
    required super.headers,
    super.client,
    super.extraBody,
  });

  @override
  Future<ImageGenerationResult> generate(ImageGenerationRequest request) async {
    final body = await _buildBody(request);
    final decoded = await postJson('/chat/completions', body);
    final text = chatReplyText(_choiceContent(decoded));
    final url = firstMarkdownImageUrl(text);
    if (url == null) {
      throw const ImageBackendException(
        ImageBackendFailure.noImage,
        'The reply contained no image link.',
      );
    }
    return fetchImage(url);
  }

  Object? _choiceContent(Map<String, dynamic> decoded) {
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final first = choices.first;
    if (first is! Map) return null;
    final message = first['message'];
    if (message is Map) return message['content'];
    // Some gateways put a non-streaming completion here instead.
    return first['text'];
  }

  Future<Map<String, dynamic>> _buildBody(
    ImageGenerationRequest request,
  ) async {
    final parts = <Map<String, dynamic>>[
      {'type': 'text', 'text': _promptFor(request)},
    ];
    for (final reference in request.references) {
      final dataUrl = await _asDataUrl(reference);
      if (dataUrl == null) continue;
      parts.add({
        'type': 'image_url',
        'image_url': {'url': dataUrl},
      });
    }
    final body = <String, dynamic>{
      'model': modelId,
      'messages': [
        {
          // One user turn: the instruction, then the pictures it refers to.
          'role': 'user',
          'content': parts.length == 1 ? parts.first['text'] : parts,
        },
      ],
      'stream': false,
    };
    CustomRequestMerger.applyBody(body, extraBody);
    return body;
  }

  /// The ratio has no request field on this shape, so it travels with the
  /// instruction. `auto` adds nothing: a chat model composes on its own.
  String _promptFor(ImageGenerationRequest request) =>
      promptWithRatio(request.prompt, request.aspectRatio);

  Future<String?> _asDataUrl(ImageReference reference) async {
    try {
      if (reference.isData) return reference.uri;
      final Uint8List bytes;
      final String mime;
      if (reference.isRemote) {
        final downloaded = await fetchImage(reference.uri);
        bytes = downloaded.bytes;
        mime = reference.mime ?? downloaded.mime;
      } else {
        final resolved = SandboxPathResolver.resolveForIo(reference.uri);
        if (resolved == null) return null;
        final file = File(resolved);
        if (!await file.exists()) return null;
        bytes = await file.readAsBytes();
        mime = reference.mime ?? mimeFromPath(resolved);
      }
      return 'data:$mime;base64,${base64Encode(bytes)}';
    } catch (_) {
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Which shape a configured model speaks
// ---------------------------------------------------------------------------

/// Whether [spec] can produce a picture, and may therefore be offered as a
/// drawing model.
///
/// Two kinds qualify: an image model (`type == image`, which speaks the images
/// API) and a chat model that declares image output (which answers with a link).
/// A text-only chat model is never offered — it would fail every call, and the
/// picker should not be a list of ways to fail.
bool modelCanDrawPicture(ModelSpec spec) =>
    spec.type == ModelType.image || spec.output.contains(Modality.image);

/// The ratio as a number, or `null` when nobody promised one.
///
/// One definition for the card's skeleton and the panel's size fallback: both
/// have to answer "how wide did we say this picture would be" before any bytes
/// exist, and `auto` genuinely has no answer — the model decides at generation
/// time, so the caller falls back to a neutral default and accepts one reflow
/// when the real picture arrives with different proportions.
double? aspectOfRatio(String? ratio) => switch (ratio) {
  '1:1' => 1,
  '3:2' => 3 / 2,
  '2:3' => 2 / 3,
  '16:9' => 16 / 9,
  _ => null,
};

/// The prompt a backend sends, with the requested ratio appended when there is
/// one.
///
/// Neither wire shape has a portable ratio field (a per-model `size` table is
/// what produced a 400 on dall-e-3), so the instruction is the only place both
/// understand. It is a soft constraint: a model that only honours its own sizes
/// will ignore it, which is why the skeleton reserves what was asked for and the
/// card reflows once if the picture comes back differently proportioned.
String promptWithRatio(String prompt, String? aspectRatio) {
  if (aspectRatio == null || aspectRatio == 'auto') return prompt;
  return '$prompt\n\nAspect ratio: $aspectRatio.';
}

/// Build the backend for one configured `provider + model`.
///
/// The shape follows the model's own declaration: an image model
/// ([ModelType.image]) speaks the images API; anything else is a chat model and
/// is expected to answer with a Markdown image link. That keeps a misconfigured
/// chat model on a path that reports `no_image` instead of a 404.
ImageBackend imageBackendFor(
  ProviderConfig config,
  String modelId, {
  http.Client? client,
  ModelType? modelType,
}) {
  final type = modelType ?? _modelType(config, modelId);
  final headers = customHeaders(
    config,
    modelId,
    baseHeaders: {
      'Authorization': 'Bearer ${apiKeyForRequest(config, modelId)}',
    },
  );
  final extraBody = modelExtraBody(config, modelId);
  final upstreamId = apiModelId(config, modelId);
  if (type == ModelType.image) {
    return ImagesApiBackend(
      baseUrl: config.baseUrl,
      modelId: upstreamId,
      headers: headers,
      // Same rule as the app's images client: a model takes reference images
      // only when its spec declares image *input*.
      supportsEdits: _supportsEdits(config, modelId),
      client: client,
      extraBody: extraBody,
    );
  }
  return ChatImageBackend(
    baseUrl: config.baseUrl,
    modelId: upstreamId,
    headers: headers,
    client: client,
    extraBody: extraBody,
  );
}

/// The provider's own custom body rows for [modelId].
///
/// Kept as a function so a caller that wants to inspect the request (tests, the
/// panel's "what did I send") can get it without building a backend.
Map<String, dynamic> modelExtraBody(ProviderConfig config, String modelId) {
  return customBody(config, modelId);
}

ModelType _modelType(ProviderConfig config, String modelId) {
  try {
    return ModelSpecResolver.instance.spec(config, modelId).type;
  } catch (_) {
    return ModelType.chat;
  }
}

/// Whether [modelId] accepts input images (so `/images/edits` is meaningful).
///
/// Mirrors `_supportsOpenAIImageEdits` in `providers/openai_images.dart`, which is
/// the app's own copy of this decision; that one guards the chat-side image path,
/// this one guards a job. Unknown models answer `false`: refusing to send an edit
/// the provider would reject is better than a 400 the user cannot act on.
bool _supportsEdits(ProviderConfig config, String modelId) {
  try {
    return ModelSpecResolver.instance
        .spec(config, modelId)
        .input
        .contains(Modality.image);
  } catch (_) {
    return false;
  }
}
