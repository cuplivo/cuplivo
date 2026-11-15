import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/home/controllers/chat_controller.dart';

/// A [ChatService] whose rows a test can change the way LAN sync's apply does:
/// messages and a title per conversation, an external-write counter, and one
/// notification. The window loading mirrors the real service's shapes — a tail
/// window, a before window and an around window — so the controller's anchoring
/// decisions are exercised rather than assumed.
class _FakeChatService extends ChatService {
  _FakeChatService(this._messages);

  final Map<String, List<ChatMessage>> _messages;
  final Map<String, int> _externalRevisions = <String, int>{};
  final Map<String, String> _titles = <String, String>{};
  final List<String> pageRequests = <String>[];

  /// What the sync apply does: rows land, the counter moves, listeners are told.
  void applyExternalWrite(
    String conversationId,
    List<ChatMessage> messages, {
    String? title,
  }) {
    _messages[conversationId] = messages;
    if (title != null) _titles[conversationId] = title;
    _externalRevisions[conversationId] =
        (_externalRevisions[conversationId] ?? 0) + 1;
    notifyListeners();
  }

  /// A notification with nothing behind it: the app's own write traffic.
  void notifyWithoutExternalWrite() => notifyListeners();

  @override
  int externalWriteRevision(String conversationId) =>
      _externalRevisions[conversationId] ?? 0;

  @override
  Future<LoadedTimelinePage?> loadTimelinePage(
    String conversationId, {
    String? beforeRevisionId,
    String? afterRevisionId,
    String? aroundRevisionId,
    bool fromStart = false,
    int limit = 40,
  }) async {
    pageRequests.add(conversationId);
    final messages = _messages[conversationId] ?? const <ChatMessage>[];
    late final int start;
    late final int end;
    if (aroundRevisionId != null) {
      final index = messages.indexWhere(
        (message) => message.id == aroundRevisionId,
      );
      final anchor = index < 0 ? 0 : index;
      start = (anchor - limit ~/ 2).clamp(0, messages.length);
      end = (start + limit).clamp(start, messages.length);
    } else if (beforeRevisionId != null) {
      final index = messages.indexWhere(
        (message) => message.id == beforeRevisionId,
      );
      final anchor = index < 0 ? messages.length : index;
      end = anchor;
      start = (anchor - limit).clamp(0, end);
    } else {
      end = messages.length;
      start = (messages.length - limit).clamp(0, end);
    }
    final timestamp = DateTime(2026, 7, 11);
    return LoadedTimelinePage(
      conversationId: conversationId,
      stateRevision: _externalRevisions[conversationId] ?? 0,
      contextStartRevisionId: null,
      slots: [
        for (final (offset, message) in messages.sublist(start, end).indexed)
          LoadedTimelineSlot(
            identity: ActiveTimelineSlot(
              slotId: message.groupId ?? message.id,
              revisionId: message.id,
              parentRevisionId: null,
              role: message.role,
              createdAt: timestamp,
              updatedAt: timestamp,
              finalizedAt: timestamp,
              versionCount: 1,
              logicalIndex: start + offset,
            ),
            message: message,
          ),
      ],
      hasMoreBefore: start > 0,
      hasMoreAfter: end < messages.length,
      totalSlotCount: messages.length,
    );
  }

  @override
  Conversation? getConversation(String id) {
    final messages = _messages[id];
    if (messages == null) return null;
    return Conversation(
      id: id,
      title: _titles[id] ?? 'Conversation $id',
      messageIds: messages.map((message) => message.id).toList(),
    );
  }

  @override
  bool isConversationFullyCached(String conversationId) => true;

  @override
  Map<String, int> getVersionSelections(String conversationId) =>
      const <String, int>{};

  @override
  List<ChatMessage> getMessagesForGroups(
    String conversationId,
    Iterable<String> groupIds,
  ) => const <ChatMessage>[];

  @override
  Future<List<ChatMessage>> loadMessagesForGroups(
    String conversationId,
    Iterable<String> groupIds,
  ) async => const <ChatMessage>[];

  @override
  Map<String, int> getFirstMessageIndicesForGroups(
    String conversationId,
    Iterable<String> groupIds,
  ) => const <String, int>{};

  @override
  Future<Map<String, int>> loadFirstMessageIndicesForGroups(
    String conversationId,
    Iterable<String> groupIds,
  ) async => const <String, int>{};
}

ChatMessage _message(String conversationId, int index) => ChatMessage(
  id: '$conversationId-message-$index',
  role: index.isEven ? 'user' : 'assistant',
  content: '$conversationId message $index',
  conversationId: conversationId,
);

void main() {
  group('ChatController reloads after an external write', () {
    late _FakeChatService service;
    late ChatController controller;

    setUp(() {
      service = _FakeChatService({
        'conv-a': [for (var i = 0; i < 5; i++) _message('conv-a', i)],
        'conv-b': [for (var i = 0; i < 3; i++) _message('conv-b', i)],
      });
      controller = ChatController(chatService: service);
    });

    tearDown(() {
      controller.dispose();
    });

    test('a peer write rebuilds the open window and its metadata', () async {
      await controller.setCurrentConversationAndLoad(
        service.getConversation('conv-a')!,
      );
      await pumpEventQueue();
      expect(controller.messages, hasLength(5));

      service.applyExternalWrite('conv-a', [
        for (var i = 0; i < 6; i++) _message('conv-a', i),
      ], title: 'Renamed by the peer');
      await pumpEventQueue();

      expect(
        controller.messages.map((message) => message.id),
        contains('conv-a-message-5'),
        reason: 'the messages the peer sent show up without reopening',
      );
      expect(
        controller.currentConversation?.title,
        'Renamed by the peer',
        reason: 'the row the page renders outside the window is refreshed too',
      );
    });

    test('an unrelated conversation leaves the window alone', () async {
      await controller.setCurrentConversationAndLoad(
        service.getConversation('conv-a')!,
      );
      await pumpEventQueue();
      final requestsBefore = service.pageRequests.length;

      service.applyExternalWrite('conv-b', [
        for (var i = 0; i < 9; i++) _message('conv-b', i),
      ]);
      await pumpEventQueue();

      expect(controller.currentConversation?.id, 'conv-a');
      expect(controller.messages, hasLength(5));
      expect(
        service.pageRequests.length,
        requestsBefore,
        reason: 'only the touched conversation is rebuilt',
      );
    });

    test('a notification with no external write costs nothing', () async {
      await controller.setCurrentConversationAndLoad(
        service.getConversation('conv-a')!,
      );
      await pumpEventQueue();
      final requestsBefore = service.pageRequests.length;

      service.notifyWithoutExternalWrite();
      await pumpEventQueue();

      expect(service.pageRequests.length, requestsBefore);
      expect(controller.messages, hasLength(5));
    });

    test('a write during a local generation waits for it', () async {
      await controller.setCurrentConversationAndLoad(
        service.getConversation('conv-a')!,
      );
      await pumpEventQueue();
      final requestsBefore = service.pageRequests.length;

      controller.setConversationLoading('conv-a', true);
      service.applyExternalWrite('conv-a', [
        for (var i = 0; i < 7; i++) _message('conv-a', i),
      ]);
      await pumpEventQueue();
      expect(
        service.pageRequests.length,
        requestsBefore,
        reason: 'reloading under a running generation would fight its writes',
      );

      // The generation ends and the deferred rebuild runs on that notification.
      controller.setConversationLoading('conv-a', false);
      await pumpEventQueue();
      expect(controller.messages, hasLength(7));
      expect(controller.messages.last.id, 'conv-a-message-6');
    });

    test('a scrolled-up window is not yanked to the tail', () async {
      final long = [for (var i = 0; i < 500; i++) _message('conv-a', i)];
      service.applyExternalWrite('conv-a', long);
      await controller.setCurrentConversationAndLoad(
        service.getConversation('conv-a')!,
      );
      await pumpEventQueue();

      // The user jumped to the middle of the history.
      await controller.loadWindowAroundMessage('conv-a-message-250');
      expect(controller.hasMoreAfter, isTrue);

      // The peer appends at the tail, which this viewport is not showing.
      service.applyExternalWrite('conv-a', [...long, _message('conv-a', 500)]);
      await pumpEventQueue();

      expect(
        controller.messages.map((message) => message.id),
        contains('conv-a-message-250'),
        reason: 'the window is rebuilt around the position the user is at',
      );
      expect(
        controller.messages.map((message) => message.id),
        isNot(contains('conv-a-message-500')),
        reason: 'a reader above the bottom is not thrown to the new messages',
      );
      expect(controller.hasMoreAfter, isTrue);
    });
  });
}
