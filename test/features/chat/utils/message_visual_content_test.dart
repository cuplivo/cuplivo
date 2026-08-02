import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/assistant_regex.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/features/chat/utils/message_visual_content.dart';

ChatMessage _message({
  String role = 'assistant',
  String content = '',
  bool isStreaming = false,
  String? reasoningText,
  String? reasoningSegmentsJson,
}) {
  return ChatMessage(
    role: role,
    content: content,
    conversationId: 'c1',
    isStreaming: isStreaming,
    reasoningText: reasoningText,
    reasoningSegmentsJson: reasoningSegmentsJson,
  );
}

void main() {
  group('messageVisualContent', () {
    test('strips legacy <think> blocks', () {
      final msg = _message(content: 'Hello <think>hidden</think> world');
      expect(messageVisualContent(msg), 'Hello  world');
    });

    test('keeps content as-is when structured reasoning is present', () {
      final msg = _message(
        content: '<think>kept</think> body',
        reasoningText: 'reasoning text',
      );
      expect(messageVisualContent(msg), '<think>kept</think> body');
    });

    test('keeps content as-is when reasoning segments are present', () {
      final msg = _message(
        content: '<think>kept</think> body',
        reasoningSegmentsJson: '[{"text":"seg"}]',
      );
      expect(messageVisualContent(msg), '<think>kept</think> body');
    });

    test('strips <think> when segments JSON is an empty list', () {
      final msg = _message(
        content: 'Hi <think>hidden</think> there',
        reasoningSegmentsJson: '[]',
      );
      expect(messageVisualContent(msg), 'Hi  there');
    });

    test('keeps content when map-form segments have entries', () {
      final msg = _message(
        content: '<think>kept</think> body',
        reasoningSegmentsJson: '{"v":2,"segments":[{"text":"seg"}]}',
      );
      expect(messageVisualContent(msg), '<think>kept</think> body');
    });

    test('strips <think> when map-form segments payload is empty', () {
      final msg = _message(
        content: 'Hi <think>hidden</think> there',
        reasoningSegmentsJson: '{"v":2,"segments":[]}',
      );
      expect(messageVisualContent(msg), 'Hi  there');
    });

    test('strips <think> when segments JSON is malformed', () {
      final msg = _message(
        content: 'Hi <think>hidden</think> there',
        reasoningSegmentsJson: '{oops',
      );
      expect(messageVisualContent(msg), 'Hi  there');
    });

    test('applies visual regex transforms with an assistant', () {
      final assistant = Assistant(
        id: 'a1',
        name: 'A',
        regexRules: const [
          AssistantRegex(
            id: 'r1',
            name: 'r',
            pattern: r'\bfoo\b',
            replacement: 'bar',
            scopes: [AssistantRegexScope.assistant],
            visualOnly: true,
          ),
        ],
      );
      final msg = _message(content: 'foo baz');
      expect(messageVisualContent(msg, assistant: assistant), 'bar baz');
    });

    test('leaves content untouched without an assistant', () {
      final msg = _message(content: 'foo baz');
      expect(messageVisualContent(msg), 'foo baz');
    });
  });

  group('canUseReadingMode', () {
    test('true for a long assistant message', () {
      expect(
        canUseReadingMode(_message(content: 'x' * (kReadingModeMinChars + 1))),
        isTrue,
      );
    });

    test('false at exactly the threshold', () {
      expect(
        canUseReadingMode(_message(content: 'x' * kReadingModeMinChars)),
        isFalse,
      );
    });

    test('false for a short assistant message', () {
      expect(canUseReadingMode(_message(content: 'hello')), isFalse);
    });

    test('false while streaming', () {
      expect(
        canUseReadingMode(
          _message(
            content: 'x' * (kReadingModeMinChars + 1),
            isStreaming: true,
          ),
        ),
        isFalse,
      );
    });

    test('false for user messages regardless of length', () {
      expect(
        canUseReadingMode(
          _message(role: 'user', content: 'x' * (kReadingModeMinChars + 1)),
        ),
        isFalse,
      );
    });

    test('length counts the think-stripped visual content', () {
      final content =
          '<think>${'x' * kReadingModeMinChars}</think>short visible';
      expect(canUseReadingMode(_message(content: content)), isFalse);
    });
  });
}
