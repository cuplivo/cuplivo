import 'package:Cuplivo/core/services/logging/context_log_models.dart';
import 'package:Cuplivo/core/services/memory/memory_block_builder.dart';
import 'package:Cuplivo/core/services/memory/memory_prompts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('snapshot json roundtrip', () {
    final snapshot = ContextLogSnapshot(
      timestamp: DateTime.utc(2026, 8, 13, 12, 0, 0),
      conversationId: 'c1',
      assistantName: 'Kelivo',
      provider: 'openai',
      model: 'gpt-4.1',
      messages: [
        ContextLogMessage(
          role: 'system',
          segments: [
            ContextSegment(
              source: ContextSource.systemPrompt,
              text: 'You are helpful.',
              tokens: 5,
            ),
            ContextSegment(
              source: ContextSource.worldBook,
              text: 'Lore',
              tokens: 1,
              meta: {'position': 'AFTER_SYSTEM_PROMPT'},
            ),
          ],
        ),
      ],
      totalTokens: 6,
    );

    final decoded = ContextLogSnapshot.fromJson(snapshot.toJson());
    expect(decoded.conversationId, 'c1');
    expect(decoded.assistantName, 'Kelivo');
    expect(decoded.model, 'gpt-4.1');
    expect(decoded.totalTokens, 6);
    expect(decoded.messages, hasLength(1));
    expect(decoded.messages.first.segments, hasLength(2));
    expect(
      decoded.messages.first.segments.last.meta?['position'],
      'AFTER_SYSTEM_PROMPT',
    );
  });

  test('last tagged segment absorbs content that grew after tagging', () {
    final message = <String, dynamic>{
      'role': 'user',
      'content': 'PREFIX user text with data:image/png;base64,QUJDREVGR0g=',
      kelivoContextSegmentsKey: [
        ContextSegmentTags.item(
          source: ContextSource.memorySnapshot,
          length: 6,
          meta: {'kind': 'full'},
        ),
        ContextSegmentTags.item(source: ContextSource.chatHistory, length: 9),
      ],
    };

    final segments = segmentsFromTaggedMessage(message);
    expect(segments, hasLength(2));
    expect(segments.first.source, ContextSource.memorySnapshot);
    expect(segments.first.text, 'PREFIX');
    expect(segments.last.source, ContextSource.chatHistory);
    expect(segments.last.text, contains('<omitted'));
    expect(segments.last.text, isNot(contains('QUJDREVGR0g=')));
  });

  test('combined frozen snapshot is split from the user turn', () {
    final prefix = MemoryBlockBuilder.buildFullSnapshotPrefix(
      MemoryBlockBuilder.buildProfileBlock(
        fields: const [],
        lang: MemoryPromptLang.zh,
      ),
      MemoryBlockBuilder.buildMemoryBlock(
        visible: const [],
        totalByType: const {},
        lang: MemoryPromptLang.zh,
        maxItems: 10,
      ),
      MemoryPromptLang.zh,
    );
    final message = <String, dynamic>{
      'role': 'user',
      'content': '$prefix用户本轮输入',
      kelivoContextSegmentsKey: [
        ContextSegmentTags.item(
          source: ContextSource.memorySnapshot,
          length: prefix.length + '用户本轮输入'.length,
        ),
      ],
    };

    final segments = segmentsFromTaggedMessage(message);
    expect(segments, hasLength(2));
    expect(segments.first.source, ContextSource.memorySnapshot);
    expect(segments.first.text, prefix);
    expect(segments.last.source, ContextSource.chatHistory);
    expect(segments.last.text, '用户本轮输入');
  });
}
