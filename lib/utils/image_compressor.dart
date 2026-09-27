import 'dart:io';

import 'package:downsize/downsize.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'manual_compress_pipeline.dart';
import 'upload_dedupe.dart';

// The manual path's vocabulary lives with its decoder; this library stays the
// compression facade callers already import.
export 'manual_compress_pipeline.dart'
    show ManualCompressParams, ImageSourceFormat, detectImageSourceFormat;

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
  /// format. The pixels come from the shared working-image decode, so this
  /// never materialises the source at full resolution. Failure to decode falls
  /// back to storing the original unchanged, mirroring the automatic path.
  static Future<UploadWrite?> compressManualToUploadDir(
    String srcPath,
    Directory dir,
    ManualCompressParams params, {
    bool? desktop,
  }) async {
    Uint8List? originalBytes;
    try {
      if (params.isNoOp) {
        originalBytes = await File(srcPath).readAsBytes();
        return await _writeToUploadDir(srcPath, dir, originalBytes);
      }
      final isDesktop = desktop ?? isDesktopPlatform;
      final working = await decodeWorkingImage(
        srcPath,
        params: params,
        budgetPixels: workingPixelBudget(desktop: isDesktop),
        budgetBytes: decodeByteBudget(desktop: isDesktop),
      );
      try {
        final encoded = await encodeArtifact(working, params);
        return await writeManualArtifactToUploadDir(
          srcPath,
          dir,
          encoded,
          params,
        );
      } finally {
        working.dispose();
      }
    } catch (error, stackTrace) {
      debugPrint(
        '[ImageCompressor] Manual compression failed for $srcPath: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
      try {
        return await _writeToUploadDir(
          srcPath,
          dir,
          originalBytes ?? await File(srcPath).readAsBytes(),
        );
      } catch (copyError) {
        debugPrint(
          '[ImageCompressor] Failed to copy original $srcPath: $copyError',
        );
      }
      return null;
    }
  }

  /// Writes an artifact the editor already encoded straight to [dir].
  ///
  /// The bytes are the ones the size row reported, so this is a file write and
  /// nothing else — no second decode and no second encode.
  static Future<UploadWrite> writeManualArtifactToUploadDir(
    String srcPath,
    Directory dir,
    Uint8List artifact,
    ManualCompressParams params,
  ) {
    return _writeToUploadDir(
      srcPath,
      dir,
      artifact,
      outputExtension: switch (params.format) {
        DownsizeFormat.png => 'png',
        DownsizeFormat.jpeg => 'jpeg',
        null => null,
      },
    );
  }

  /// Returns a smaller JPEG, or `null` when compression should be skipped.
  ///
  /// The skip guards are Kelivo's: a disabled pipeline, a source under
  /// [kMinBytesToCompress], transparency the preset did not opt into, and a
  /// result that would be larger than the input. What changed in ADR-0005 is how
  /// the pixels arrive — through the same budgeted working-image decode the
  /// editor uses, so a huge attach no longer full-decodes at roughly 15 bytes per
  /// source pixel. A source too large for the decode budget is skipped like any
  /// other skip, leaving the pristine copy in place.
  static Future<Uint8List?> compressBytes(
    Uint8List bytes,
    ImageCompressConfig config, {
    bool? desktop,
  }) async {
    if (!config.enabled || bytes.lengthInBytes < kMinBytesToCompress) {
      return null;
    }

    switch (detectImageSourceFormat(bytes)) {
      case ImageSourceFormat.jpeg:
        break;
      case ImageSourceFormat.png:
        if (!config.includeTransparent && _pngNeedsOptIn(bytes)) {
          return null;
        }
        break;
      case ImageSourceFormat.gif:
      case ImageSourceFormat.other:
        if (!config.includeTransparent) {
          return null;
        }
        break;
    }

    final isDesktop = desktop ?? isDesktopPlatform;
    WorkingImage? working;
    try {
      working = await decodeWorkingImageBytes(
        bytes,
        requestedLongEdge: config.maxLongEdge <= 0 ? null : config.maxLongEdge,
        // A preset is an exact cap, not the editor's 25% floor.
        floorAtQuarterOfSource: false,
        budgetPixels: workingPixelBudget(desktop: isDesktop),
        budgetBytes: decodeByteBudget(desktop: isDesktop),
      );
      final encoded = await encodeArtifact(
        working,
        ManualCompressParams(
          format: DownsizeFormat.jpeg,
          quality: config.quality,
        ),
      );
      if (encoded.lengthInBytes >= bytes.lengthInBytes) return null;
      return encoded;
    } on WorkingImageTooLargeException catch (error) {
      debugPrint('[ImageCompressor] Skipping oversized source: $error');
      return null;
    } catch (error, stackTrace) {
      debugPrint('[ImageCompressor] Compression failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    } finally {
      working?.dispose();
    }
  }

  /// A pristine copy keeps the name it was picked under, but an
  /// extensionless pick would otherwise travel as `image/png` on the wire
  /// whatever it holds, so the name gets the extension its bytes imply.
  static String _withDetectedExtension(String originalName, Uint8List bytes) {
    if (originalName.isEmpty || p.extension(originalName).isNotEmpty) {
      return originalName;
    }
    final extension = switch (detectImageSourceFormat(bytes)) {
      ImageSourceFormat.jpeg => 'jpeg',
      ImageSourceFormat.png => 'png',
      ImageSourceFormat.gif => 'gif',
      ImageSourceFormat.other => null,
    };
    if (extension == null) return originalName;
    return '${p.basenameWithoutExtension(originalName)}.$extension';
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
        : (originalName.isEmpty
              ? 'image'
              : _withDetectedExtension(originalName, bytes));

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
