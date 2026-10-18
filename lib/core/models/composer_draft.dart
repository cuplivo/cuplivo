import 'package:flutter/foundation.dart';
import 'chat_input_data.dart';
import 'message_quote.dart';

/// The editor value, before the send path trims text or filters attachments.
class ComposerDraftInput {
  const ComposerDraftInput({
    this.text = '',
    this.selectionBase = -1,
    this.selectionExtent = -1,
    this.images = const [],
    this.documents = const [],
    this.allowImagesApiRouting = true,
    this.quote,
    this.quoteLabel,
  });

  final String text;
  final int selectionBase;
  final int selectionExtent;
  final List<DraftImage> images;
  final List<DocumentAttachment> documents;
  final bool allowImagesApiRouting;

  /// The pending reply citation. Draft-only in the sense that it rides the
  /// composer state, but it is carried into the sent user message as
  /// `ChatMessage.quote`.
  final MessageQuote? quote;

  /// One-line presentation of [quote] for the composer's preview row.
  ///
  /// Presentation only: the sent bubble renders its own citation, and the
  /// model-facing citation is derived from [quote] — never from this string.
  /// It rides the draft because a whole-message citation's text is resolved
  /// from a target the restored composer no longer holds.
  final String? quoteLabel;

  bool get isEmpty => text.isEmpty && images.isEmpty && documents.isEmpty;
  Iterable<String> get paths sync* {
    yield* images.map((image) => image.path);
    yield* documents.map((document) => document.path);
  }

  ComposerDraftInput copyWith({
    String? text,
    int? selectionBase,
    int? selectionExtent,
    List<DraftImage>? images,
    List<DocumentAttachment>? documents,
    MessageQuote? quote,
    String? quoteLabel,
  }) => ComposerDraftInput(
    text: text ?? this.text,
    selectionBase: selectionBase ?? this.selectionBase,
    selectionExtent: selectionExtent ?? this.selectionExtent,
    images: images ?? this.images,
    documents: documents ?? this.documents,
    allowImagesApiRouting: allowImagesApiRouting,
    // A pending quote is cleared by rebuilding this value from the composer's
    // own state, never through `copyWith`: text and attachment edits revise a
    // draft in place and must keep the citation they were made under.
    quote: quote ?? this.quote,
    quoteLabel: quoteLabel ?? this.quoteLabel,
  );

  ChatInputData toInput({DraftSubmission? submission}) => ChatInputData(
    text: text,
    imagePaths: images.map((image) => image.path).toList(),
    documents: documents,
    allowImagesApiRouting: allowImagesApiRouting,
    draftSubmission: submission,
    quote: quote,
    quoteLabel: quoteLabel,
  );

  factory ComposerDraftInput.fromInput(ChatInputData input) =>
      ComposerDraftInput(
        text: input.text,
        images: [for (final path in input.imagePaths) DraftImage(path: path)],
        documents: List.of(input.documents),
        allowImagesApiRouting: input.allowImagesApiRouting,
        quote: input.quote,
        quoteLabel: input.quoteLabel,
      );

  Map<String, dynamic> toJson() => {
    'text': text,
    'selectionBase': selectionBase,
    'selectionExtent': selectionExtent,
    'images': images.map((image) => image.toJson()).toList(),
    'documents': [
      for (final doc in documents)
        {'path': doc.path, 'fileName': doc.fileName, 'mime': doc.mime},
    ],
    'allowImagesApiRouting': allowImagesApiRouting,
    'quote': quote?.toJson(),
    'quoteLabel': quoteLabel,
  };

  factory ComposerDraftInput.fromJson(Map<String, dynamic> json) =>
      ComposerDraftInput(
        text: json['text'] as String,
        selectionBase: json['selectionBase'] as int,
        selectionExtent: json['selectionExtent'] as int,
        images: [
          for (final value in json['images'] as List)
            DraftImage.fromJson(Map<String, dynamic>.from(value as Map)),
        ],
        documents: [
          for (final value in json['documents'] as List)
            DocumentAttachment(
              path: value['path'] as String,
              fileName: value['fileName'] as String,
              mime: value['mime'] as String,
            ),
        ],
        allowImagesApiRouting: json['allowImagesApiRouting'] as bool,
        // Absent in drafts written before the reply feature.
        quote: MessageQuote.tryParse(json['quote']),
        quoteLabel: json['quoteLabel'] as String?,
      );

  bool sameValue(ComposerDraftInput other) =>
      text == other.text &&
      selectionBase == other.selectionBase &&
      selectionExtent == other.selectionExtent &&
      allowImagesApiRouting == other.allowImagesApiRouting &&
      quote == other.quote &&
      quoteLabel == other.quoteLabel &&
      listEquals(
        images
            .map((image) => (image.path, image.processing, image.failed))
            .toList(),
        other.images
            .map((image) => (image.path, image.processing, image.failed))
            .toList(),
      ) &&
      listEquals(
        documents.map((doc) => (doc.path, doc.fileName, doc.mime)).toList(),
        other.documents
            .map((doc) => (doc.path, doc.fileName, doc.mime))
            .toList(),
      );
}

class DraftImage {
  const DraftImage({
    required this.path,
    this.processing = false,
    this.failed = false,
  });
  final String path;
  final bool processing;
  final bool failed;
  Map<String, dynamic> toJson() => {
    'path': path,
    'processing': processing,
    'failed': failed,
  };
  factory DraftImage.fromJson(Map<String, dynamic> json) => DraftImage(
    path: json['path'] as String,
    processing: json['processing'] as bool,
    failed: json['failed'] as bool,
  );
}

/// Also used as the persisted user message ID: a committed message is the
/// durable receipt for this submission, including after a lost UI callback.
class DraftSubmission {
  const DraftSubmission({
    required this.conversationId,
    required this.id,
    this.editMessageId,
  });
  final String conversationId;
  final String id;
  final String? editMessageId;
}

class ComposerDraft {
  ComposerDraft({
    required this.conversationId,
    this.assistantId,
    this.compose = const ComposerDraftInput(),
    this.edit,
    this.editMessageId,
    this.pending,
    this.submissionId,
    this.submissionEditId,
    this.revision = 0,
  });
  final String conversationId;
  String? assistantId;
  ComposerDraftInput compose;
  ComposerDraftInput? edit;
  String? editMessageId;
  ComposerDraftInput? pending;
  String? submissionId;
  String? submissionEditId;
  int revision;
  ComposerDraftInput get active => edit ?? compose;
  ComposerDraftInput get recoveryTarget =>
      submissionEditId == null ? compose : edit ?? const ComposerDraftInput();
  bool get hasRecoveryConflict =>
      !recoveryTarget.isEmpty ||
      (submissionEditId != null &&
          editMessageId != null &&
          submissionEditId != editMessageId);
  bool get hasContent => !compose.isEmpty || edit != null || pending != null;
  Iterable<String> get paths sync* {
    yield* compose.paths;
    if (edit != null) yield* edit!.paths;
    if (pending != null) yield* pending!.paths;
  }

  Map<String, dynamic> toJson() => {
    'conversationId': conversationId,
    'assistantId': assistantId,
    'compose': compose.toJson(),
    'edit': edit?.toJson(),
    'editMessageId': editMessageId,
    'pending': pending?.toJson(),
    'submissionId': submissionId,
    'submissionEditId': submissionEditId,
    'revision': revision,
  };
  factory ComposerDraft.fromJson(Map<String, dynamic> json) => ComposerDraft(
    conversationId: json['conversationId'] as String,
    assistantId: json['assistantId'] as String?,
    compose: ComposerDraftInput.fromJson(
      Map<String, dynamic>.from(json['compose'] as Map),
    ),
    edit: json['edit'] == null
        ? null
        : ComposerDraftInput.fromJson(
            Map<String, dynamic>.from(json['edit'] as Map),
          ),
    editMessageId: json['editMessageId'] as String?,
    pending: json['pending'] == null
        ? null
        : ComposerDraftInput.fromJson(
            Map<String, dynamic>.from(json['pending'] as Map),
          ),
    submissionId: json['submissionId'] as String?,
    submissionEditId: json['submissionEditId'] as String?,
    revision: json['revision'] as int,
  );
}
