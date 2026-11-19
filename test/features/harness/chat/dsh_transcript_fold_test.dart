import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/features/harness/controllers/dsh_chat_session.dart';
import 'package:Cuplivo/features/harness/controllers/dsh_transcript_fold.dart';

void main() {
  const conversationId = 'dsh:remote-1:session-1';

  DshChatViewState buildState() {
    return DshChatViewState(
      items: <DshChatItem>[
        DshUserMessageItem(
          id: 'u1',
          text: 'hello',
          timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
        DshAssistantMessageItem(
          id: 'a1',
          text: 'hi there',
          timestamp: DateTime.fromMillisecondsSinceEpoch(2000),
          isStreaming: true,
          interrupted: true,
          modelId: 'deepseek-flash',
          providerId: 'deepseek',
          reasoning: const <DshReasoningSegment>[
            DshReasoningSegment(
              text: 'weigh the options',
              startedAt: null,
              finishedAt: null,
            ),
          ],
          tools: const <DshToolCall>[
            DshToolCall(
              id: 't1',
              name: 'read_file',
              arguments: <String, dynamic>{'path': 'README.md'},
              resultText: 'contents',
              isRunning: true,
            ),
          ],
          usage: const DshUsage(
            promptTokens: 11,
            completionTokens: 7,
            totalTokens: 18,
          ),
          failureMessage: 'stream ended',
        ),
        DshNoticeItem(
          id: 'n1',
          kind: DshNoticeKind.cancelled,
          text: 'cancelled by user',
        ),
      ],
    );
  }

  group('foldDshTranscript', () {
    test('produces one renderer message per transcript item', () {
      final folded = foldDshTranscript(
        conversationId: conversationId,
        state: buildState(),
      );

      expect(folded.messages, hasLength(2));
      expect(folded.isEmpty, isFalse);

      final user = folded.messages.first;
      expect(user.role, 'user');
      expect(user.conversationId, conversationId);
      expect(user.timestamp, DateTime.fromMillisecondsSinceEpoch(1000));
      expect(user.parts, hasLength(1));
      expect((user.parts.single as TextPart).text, 'hello');
      expect(user.isStreaming, isFalse);

      final assistant = folded.messages.last;
      expect(assistant.role, 'assistant');
      expect(assistant.conversationId, conversationId);
      expect(assistant.isStreaming, isTrue);
      expect(assistant.modelId, 'deepseek-flash');
      expect(assistant.providerId, 'deepseek');
      expect(assistant.reasoningText, 'weigh the options');
      expect(assistant.promptTokens, 11);
      expect(assistant.completionTokens, 7);
      expect(assistant.totalTokens, 18);
      expect((assistant.parts.single as TextPart).text, 'hi there');
    });

    test('exposes reasoning segments, tool cards and notices', () {
      final folded = foldDshTranscript(
        conversationId: conversationId,
        state: buildState(),
      );

      final reasoning = folded.reasoning['a1'];
      expect(reasoning, isNotNull);
      expect(reasoning!.text, 'weigh the options');

      final segments = folded.reasoningSegments['a1'];
      expect(segments, hasLength(1));
      expect(segments!.single.text, 'weigh the options');
      expect(segments.single.toolStartIndex, 0);

      final tools = folded.toolParts['a1'];
      expect(tools, hasLength(1));
      expect(tools!.single.id, 't1');
      expect(tools.single.toolName, 'read_file');
      expect(tools.single.arguments, <String, dynamic>{'path': 'README.md'});
      expect(tools.single.content, 'contents');
      expect(tools.single.loading, isTrue);

      expect(folded.notices, hasLength(2));
      expect(folded.notices.first.kind, DshNoticeKind.error);
      expect(folded.notices.first.text, 'stream ended');
      expect(folded.notices.last.kind, DshNoticeKind.cancelled);
      expect(folded.notices.last.text, 'cancelled by user');
      expect(folded.contentSplits, isEmpty);
    });

    test('an empty session folds to empty renderer structures', () {
      final folded = foldDshTranscript(
        conversationId: conversationId,
        state: const DshChatViewState(),
      );

      expect(folded.isEmpty, isTrue);
      expect(folded.messages, isEmpty);
      expect(folded.reasoning, isEmpty);
      expect(folded.reasoningSegments, isEmpty);
      expect(folded.toolParts, isEmpty);
      expect(folded.notices, isEmpty);
    });

    test('a missing timestamp gets the renderer-safe epoch fallback', () {
      final folded = foldDshTranscript(
        conversationId: conversationId,
        state: const DshChatViewState(
          items: <DshChatItem>[DshUserMessageItem(id: 'u1', text: 'hi')],
        ),
      );

      expect(folded.messages.single.timestamp, isNotNull);
      expect(folded.messages.single.timestamp.millisecondsSinceEpoch, 0);
    });
  });

  group('groupDshTranscript', () {
    test('puts every message in its own group at version 0', () {
      final folded = foldDshTranscript(
        conversationId: conversationId,
        state: buildState(),
      );
      final grouping = groupDshTranscript(folded.messages);

      expect(grouping.byGroup.keys, <String>['u1', 'a1']);
      expect(grouping.byGroup['u1'], hasLength(1));
      expect(grouping.byGroup['a1'], hasLength(1));
      expect(grouping.versionSelections, <String, int>{'u1': 0, 'a1': 0});
    });

    test('an empty transcript groups to empty maps', () {
      final grouping = groupDshTranscript(const <ChatMessage>[]);
      expect(grouping.byGroup, isEmpty);
      expect(grouping.versionSelections, isEmpty);
    });
  });
}
