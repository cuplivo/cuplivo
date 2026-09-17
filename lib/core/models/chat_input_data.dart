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

  /// Pending reply citation; carried into the persisted user message as
  /// `ChatMessage.quoteJson`. Null = plain send.
  final MessageQuote? quote;

  /// Display-ready quote snippet for the composer preview row. Draft-only
  /// presentation state (the bubble renders its own citation); never read by
  /// the send pipeline.
  final String? quoteSnippet;

  const ChatInputData({
    required this.text,
    this.imagePaths = const [],
    this.documents = const [],
    this.allowImagesApiRouting = true,
    this.quote,
    this.quoteSnippet,
  });

  ChatInputData copyWith({
    String? text,
    List<String>? imagePaths,
    List<DocumentAttachment>? documents,
    bool? allowImagesApiRouting,
    Object? quote = _sentinel,
    Object? quoteSnippet = _sentinel,
  }) {
    return ChatInputData(
      text: text ?? this.text,
      imagePaths: imagePaths ?? this.imagePaths,
      documents: documents ?? this.documents,
      allowImagesApiRouting:
          allowImagesApiRouting ?? this.allowImagesApiRouting,
      quote: identical(quote, _sentinel) ? this.quote : quote as MessageQuote?,
      quoteSnippet: identical(quoteSnippet, _sentinel)
          ? this.quoteSnippet
          : quoteSnippet as String?,
    );
  }
}

const _sentinel = Object();

enum ChatInputSubmissionResult { sent, queued, rejected }

class QueuedChatInput {
  final String conversationId;
  final ChatInputData input;

  const QueuedChatInput({required this.conversationId, required this.input});
}
