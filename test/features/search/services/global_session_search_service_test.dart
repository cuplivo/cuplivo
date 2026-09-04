import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/quick_instruction.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/search/services/global_session_search_service.dart';

/// Minimal ChatService stand-in: the search service only reads
/// [ChatService.searchConversationMatches], which we stub with pre-built
/// candidates so the test exercises the service-level stripping of vendor
/// thinking blocks (`<think>` / `<thinking>` / `<thought>` / `<reasoning>`).
class _FakeChatService extends ChatService {
  List<ConversationSearchMatch> matches = <ConversationSearchMatch>[];

  @override
  List<ConversationSearchMatch> searchConversationMatches({
    required List<String> tokens,
    int limit = 200,
  }) {
    return matches;
  }
}

ConversationSearchMatch _match({
  required String content,
  String role = 'assistant',
  String title = 'Conversation',
  String? quickInstructionInvocationsJson,
}) {
  return ConversationSearchMatch(
    conversationId: 'conv-1',
    conversationTitle: title,
    updatedAt: DateTime(2026, 1, 1),
    versionSelections: const <String, int>{},
    messageId: 'msg-1',
    messageContent: content,
    quickInstructionInvocationsJson: quickInstructionInvocationsJson,
    messageRole: role,
    groupId: 'msg-1',
    version: 0,
    maxVersion: 0,
  );
}

void main() {
  late _FakeChatService chatService;

  setUp(() {
    chatService = _FakeChatService();
  });

  group('GlobalSessionSearchService vendor thinking stripping', () {
    test('long <thinking> content does not participate in search', () {
      chatService.matches = [
        _match(content: 'visible answer <thinking>hidden needle</thinking>'),
      ];

      // Token only present inside the <thinking> block must not match.
      final results = GlobalSessionSearchService.search(
        chatService: chatService,
        query: 'needle',
      );
      expect(results, isEmpty);

      // Visible content still matches normally.
      final visible = GlobalSessionSearchService.search(
        chatService: chatService,
        query: 'visible',
      );
      expect(visible, hasLength(1));
      expect(visible.first.snippet, contains('visible'));
    });

    test('mixed-case <THINKING> content is stripped', () {
      chatService.matches = [
        _match(content: '<THINKING>secret</THINKING> visible'),
      ];

      final results = GlobalSessionSearchService.search(
        chatService: chatService,
        query: 'secret',
      );
      expect(results, isEmpty);
    });

    test('legacy <think> content stays stripped (regression)', () {
      chatService.matches = [_match(content: '<think>secret</think> visible')];

      final results = GlobalSessionSearchService.search(
        chatService: chatService,
        query: 'secret',
      );
      expect(results, isEmpty);
    });

    test('<thought> and <reasoning> blocks stay stripped (regression)', () {
      chatService.matches = [
        _match(
          content:
              'a <thought>hidden thought</thought> b '
              '<reasoning>hidden reasoning</reasoning> c',
        ),
      ];

      expect(
        GlobalSessionSearchService.search(
          chatService: chatService,
          query: 'hidden',
        ),
        isEmpty,
      );
      expect(
        GlobalSessionSearchService.search(
          chatService: chatService,
          query: 'reasoning',
        ),
        isEmpty,
      );
    });

    test('unclosed <thinking> tag keeps the whole text searchable', () {
      // Mirrors ThinkingTagParser: an unclosed tag is not a valid vendor
      // block, so the raw text remains part of the searchable body.
      chatService.matches = [
        _match(content: 'streaming <thinking>partial reasoning'),
      ];

      final results = GlobalSessionSearchService.search(
        chatService: chatService,
        query: 'partial',
      );
      expect(results, hasLength(1));
    });
  });

  test('quick-instruction names are searchable without exposing prompts', () {
    final snapshot = QuickInstructionInvocationSnapshot.fromInstruction(
      QuickInstruction(
        id: 'review',
        title: 'Careful review',
        prompt: 'private prompt needle',
      ),
      order: 0,
    );
    chatService.matches = [
      _match(
        role: 'user',
        content: 'visible question',
        quickInstructionInvocationsJson:
            QuickInstructionInvocationSnapshot.encodeList([snapshot]),
      ),
    ];

    final byName = GlobalSessionSearchService.search(
      chatService: chatService,
      query: 'careful',
    );
    final byPrompt = GlobalSessionSearchService.search(
      chatService: chatService,
      query: 'needle',
    );

    expect(byName.single.snippet, contains('Careful review'));
    expect(byName.single.snippet, isNot(contains('private prompt')));
    expect(byPrompt, isEmpty);
  });
}
