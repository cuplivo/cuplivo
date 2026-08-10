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

  const ChatInputData({
    required this.text,
    this.imagePaths = const [],
    this.documents = const [],
    this.allowImagesApiRouting = true,
  });
}

enum ChatInputSubmissionResult { sent, queued, rejected }

class QueuedChatInput {
  final String conversationId;
  final ChatInputData input;

  const QueuedChatInput({required this.conversationId, required this.input});
}
