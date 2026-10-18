import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/core/utils/token_estimator.dart';
import 'package:Cuplivo/features/home/controllers/home_view_model.dart';
import 'package:Cuplivo/features/home/services/compress_context_estimate.dart';

ChatMessage _message(String id, String role, String content) => ChatMessage(
  id: id,
  role: role,
  content: content,
  conversationId: 'conversation-1',
  groupId: id,
);

Future<CompressContextWeights> _weigh(
  List<ChatMessage> messages,
  Map<String, List<Map<String, dynamic>>> events,
) {
  return estimateCompressContextWeights(
    messages: messages,
    toolEventsFor: (message) => events[message.id] ?? const [],
  );
}

void main() {
  test('工具负载计入模型口径，但不进摘要区间底数', () async {
    final messages = <ChatMessage>[
      _message('u1', 'user', 'a' * 400),
      _message('a1', 'assistant', 'b' * 400),
      _message('u2', 'user', 'c' * 400),
      _message('a2', 'assistant', 'd' * 400),
    ];
    final events = {
      'a1': [
        {
          'name': 'read_file',
          'arguments': {'path': 'lib/main.dart'},
          'content': 'z' * 4000,
        },
      ],
    };

    final weights = await _weigh(messages, events);
    final start = keepRecentStartIndex(messages, 1)!;
    final split = weights.splitAt(start);

    // 工具负载只在模型口径里：头部的模型量明显大于摘要模型的输入量。
    expect(
      split.totalTokens - split.keptTokens,
      greaterThan(split.summaryInputTokens),
    );
    expect(
      split.summaryInputTokens,
      estimateTokens(conversationLineForCompression(messages[0])!) +
          estimateTokens(conversationLineForCompression(messages[1])!),
    );
    expect(
      split.minResultTokens,
      split.keptTokens + (split.summaryInputTokens * 0.10).round(),
    );
    expect(
      split.maxResultTokens,
      split.keptTokens + (split.summaryInputTokens * 0.30).round(),
    );
  });

  test('纯正文会话：摘要底数只在角色前缀上高出模型口径', () async {
    final messages = <ChatMessage>[
      _message('u1', 'user', 'a' * 400),
      _message('a1', 'assistant', 'b' * 400),
      _message('u2', 'user', 'c' * 400),
      _message('a2', 'assistant', 'd' * 400),
    ];

    final weights = await _weigh(messages, const {});
    final split = weights.splitAt(keepRecentStartIndex(messages, 1)!);
    final modelHead = split.totalTokens - split.keptTokens;

    // 模型列计原始正文，摘要列计带 `User: ` / `Assistant: ` 的整行，所以没有
    // 工具负载时两者只差前缀（消息数 × 几个 token）。
    expect(split.summaryInputTokens, greaterThanOrEqualTo(modelHead));
    expect(split.summaryInputTokens - modelHead, lessThan(10));
    expect(split.reductionPercent, greaterThan(0));
  });

  test('图片用户消息不再计 0：按未知尺寸的占位计', () async {
    final messages = <ChatMessage>[
      ChatMessage(
        id: 'u1',
        role: 'user',
        parts: const [ImagePart(uri: '/images/shot.png')],
        conversationId: 'conversation-1',
      ),
      _message('a1', 'assistant', '看完了'),
    ];

    final weights = await _weigh(messages, const {});

    expect(weights.modelTokens.first, kUnknownImageTokens);
    // 摘要模型读不到图片，正文列为 0（该消息没有正文行）。
    expect(weights.summaryInputTokens.first, 0);
    expect(weights.modelTokens.last, estimateTokens('看完了'));
  });

  test('typed 工具图片按张计入模型口径', () async {
    final message = _message('a1', 'assistant', 'done');
    final events = {
      'a1': [
        {
          'name': 'view_image',
          'content': 'Image (1024 x 768).\n![](/images/x.png)',
          'metadata': {
            'mcpResult': {
              'version': 1,
              'imageUris': ['/images/x.png', '/images/y.png'],
            },
          },
        },
      ],
    };

    final weights = await _weigh([message], events);

    expect(
      weights.modelTokens.single,
      estimateTokens(
            compressWeightTextForMessage(message, toolEvents: events['a1']!),
          ) +
          2 * kUnknownImageTokens,
    );
    expect(
      weights.summaryInputTokens.single,
      estimateTokens(conversationLineForCompression(message)!),
    );
  });
}
