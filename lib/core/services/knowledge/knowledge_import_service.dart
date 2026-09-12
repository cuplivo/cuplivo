import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../models/knowledge.dart';
import '../chat/document_text_extractor.dart';
import 'knowledge_chunker.dart';
import 'knowledge_store.dart';

/// Extracts plain text from a file. Injectable so import can be unit-tested
/// without touching the filesystem.
typedef KnowledgeTextExtractor =
    Future<String> Function({required String path, required String mime});

enum KnowledgeImportStatus { imported, duplicate, unsupported, failed }

/// A picked file queued for import (path is platform-resolved by the picker).
class KnowledgeImportFile {
  final String path;
  final String name;

  const KnowledgeImportFile({required this.path, required this.name});
}

class KnowledgeImportResult {
  final String fileName;
  final KnowledgeImportStatus status;
  final int chunkCount;

  /// Technical failure detail (extractor marker / exception text). Never shown
  /// raw in the UI — the UI maps [status] to localized copy.
  final String? detail;

  const KnowledgeImportResult({
    required this.fileName,
    required this.status,
    this.chunkCount = 0,
    this.detail,
  });

  bool get isImported => status == KnowledgeImportStatus.imported;
}

/// Orchestrates importing one file into a knowledge base (issue #389):
/// extraction -> failure detection -> per-base SHA-256 dedup -> chunking ->
/// atomic insert (document + chunks + FTS via [KnowledgeStore]).
///
/// [DocumentTextExtractor]'s error contract embeds failure markers in the
/// returned string (e.g. `[[Failed to read PDF: ...]]`); those are treated as
/// failures here so marker text is never imported as document content.
class KnowledgeImportService {
  KnowledgeImportService({
    required this._store,
    KnowledgeTextExtractor? extractor,
  }) : _extractor = extractor ?? DocumentTextExtractor.extract;

  final KnowledgeStore _store;
  final KnowledgeTextExtractor _extractor;

  static const Map<String, String> _mimeByExtension = {
    'txt': 'text/plain',
    'md': 'text/markdown',
    'markdown': 'text/markdown',
    'pdf': 'application/pdf',
    'docx':
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  };

  static const List<String> acceptedExtensions = [
    'txt',
    'md',
    'markdown',
    'pdf',
    'docx',
  ];

  /// MIME type for [fileName], or null when the extension is unsupported.
  static String? mimeForFileName(String fileName) {
    final ext = _extension(fileName);
    return ext == null ? null : _mimeByExtension[ext];
  }

  static String sourceTypeForFileName(String fileName) {
    final ext = _extension(fileName) ?? '';
    return ext == 'markdown' ? 'md' : ext;
  }

  Future<KnowledgeImportResult> importPath({
    required KnowledgeBase base,
    required String path,
    required String fileName,
  }) async {
    final mime = mimeForFileName(fileName);
    if (mime == null) {
      return KnowledgeImportResult(
        fileName: fileName,
        status: KnowledgeImportStatus.unsupported,
      );
    }

    String extracted;
    try {
      extracted = await _extractor(path: path, mime: mime);
    } on Exception catch (e) {
      debugPrint('KnowledgeImport: extraction failed for $fileName: $e');
      return KnowledgeImportResult(
        fileName: fileName,
        status: KnowledgeImportStatus.failed,
        detail: '$e',
      );
    }

    if (isExtractionFailure(extracted)) {
      return KnowledgeImportResult(
        fileName: fileName,
        status: KnowledgeImportStatus.failed,
        detail: extracted.trim(),
      );
    }

    final content = extracted.trim();
    if (content.isEmpty) {
      return KnowledgeImportResult(
        fileName: fileName,
        status: KnowledgeImportStatus.failed,
        detail: 'empty text',
      );
    }

    final contentHash = sha256.convert(utf8.encode(content)).toString();
    if (await _store.findDocumentByHash(base.id, contentHash) != null) {
      return KnowledgeImportResult(
        fileName: fileName,
        status: KnowledgeImportStatus.duplicate,
      );
    }

    final pieces = KnowledgeChunker.chunk(
      content,
      chunkSize: base.chunkSize,
      chunkOverlap: base.chunkOverlap,
    );
    if (pieces.isEmpty) {
      return KnowledgeImportResult(
        fileName: fileName,
        status: KnowledgeImportStatus.failed,
        detail: 'empty text',
      );
    }

    final documentId = const Uuid().v4();
    final document = KnowledgeDocument(
      id: documentId,
      knowledgeBaseId: base.id,
      name: fileName,
      sourceType: sourceTypeForFileName(fileName),
      content: content,
      contentHash: contentHash,
      charCount: content.length,
      chunkTotal: pieces.length,
      importedAt: DateTime.now(),
    );
    final chunks = <KnowledgeChunk>[
      for (var i = 0; i < pieces.length; i++)
        KnowledgeChunk(
          id: const Uuid().v4(),
          documentId: documentId,
          knowledgeBaseId: base.id,
          chunkIndex: i,
          content: pieces[i],
          charCount: pieces[i].length,
        ),
    ];
    await _store.insertDocumentWithChunks(document, chunks);
    return KnowledgeImportResult(
      fileName: fileName,
      status: KnowledgeImportStatus.imported,
      chunkCount: chunks.length,
    );
  }

  /// True when [text] is one of [DocumentTextExtractor]'s failure markers.
  static bool isExtractionFailure(String text) {
    final trimmed = text.trimLeft();
    return trimmed.startsWith('[[') ||
        trimmed.startsWith('[PDF]') ||
        trimmed.startsWith('[DOCX]') ||
        trimmed.startsWith('[DOC format');
  }

  static String? _extension(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return null;
    return fileName.substring(dot + 1).toLowerCase();
  }
}
