import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/features/harness/controllers/dsh_chat_session.dart';

/// Why a composer attachment could not be prepared for `session/prompt`.
///
/// The service throws these instead of surfacing a transport string; the chat
/// surface maps the kind to a localized sentence (numbers are carried so the
/// user sees the real budget that was exceeded, never an invented one).
enum DshAttachmentFailureKind {
  /// More images than the Host's `maxImagesPerMessage`.
  tooManyImages,

  /// One encoded image exceeds `maxImageBytes`.
  imageTooLarge,

  /// All inline images together exceed `maxMessageImageBytes`.
  imagesTooLarge,

  /// The image's type is outside the Host's `mediaTypes` list.
  unsupportedImageType,

  /// The staged file could not be read from disk.
  readFailed,

  /// `POST /api/session/uploadFileBinary` refused the file.
  uploadFailed,
}

@immutable
class DshAttachmentFailure implements Exception {
  const DshAttachmentFailure(
    this.kind, {
    this.fileName,
    this.actualBytes,
    this.limitBytes,
    this.detail,
  });

  final DshAttachmentFailureKind kind;
  final String? fileName;
  final int? actualBytes;
  final int? limitBytes;

  /// Host-supplied rejection text when there is one (`uploadFailed`).
  final String? detail;

  @override
  String toString() => 'DshAttachmentFailure($kind)';
}

/// Turns the composer's staged paths into the prompt parts `session/prompt`
/// accepts.
///
/// DSH's prompt takes images **inline as base64** (`content[].data`) and files
/// as **upload receipts** (`uploadFileBinary` → `file` part). The service keeps
/// that split and enforces the Host's `imageLimits` projection before anything
/// is sent, so a refused image keeps the draft instead of half-sending a prompt.
///
/// It is deliberately I/O-injected: the chat view owns the handle and passes
/// `readFile`/`uploadFile`, which keeps the limit logic pure and testable.
class DshAttachmentUploadService {
  DshAttachmentUploadService({
    required this.readFile,
    required this.uploadFile,
    required this.imageLimits,
  });

  /// Reads one staged path's bytes (images and files alike).
  final Future<Uint8List> Function(String path) readFile;

  /// Uploads bytes and returns the receipt id for the prompt's file part.
  final Future<String> Function(
    Uint8List bytes, {
    required String name,
    String? mediaType,
  })
  uploadFile;

  /// The Host's current budget (null when the projection has not arrived).
  final DshImageLimits? Function() imageLimits;

  /// Prepares every attachment of [input] for one prompt.
  ///
  /// Images keep their bytes inline; every document is uploaded and referenced
  /// by its receipt. Throws [DshAttachmentFailure] for a refused item.
  Future<List<DshPromptAttachment>> prepare(ChatInputData input) async {
    final prepared = <DshPromptAttachment>[];
    final limits = imageLimits();
    final images = input.imagePaths;
    if (images.isNotEmpty) {
      final maxCount = limits?.maxImagesPerMessage;
      if (maxCount != null && maxCount > 0 && images.length > maxCount) {
        throw DshAttachmentFailure(
          DshAttachmentFailureKind.tooManyImages,
          actualBytes: images.length,
          limitBytes: maxCount,
        );
      }
      var totalBytes = 0;
      for (var index = 0; index < images.length; index++) {
        final path = images[index];
        final bytes = await _readImageBytes(path);
        final name = _imageName(path);
        final mediaType = _imageMediaType(name);
        final accepted = limits?.mediaTypes;
        if (accepted != null &&
            accepted.isNotEmpty &&
            !accepted.contains(mediaType)) {
          throw DshAttachmentFailure(
            DshAttachmentFailureKind.unsupportedImageType,
            fileName: name,
            detail: mediaType,
          );
        }
        final maxImageBytes = limits?.maxImageBytes;
        if (maxImageBytes != null &&
            maxImageBytes > 0 &&
            bytes.length > maxImageBytes) {
          throw DshAttachmentFailure(
            DshAttachmentFailureKind.imageTooLarge,
            fileName: name,
            actualBytes: bytes.length,
            limitBytes: maxImageBytes,
          );
        }
        totalBytes += bytes.length;
        prepared.add(
          DshPromptAttachment.image(
            bytes: bytes,
            name: name,
            mediaType: mediaType,
          ),
        );
      }
      final maxTotalBytes = limits?.maxMessageImageBytes;
      if (maxTotalBytes != null &&
          maxTotalBytes > 0 &&
          totalBytes > maxTotalBytes) {
        throw DshAttachmentFailure(
          DshAttachmentFailureKind.imagesTooLarge,
          actualBytes: totalBytes,
          limitBytes: maxTotalBytes,
        );
      }
    }
    for (final document in input.documents) {
      final Uint8List bytes;
      try {
        bytes = await readFile(document.path);
      } catch (_) {
        throw DshAttachmentFailure(
          DshAttachmentFailureKind.readFailed,
          fileName: document.fileName,
        );
      }
      try {
        final receiptId = await uploadFile(
          bytes,
          name: document.fileName,
          mediaType: document.mime,
        );
        prepared.add(
          DshPromptAttachment.file(
            receiptId: receiptId,
            name: document.fileName,
            mediaType: document.mime,
          ),
        );
      } catch (error) {
        throw DshAttachmentFailure(
          DshAttachmentFailureKind.uploadFailed,
          fileName: document.fileName,
          detail: error is Exception ? '$error' : null,
        );
      }
    }
    return prepared;
  }

  Future<Uint8List> _readImageBytes(String path) async {
    final trimmed = path.trim();
    if (trimmed.startsWith('data:')) {
      final marker = trimmed.indexOf('base64,');
      if (marker != -1) {
        try {
          return base64Decode(trimmed.substring(marker + 7));
        } on FormatException {
          throw const DshAttachmentFailure(DshAttachmentFailureKind.readFailed);
        }
      }
      throw const DshAttachmentFailure(DshAttachmentFailureKind.readFailed);
    }
    try {
      return await readFile(trimmed);
    } catch (_) {
      throw DshAttachmentFailure(
        DshAttachmentFailureKind.readFailed,
        fileName: _imageName(trimmed),
      );
    }
  }

  static String _imageName(String path) {
    if (path.startsWith('data:')) return 'image.png';
    final normalized = path.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    return index == -1 ? normalized : normalized.substring(index + 1);
  }

  static String _imageMediaType(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/png';
  }
}
