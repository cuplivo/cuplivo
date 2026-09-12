/// Knowledge base domain models (issue #389).
///
/// A [KnowledgeBase] is an assistant-bindable document collection; retrieval
/// injects the most relevant [KnowledgeChunk]s per request. The document's
/// extracted text is the source of truth — chunks and the FTS index are
/// derived data, rebuildable from [KnowledgeDocument.content].
///
/// See docs/adr/0064-knowledge-base-fts5-first-retrieval.md and
/// docs/adr/0065-knowledge-base-storage-backup-contract.md.
library;

class KnowledgeBase {
  final String id;
  final String name;
  final String description;
  final bool enabled;
  final int chunkSize;
  final int chunkOverlap;
  final DateTime createdAt;
  final DateTime updatedAt;

  const KnowledgeBase({
    required this.id,
    required this.name,
    this.description = '',
    this.enabled = true,
    this.chunkSize = 512,
    this.chunkOverlap = 64,
    required this.createdAt,
    required this.updatedAt,
  });

  KnowledgeBase copyWith({
    String? id,
    String? name,
    String? description,
    bool? enabled,
    int? chunkSize,
    int? chunkOverlap,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => KnowledgeBase(
    id: id ?? this.id,
    name: name ?? this.name,
    description: description ?? this.description,
    enabled: enabled ?? this.enabled,
    chunkSize: chunkSize ?? this.chunkSize,
    chunkOverlap: chunkOverlap ?? this.chunkOverlap,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'enabled': enabled,
    'chunkSize': chunkSize,
    'chunkOverlap': chunkOverlap,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  static KnowledgeBase fromJson(Map<String, dynamic> json) {
    final now = DateTime.now();
    return KnowledgeBase(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      chunkSize: (json['chunkSize'] as num?)?.toInt() ?? 512,
      chunkOverlap: (json['chunkOverlap'] as num?)?.toInt() ?? 64,
      createdAt: _parseDate(json['createdAt']) ?? now,
      updatedAt: _parseDate(json['updatedAt']) ?? now,
    );
  }
}

class KnowledgeDocument {
  final String id;
  final String knowledgeBaseId;
  final String name;

  /// 'txt' | 'md' | 'pdf' | 'docx' | 'manual'
  final String sourceType;

  /// Extracted plain text — the source of truth for this document.
  final String content;

  /// SHA-256 of [content], used for per-base duplicate detection.
  final String contentHash;
  final int charCount;
  final int chunkTotal;
  final DateTime importedAt;

  const KnowledgeDocument({
    required this.id,
    required this.knowledgeBaseId,
    required this.name,
    required this.sourceType,
    required this.content,
    required this.contentHash,
    required this.charCount,
    this.chunkTotal = 0,
    required this.importedAt,
  });

  KnowledgeDocument copyWith({
    String? id,
    String? knowledgeBaseId,
    String? name,
    String? sourceType,
    String? content,
    String? contentHash,
    int? charCount,
    int? chunkTotal,
    DateTime? importedAt,
  }) => KnowledgeDocument(
    id: id ?? this.id,
    knowledgeBaseId: knowledgeBaseId ?? this.knowledgeBaseId,
    name: name ?? this.name,
    sourceType: sourceType ?? this.sourceType,
    content: content ?? this.content,
    contentHash: contentHash ?? this.contentHash,
    charCount: charCount ?? this.charCount,
    chunkTotal: chunkTotal ?? this.chunkTotal,
    importedAt: importedAt ?? this.importedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'knowledgeBaseId': knowledgeBaseId,
    'name': name,
    'sourceType': sourceType,
    'content': content,
    'contentHash': contentHash,
    'charCount': charCount,
    'chunkTotal': chunkTotal,
    'importedAt': importedAt.toIso8601String(),
  };

  static KnowledgeDocument fromJson(Map<String, dynamic> json) {
    final content = (json['content'] ?? '').toString();
    return KnowledgeDocument(
      id: (json['id'] ?? '').toString(),
      knowledgeBaseId: (json['knowledgeBaseId'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      sourceType: (json['sourceType'] ?? 'txt').toString(),
      content: content,
      contentHash: (json['contentHash'] ?? '').toString(),
      charCount: (json['charCount'] as num?)?.toInt() ?? content.length,
      chunkTotal: (json['chunkTotal'] as num?)?.toInt() ?? 0,
      importedAt: _parseDate(json['importedAt']) ?? DateTime.now(),
    );
  }
}

class KnowledgeChunk {
  final String id;
  final String documentId;
  final String knowledgeBaseId;
  final int chunkIndex;
  final String content;
  final int charCount;

  const KnowledgeChunk({
    required this.id,
    required this.documentId,
    required this.knowledgeBaseId,
    required this.chunkIndex,
    required this.content,
    required this.charCount,
  });

  KnowledgeChunk copyWith({
    String? id,
    String? documentId,
    String? knowledgeBaseId,
    int? chunkIndex,
    String? content,
    int? charCount,
  }) => KnowledgeChunk(
    id: id ?? this.id,
    documentId: documentId ?? this.documentId,
    knowledgeBaseId: knowledgeBaseId ?? this.knowledgeBaseId,
    chunkIndex: chunkIndex ?? this.chunkIndex,
    content: content ?? this.content,
    charCount: charCount ?? this.charCount,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'documentId': documentId,
    'knowledgeBaseId': knowledgeBaseId,
    'chunkIndex': chunkIndex,
    'content': content,
    'charCount': charCount,
  };

  static KnowledgeChunk fromJson(Map<String, dynamic> json) {
    final content = (json['content'] ?? '').toString();
    return KnowledgeChunk(
      id: (json['id'] ?? '').toString(),
      documentId: (json['documentId'] ?? '').toString(),
      knowledgeBaseId: (json['knowledgeBaseId'] ?? '').toString(),
      chunkIndex: (json['chunkIndex'] as num?)?.toInt() ?? 0,
      content: content,
      charCount: (json['charCount'] as num?)?.toInt() ?? content.length,
    );
  }
}

DateTime? _parseDate(Object? value) {
  if (value is DateTime) return value;
  if (value is num) return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  if (value is String && value.isNotEmpty) return DateTime.tryParse(value);
  return null;
}
