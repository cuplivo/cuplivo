import '../models/chat_message.dart';
import '../models/quick_instruction.dart';

String quickInstructionNameMarkers(ChatMessage message) {
  return quickInstructionSnapshotNameMarkers(
    message.quickInstructionInvocations,
  );
}

String quickInstructionSnapshotNameMarkers(
  Iterable<QuickInstructionInvocationSnapshot> snapshots,
) {
  final titles = snapshots
      .map((snapshot) => snapshot.title.trim())
      .where((title) => title.isNotEmpty)
      .toList(growable: false);
  return titles.map((title) => '【$title】').join(' ');
}

/// Human-readable text may expose invocation names, but never the frozen
/// prompt or tool policy. API processing, translation, and TTS intentionally
/// keep using [ChatMessage.content] instead.
String quickInstructionDecoratedContent(ChatMessage message) {
  return quickInstructionDecorateText(message, message.content);
}

String quickInstructionDecorateText(ChatMessage message, String content) {
  final markers = quickInstructionNameMarkers(message);
  if (markers.isEmpty) return content;
  final body = content.trim();
  return body.isEmpty ? markers : '$markers\n$body';
}
