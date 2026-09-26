import 'dart:io';

import 'package:downsize/downsize.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'upload_dedupe.dart';

class ImageCompressConfig {
  const ImageCompressConfig({
    required this.enabled,
    required this.quality,
    required this.maxLongEdge,
    required this.includeTransparent,
  });

  final bool enabled;
  final int quality;
  final int maxLongEdge;
  final bool includeTransparent;
}

/// Parameters of one explicit, user-chosen compression in the manual editor.
///
/// A null [format] means 原图 (as-is): the stored bytes pass through
/// untouched. Unlike the automatic pipeline there are no skip guards — no
/// minimum size, no alpha gate, and the result may be larger than the input
/// (a PNG of a JPEG photo legitimately grows); the editor shows the estimated
/// size before anything is applied.
class ManualCompressParams {
  const ManualCompressParams({
    this.format,
    this.quality = 80,
    this.maxLongEdge,
  });

  final DownsizeFormat? format;
  final int quality;
  final int? maxLongEdge;

  bool get isNoOp => format == null;

  @override
  bool operator ==(Object other) =>
      other is ManualCompressParams &&
      other.format == format &&
      other.quality == quality &&
      other.maxLongEdge == maxLongEdge;

  @override
  int get hashCode => Object.hash(format, quality, maxLongEdge);
}

class ImageCompressor {
  static const int kMinBytesToCompress = 64 * 1024;

  /// Compresses [srcPath] into [dir] with the automatic pipeline.
  ///
  /// Images that are skipped, fail to decode, or would grow are copied
  /// unchanged; an image whose bytes are already stored in [dir] is reused.
  /// Returns `null` only when the source cannot be persisted.
  static Future<UploadWrite?> compressToUploadDir(
    String srcPath,
    Directory dir,
    ImageCompressConfig config,
  ) async {
    Uint8List? originalBytes;
    try {
      originalBytes = await File(srcPath).readAsBytes();
      final compressed = await compressBytes(originalBytes, config);
      return await _writeToUploadDir(
        srcPath,
        dir,
        compressed ?? originalBytes,
        outputExtension: compressed != null ? 'jpeg' : null,
      );
    } catch (error, stackTrace) {
      debugPrint('[ImageCompressor] Failed to compress $srcPath: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (originalBytes != null) {
        try {
          return await _writeToUploadDir(srcPath, dir, originalBytes);
        } catch (copyError) {
          debugPrint(
            '[ImageCompressor] Failed to copy original $srcPath: $copyError',
          );
        }
      }
      return null;
    }
  }

  /// Applies exactly [params] to [srcPath] — the manual pipeline.
  ///
  /// No skip guards and no alpha gate: the user saw the image and picked the
  /// format. Failure to decode falls back to storing the original unchanged,
  /// mirroring the automatic path.
  static Future<UploadWrite?> compressManualToUploadDir(
    String srcPath,
    Directory dir,
    ManualCompressParams params,
  ) async {
    Uint8List? originalBytes;
    try {
      originalBytes = await File(srcPath).readAsBytes();
      final encoded = params.isNoOp
          ? null
          : await compute(
              _manualEncodeTask,
              _ManualEncodeParams(
                bytes: originalBytes,
                format: params.format!,
                quality: params.quality,
                maxLongEdge: params.maxLongEdge,
              ),
            );
      return await _writeToUploadDir(
        srcPath,
        dir,
        encoded ?? originalBytes,
        outputExtension: switch (params.format) {
          DownsizeFormat.png => 'png',
          DownsizeFormat.jpeg => 'jpeg',
          null => null,
        },
      );
    } catch (error, stackTrace) {
      debugPrint(
        '[ImageCompressor] Manual compression failed for $srcPath: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
      if (originalBytes != null) {
        try {
          return await _writeToUploadDir(srcPath, dir, originalBytes);
        } catch (copyError) {
          debugPrint(
            '[ImageCompressor] Failed to copy original $srcPath: $copyError',
          );
        }
      }
      return null;
    }
  }

  /// Returns a smaller JPEG, or `null` when compression should be skipped.
  static Future<Uint8List?> compressBytes(
    Uint8List bytes,
    ImageCompressConfig config,
  ) async {
    if (!config.enabled || bytes.lengthInBytes < kMinBytesToCompress) {
      return null;
    }

    try {
      return await compute(
        _compressTask,
        _CompressTaskParams(
          bytes: bytes,
          quality: config.quality,
          maxLongEdge: config.maxLongEdge,
          includeTransparent: config.includeTransparent,
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('[ImageCompressor] Compression failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }

  /// Runs the manual encode pipeline on raw bytes without touching the
  /// upload directory. Returns `null` for a no-op ([ManualCompressParams.isNoOp]).
  static Future<Uint8List?> encodeManualBytes(
    Uint8List bytes,
    ManualCompressParams params,
  ) async {
    if (params.isNoOp) return null;
    return compute(
      _manualEncodeTask,
      _ManualEncodeParams(
        bytes: bytes,
        format: params.format!,
        quality: params.quality,
        maxLongEdge: params.maxLongEdge,
      ),
    );
  }

  static Future<UploadWrite> _writeToUploadDir(
    String srcPath,
    Directory dir,
    Uint8List bytes, {
    String? outputExtension,
  }) async {
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final originalName = p.basename(srcPath);
    final baseName = p.basenameWithoutExtension(originalName);
    final outputName = outputExtension != null
        ? '${baseName.isEmpty ? 'image' : baseName}.$outputExtension'
        : (originalName.isEmpty ? 'image' : originalName);

    // Reuse an already stored image with the same name and bytes instead of
    // piling up copies; this also covers re-importing a file from [dir].
    final existing = await UploadDedupe.findIdentical(dir, bytes, outputName);
    if (existing != null) return UploadWrite(existing, reused: true);

    final reserved = await UploadDedupe.reserveUniqueFile(dir, outputName);
    try {
      await reserved.writeAsBytes(bytes, flush: true);
      return UploadWrite(reserved.path, reused: false);
    } catch (_) {
      try {
        await reserved.delete();
      } catch (_) {}
      rethrow;
    }
  }
}

enum _DetectedImageFormat { jpeg, png, gif, other }

class _CompressTaskParams {
  const _CompressTaskParams({
    required this.bytes,
    required this.quality,
    required this.maxLongEdge,
    required this.includeTransparent,
  });

  final Uint8List bytes;
  final int quality;
  final int maxLongEdge;
  final bool includeTransparent;
}

Uint8List? _compressTask(_CompressTaskParams params) {
  final format = _detectFormat(params.bytes);

  switch (format) {
    case _DetectedImageFormat.jpeg:
      break;
    case _DetectedImageFormat.png:
      if (!params.includeTransparent && _pngNeedsOptIn(params.bytes)) {
        return null;
      }
      break;
    case _DetectedImageFormat.gif:
    case _DetectedImageFormat.other:
      if (!params.includeTransparent) {
        return null;
      }
      break;
  }

  final compressed = Downsize().compress(
    Config(
      data: params.bytes,
      quality: params.quality,
      maxLongEdge: params.maxLongEdge,
    ),
  );
  if (compressed == null ||
      compressed.lengthInBytes >= params.bytes.lengthInBytes) {
    return null;
  }
  return compressed;
}

class _ManualEncodeParams {
  const _ManualEncodeParams({
    required this.bytes,
    required this.format,
    required this.quality,
    required this.maxLongEdge,
  });

  final Uint8List bytes;
  final DownsizeFormat format;
  final int quality;
  final int? maxLongEdge;
}

Uint8List? _manualEncodeTask(_ManualEncodeParams params) {
  return Downsize().compress(
    Config(
      data: params.bytes,
      format: params.format,
      quality: params.quality,
      maxLongEdge: params.maxLongEdge,
    ),
  );
}

_DetectedImageFormat _detectFormat(Uint8List bytes) {
  if (bytes.lengthInBytes >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return _DetectedImageFormat.jpeg;
  }
  if (bytes.lengthInBytes >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0d &&
      bytes[5] == 0x0a &&
      bytes[6] == 0x1a &&
      bytes[7] == 0x0a) {
    return _DetectedImageFormat.png;
  }
  if (bytes.lengthInBytes >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38 &&
      (bytes[4] == 0x37 || bytes[4] == 0x39) &&
      bytes[5] == 0x61) {
    return _DetectedImageFormat.gif;
  }
  return _DetectedImageFormat.other;
}

bool _pngNeedsOptIn(Uint8List bytes) {
  const ihdrChunkEnd = 33;
  if (bytes.lengthInBytes < ihdrChunkEnd ||
      _readUint32(bytes, 8) != 13 ||
      !_isChunkType(bytes, 12, 0x49, 0x48, 0x44, 0x52)) {
    return false;
  }

  // This is intentionally conservative: color types 4/6 and tRNS mean the
  // image can contain transparency. An all-opaque alpha channel is therefore
  // skipped too; proving otherwise would require the full pixel scan avoided
  // here.
  final colorType = bytes[25];
  if (colorType == 4 || colorType == 6) return true;

  var offset = ihdrChunkEnd;
  while (offset + 12 <= bytes.lengthInBytes) {
    final dataLength = _readUint32(bytes, offset);
    if (dataLength > bytes.lengthInBytes - offset - 12) return false;

    final typeOffset = offset + 4;
    if (_isChunkType(bytes, typeOffset, 0x74, 0x52, 0x4e, 0x53) ||
        _isChunkType(bytes, typeOffset, 0x61, 0x63, 0x54, 0x4c)) {
      return true;
    }
    if (_isChunkType(bytes, typeOffset, 0x49, 0x44, 0x41, 0x54) ||
        _isChunkType(bytes, typeOffset, 0x49, 0x45, 0x4e, 0x44)) {
      return false;
    }
    offset += dataLength + 12;
  }
  return false;
}

int _readUint32(Uint8List bytes, int offset) {
  return bytes[offset] << 24 |
      bytes[offset + 1] << 16 |
      bytes[offset + 2] << 8 |
      bytes[offset + 3];
}

bool _isChunkType(Uint8List bytes, int offset, int a, int b, int c, int d) {
  return bytes[offset] == a &&
      bytes[offset + 1] == b &&
      bytes[offset + 2] == c &&
      bytes[offset + 3] == d;
}
