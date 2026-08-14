import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as image_lib;
import 'package:path/path.dart' as p;

import '../../../core/services/network/dio_http_client.dart';
import '../../../utils/sandbox_path_resolver.dart';
import 'web_transcript_models.dart';

class WebTranscriptResourceData {
  const WebTranscriptResourceData({
    required this.bytes,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String mimeType;
}

class WebTranscriptResourceException implements Exception {
  const WebTranscriptResourceException(this.code);

  final String code;

  @override
  String toString() => 'WebTranscriptResourceException($code)';
}

class WebTranscriptResourceProxy {
  WebTranscriptResourceProxy({http.Client? client})
    : _client =
          client ??
          DioHttpClient(
            addressResolver: _resolvePublicAddress,
            enableRequestLogging: false,
          );

  static const int maxResourceBytes = 8 * 1024 * 1024;
  static const int maxRedirects = 3;
  static const int maxImageDimension = 8192;
  static const int maxImagePixels = 40 * 1000 * 1000;
  static const Duration requestTimeout = Duration(seconds: 15);

  final http.Client _client;

  Future<WebTranscriptResourceData> load(WebTranscriptResource resource) async {
    if (resource.kind == WebTranscriptResourceKind.attachment) {
      throw const WebTranscriptResourceException('attachment_not_embeddable');
    }
    final uri = Uri.tryParse(resource.source);
    if (uri != null && uri.scheme.isNotEmpty) {
      if (uri.scheme != 'https') {
        throw const WebTranscriptResourceException('unsupported_scheme');
      }
      return _loadRemote(uri);
    }
    return _loadLocal(resource.source);
  }

  Future<WebTranscriptResourceData> _loadLocal(String rawPath) async {
    final normalized = resolveManagedLocalPath(rawPath);
    if (normalized == null) {
      throw const WebTranscriptResourceException('file_not_found');
    }
    final file = File(normalized);
    final length = await file.length();
    if (length > maxResourceBytes) {
      throw const WebTranscriptResourceException('resource_too_large');
    }
    final bytes = await file.readAsBytes();
    _validateImage(bytes);
    return WebTranscriptResourceData(
      bytes: bytes,
      mimeType: _mimeForPath(normalized),
    );
  }

  static String? resolveManagedLocalPath(String rawPath) {
    final fixed = SandboxPathResolver.fix(rawPath);
    final candidate = File(p.normalize(p.absolute(fixed)));
    if (!candidate.existsSync()) return null;
    String resolved;
    try {
      resolved = candidate.resolveSymbolicLinksSync();
    } on FileSystemException {
      return null;
    }
    for (final root in <String?>[
      SandboxPathResolver.docsDir,
      SandboxPathResolver.supportDir,
    ]) {
      if (root == null || root.isEmpty) continue;
      try {
        final normalizedRoot = Directory(
          p.normalize(p.absolute(root)),
        ).resolveSymbolicLinksSync();
        if (p.isWithin(normalizedRoot, resolved)) return resolved;
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  Future<WebTranscriptResourceData> _loadRemote(Uri initial) async {
    var current = initial;
    for (var redirect = 0; redirect <= maxRedirects; redirect++) {
      _validateRemoteUri(current);
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers['Accept'] =
            'image/avif,image/webp,image/png,image/jpeg,image/gif';
      final response = await _client.send(request).timeout(requestTimeout);
      if (response.isRedirect) {
        final location = response.headers['location'];
        if (location == null || redirect == maxRedirects) {
          throw const WebTranscriptResourceException('invalid_redirect');
        }
        await response.stream.drain<void>();
        current = current.resolve(location);
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw WebTranscriptResourceException('http_${response.statusCode}');
      }
      final declaredLength = response.contentLength;
      if (declaredLength != null && declaredLength > maxResourceBytes) {
        throw const WebTranscriptResourceException('resource_too_large');
      }
      final mime = (response.headers['content-type'] ?? '')
          .split(';')
          .first
          .trim()
          .toLowerCase();
      if (!_allowedImageMimeTypes.contains(mime)) {
        throw const WebTranscriptResourceException('unsupported_mime');
      }
      final builder = BytesBuilder(copy: false);
      var received = 0;
      await for (final chunk in response.stream.timeout(requestTimeout)) {
        received += chunk.length;
        if (received > maxResourceBytes) {
          throw const WebTranscriptResourceException('resource_too_large');
        }
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      _validateImage(bytes);
      return WebTranscriptResourceData(bytes: bytes, mimeType: mime);
    }
    throw const WebTranscriptResourceException('redirect_limit');
  }

  void _validateRemoteUri(Uri uri) {
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw const WebTranscriptResourceException('invalid_remote_uri');
    }
  }

  static Future<InternetAddress> _resolvePublicAddress(String host) async {
    final addresses = await InternetAddress.lookup(
      host,
    ).timeout(requestTimeout);
    if (addresses.isEmpty || addresses.any(_isPrivateAddress)) {
      throw const WebTranscriptResourceException('private_remote_host');
    }
    return addresses.first;
  }

  static bool _isPrivateAddress(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal) return true;
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      return bytes[0] == 10 ||
          bytes[0] == 127 ||
          (bytes[0] == 169 && bytes[1] == 254) ||
          (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
          (bytes[0] == 192 && bytes[1] == 168) ||
          bytes[0] == 0;
    }
    final isMappedIpv4 =
        bytes.length == 16 &&
        bytes.take(10).every((byte) => byte == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff;
    if (isMappedIpv4) {
      return _isPrivateAddress(
        InternetAddress.fromRawAddress(Uint8List.fromList(bytes.sublist(12))),
      );
    }
    return bytes.every((byte) => byte == 0) ||
        (bytes[0] & 0xfe) == 0xfc ||
        (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80);
  }

  String _mimeForPath(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.png':
        return 'image/png';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.avif':
        return 'image/avif';
      default:
        throw const WebTranscriptResourceException('unsupported_mime');
    }
  }

  void _validateImage(Uint8List bytes) {
    final decoder = image_lib.findDecoderForData(bytes);
    final info = decoder?.startDecode(bytes);
    if (info == null) {
      throw const WebTranscriptResourceException('invalid_image');
    }
    if (info.width <= 0 ||
        info.height <= 0 ||
        info.width > maxImageDimension ||
        info.height > maxImageDimension ||
        info.width * info.height > maxImagePixels) {
      throw const WebTranscriptResourceException('image_dimensions_too_large');
    }
  }

  void dispose() => _client.close();
}

const Set<String> _allowedImageMimeTypes = <String>{
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
  'image/avif',
};
