import 'composer_draft.dart' show DraftSubmission;
import 'package:Cuplivo/features/intelligent_ui/models/ui_context_attachment.dart';
import 'message_quote.dart';

class DocumentAttachment {
  final String path; // absolute file path
  final String fileName;
  final String mime; // e.g. application/pdf, text/plain

  const DocumentAttachment({
    required this.path,
    required this.fileName,
    required this.mime,
  });
}

class ChatInputData {
  final String text;
  final List<String> imagePaths; // absolute file paths or data URLs
  final List<DocumentAttachment> documents; // selected files
  final bool allowImagesApiRouting;
  final DraftSubmission? draftSubmission;
  final UiContextAttachment? uiContext;

  /// The pending reply citation, carried into the persisted user message as
  /// `ChatMessage.quote`. Null = a plain send.
  final MessageQuote? quote;

  /// [quote]'s one-line presentation, for the composer's preview row only.
  ///
  /// A whole-message citation has no text of its own — its label was derived
  /// from a target the composer does not hold — so it rides the payload that
  /// leaves the composer and comes back with it when a send is queued and then
  /// cancelled. It is never persisted with the message and never reaches the
  /// model; the bubble derives its own citation label.
  final String? quoteLabel;

  const ChatInputData({
    required this.text,
    this.imagePaths = const [],
    this.documents = const [],
    this.allowImagesApiRouting = true,
    this.draftSubmission,
    this.uiContext,
    this.quote,
    this.quoteLabel,
  });

  bool get isEmpty =>
      text.trim().isEmpty &&
      imagePaths.isEmpty &&
      documents.isEmpty &&
      uiContext == null;
}

enum ChatInputSubmissionResult { sent, queued, rejected }

class QueuedChatInput {
  final String conversationId;
  final ChatInputData input;

  const QueuedChatInput({required this.conversationId, required this.input});
}
