import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/compress_context_options.dart';

/// A group's summary is what the next speakers read instead of the turns it
/// replaced, so the compression source has to keep the voices apart: every
/// roster member reaches the compressor as `assistant`, and only the sender
/// marker says which one spoke.
///
/// The fork's own compression builder named the speakers through a `labelOf`
/// callback. This baseline's builder is upstream's, which keeps the source
/// message's identity in the line's prefix; the speaker rides there instead of
/// in a second API, so the invariant survives the rework without a second
/// implementation of "who said this".
void main() {
  ChatMessage message(
    String id,
    String role,
    String content, {
    String? senderId,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      content: content,
      timestamp: DateTime.utc(2026),
      conversationId: 'c1',
      senderId: senderId,
    );
  }

  String line(ChatMessage message) => conversationLineForCompression(
    message,
    quoteMarker: (index) => '[$index]',
  )!;

  test('a single-owner conversation keeps the plain role label', () {
    final line0 = line(message('a1', 'assistant', 'I am.'));
    expect(line0, contains('Assistant: I am.'));
    expect(line0, contains('role=assistant'));
  });

  test('a member reply carries its sender', () {
    final line0 = line(message('a1', 'assistant', 'I am.', senderId: 'alice'));
    expect(line0, contains('Assistant[alice]: I am.'));
  });

  test('two members of one round stay distinguishable', () {
    final lines = [
      line(message('a1', 'assistant', 'I am.', senderId: 'alice')),
      line(message('a2', 'assistant', 'So am I.', senderId: 'bob')),
    ];
    expect(lines[0], isNot(lines[1]));
    expect(lines[0], contains('alice'));
    expect(lines[1], contains('bob'));
  });
}
