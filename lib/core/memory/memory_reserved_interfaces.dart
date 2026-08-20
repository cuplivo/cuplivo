/// Reserved interfaces for the memory subsystem's deferred phases.
///
/// Each entry in this file is a `TODO(phase-N)` placeholder — the abstract
/// class is the call site the rest of the codebase may depend on, the
/// default implementation throws so any accidental use fails loudly in
/// tests instead of silently dropping a memory write.
///
/// Phase 2 (cheap): DailySummary, DiarySummary, ExternalMemory,
/// MemoryPluginBridge, StickerAi, ReadingSpace.
/// Phase 3 (Android-bound): ProactiveMessage — gated on a Flutter-native
/// notifications / WorkManager equivalent.
library;

import '../services/chat/chat_service.dart';

class DailySummaryService {
  Future<void> summarizeToday() {
    throw UnimplementedError(
      'DailySummaryService.summarizeToday is reserved for phase 2.',
    );
  }
}

class DiarySummaryService {
  Future<String> generate(DateTime date) {
    throw UnimplementedError(
      'DiarySummaryService.generate is reserved for phase 2.',
    );
  }
}

class ExternalMemoryService {
  Future<void> syncToCloud() {
    throw UnimplementedError(
      'ExternalMemoryService.syncToCloud is reserved for phase 2.',
    );
  }

  Future<void> syncFromCloud() {
    throw UnimplementedError(
      'ExternalMemoryService.syncFromCloud is reserved for phase 2.',
    );
  }
}

class MemoryPluginBridge {
  Map<String, Function> get jsApi {
    throw UnimplementedError(
      'MemoryPluginBridge.jsApi is reserved for phase 2.',
    );
  }
}

class StickerAiSupport {
  static String buildPromptPlaceholder() {
    throw UnimplementedError(
      'StickerAiSupport.buildPrompt is reserved for phase 2.',
    );
  }
}

class ReadingSpaceService {
  Future<List<ReadingNote>> getRecentNotes(String bookId) {
    throw UnimplementedError(
      'ReadingSpaceService.getRecentNotes is reserved for phase 2.',
    );
  }
}

class ReadingNote {
  final String bookId;
  final String quote;
  final String text;
  final DateTime createdAt;
  const ReadingNote({
    required this.bookId,
    required this.quote,
    required this.text,
    required this.createdAt,
  });
}

class ProactiveMessageService {
  /// Reference kept only so a future Flutter notifications port has a
  /// typed handle to the chat service. The intent field is intentionally
  /// loose here — the eventual port will replace this with a concrete
  /// platform-channel call.
  final ChatService? chatService;
  ProactiveMessageService({this.chatService});

  Future<void> scheduleMessagePlaceholder() {
    throw UnimplementedError(
      'ProactiveMessageService is reserved for phase 3 (Flutter-native).',
    );
  }
}
