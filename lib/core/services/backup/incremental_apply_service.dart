import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/chat_message.dart';
import '../../models/conversation.dart';
import '../chat/chat_service.dart';

/// Applies an incremental chats.json payload to the live store.
///
/// Merge semantics (the working-tree equivalent of the fork's LAN-sync
/// apply): every payload conversation is inserted when unknown, or updated in
/// place when known (metadata wins per [conflict direction]); messages are
/// appended only when their id is not already present, in payload order.
/// Local-only conversations and messages are never touched. This is a
/// conservative union — the same guarantee `RestoreMode.merge` gives for
/// chat content on the snapshot path.
class IncrementalApplyService {
  IncrementalApplyService({required this.chatService});

  final ChatService chatService;

  /// Applies [payload] (the `chats.json` map of an incremental zip).
  /// Returns per-conversation counts for UI feedback.
  Future<IncrementalApplyReport> apply(
    Map<String, dynamic> payload, {
    bool incomingWinsConflicts = true,
  }) async {
    final rawConversations = payload['conversations'];
    final rawMessages = payload['messages'];
    if (rawConversations is! List || rawMessages is! List) {
      throw const FormatException('incremental chats payload');
    }

    final conversations = <Conversation>[
      for (final entry in rawConversations)
        Conversation.fromJson((entry as Map).cast<String, dynamic>()),
    ];
    final messagesByConversation = <String, List<ChatMessage>>{};
    for (final entry in rawMessages) {
      final message = ChatMessage.fromJson(
        (entry as Map).cast<String, dynamic>(),
      );
      messagesByConversation
          .putIfAbsent(message.conversationId, () => <ChatMessage>[])
          .add(message);
    }

    var insertedConversations = 0;
    var updatedConversations = 0;
    var appendedMessages = 0;

    for (final incoming in conversations) {
      final existing = chatService.getConversation(incoming.id);
      if (existing == null) {
        await _insertWithMessages(
          incoming,
          messagesByConversation[incoming.id] ?? const <ChatMessage>[],
        );
        insertedConversations++;
        appendedMessages += messagesByConversation[incoming.id]?.length ?? 0;
        continue;
      }

      final next = incomingWinsConflicts
          ? incoming.copyWith(
              extras: _mergedExtras(existing, incoming),
              messageIds: List<String>.of(existing.messageIds),
            )
          : existing.copyWith(
              title: existing.title,
              isPinned: existing.isPinned,
              summary: existing.summary,
            );
      await chatService.putConversation(next);
      updatedConversations++;

      final existingOrder = existing.messageIds.toSet();
      final appendedIds = <String>[];
      for (final message
          in messagesByConversation[incoming.id] ?? const <ChatMessage>[]) {
        if (existingOrder.contains(message.id)) continue;
        await chatService.addMessageDirectly(incoming.id, message);
        appendedIds.add(message.id);
        appendedMessages++;
      }
      if (appendedIds.isNotEmpty && incomingWinsConflicts) {
        await chatService.putConversation(
          next.copyWith(messageIds: [...next.messageIds, ...appendedIds]),
        );
      }
    }

    return IncrementalApplyReport(
      insertedConversations: insertedConversations,
      updatedConversations: updatedConversations,
      appendedMessages: appendedMessages,
    );
  }

  /// Local extras the incoming row must not clobber (feature keys only the
  /// local side wrote, e.g. proactive-care state or group metadata).
  Map<String, dynamic> _mergedExtras(
    Conversation existing,
    Conversation incoming,
  ) {
    final merged = Map<String, dynamic>.from(incoming.extras);
    for (final entry in existing.extras.entries) {
      merged.putIfAbsent(entry.key, entry.value);
    }
    return merged;
  }

  Future<void> _insertWithMessages(
    Conversation conversation,
    List<ChatMessage> messages,
  ) async {
    await chatService.putConversation(conversation);
    for (final message in messages) {
      await chatService.addMessageDirectly(conversation.id, message);
    }
  }
}

class IncrementalApplyReport {
  const IncrementalApplyReport({
    required this.insertedConversations,
    required this.updatedConversations,
    required this.appendedMessages,
  });

  final int insertedConversations;
  final int updatedConversations;
  final int appendedMessages;

  @override
  String toString() => jsonEncode({
    'insertedConversations': insertedConversations,
    'updatedConversations': updatedConversations,
    'appendedMessages': appendedMessages,
  });
}

typedef IncrementalApplyDebugPrint = DebugPrintCallback;
