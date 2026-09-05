import 'message_quote.dart';
import 'quick_instruction.dart';

/// SharedPreferences key of the persisted chat input draft. Single global
/// draft — the input is shared across conversations. Local-only: excluded
/// from backups/LAN sync (see `SharedPreferencesAsync._localOnlyKeys`).
const String chatInputDraftPrefsKey = 'chat_draft_v1';

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
  final Map<String, dynamic> extraBody; // per-send API body overrides

  /// Pending reply citation; carried into the persisted user message as
  /// `ChatMessage.quoteJson`. Null = plain send.
  final MessageQuote? quote;

  /// Display-ready quote snippet for the composer preview row. Draft-only
  /// presentation state (the bubble renders its own citation); never read by
  /// the send pipeline.
  final String? quoteSnippet;

  /// Frozen one-shot invocations selected in the composer. Persistent
  /// invocations are merged into this list at send/queue snapshot time.
  final List<QuickInstructionInvocationSnapshot> quickInstructions;

  /// Whether the conversation's persistent activations have already been
  /// frozen into [quickInstructions]. Queued and edited inputs set this so a
  /// later send cannot absorb newly enabled instructions.
  final bool quickInstructionsFrozen;

  const ChatInputData({
    required this.text,
    this.imagePaths = const [],
    this.documents = const [],
    this.allowImagesApiRouting = true,
    this.extraBody = const {},
    this.quote,
    this.quoteSnippet,
    this.quickInstructions = const <QuickInstructionInvocationSnapshot>[],
    this.quickInstructionsFrozen = false,
  });

  ChatInputData copyWith({
    String? text,
    List<String>? imagePaths,
    List<DocumentAttachment>? documents,
    bool? allowImagesApiRouting,
    Map<String, dynamic>? extraBody,
    Object? quote = _sentinel,
    Object? quoteSnippet = _sentinel,
    List<QuickInstructionInvocationSnapshot>? quickInstructions,
    bool? quickInstructionsFrozen,
  }) {
    return ChatInputData(
      text: text ?? this.text,
      imagePaths: imagePaths ?? this.imagePaths,
      documents: documents ?? this.documents,
      allowImagesApiRouting:
          allowImagesApiRouting ?? this.allowImagesApiRouting,
      extraBody: extraBody ?? this.extraBody,
      quote: identical(quote, _sentinel) ? this.quote : quote as MessageQuote?,
      quoteSnippet: identical(quoteSnippet, _sentinel)
          ? this.quoteSnippet
          : quoteSnippet as String?,
      quickInstructions: quickInstructions ?? this.quickInstructions,
      quickInstructionsFrozen:
          quickInstructionsFrozen ?? this.quickInstructionsFrozen,
    );
  }

  static const Object _sentinel = Object();
}

enum ChatInputSubmissionResult { sent, queued, rejected }

class QueuedChatInput {
  final String conversationId;
  final ChatInputData input;

  const QueuedChatInput({required this.conversationId, required this.input});
}
