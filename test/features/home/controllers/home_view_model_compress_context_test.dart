import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/core/utils/token_estimator.dart';
import 'package:Cuplivo/features/home/controllers/home_view_model.dart';
import 'package:Cuplivo/utils/mcp_structured_image.dart';

ChatMessage _message({
  required String id,
  required String role,
  required String content,
  String? groupId,
  int version = 0,
}) {
  return ChatMessage(
    id: id,
    role: role,
    content: content,
    conversationId: 'conversation-1',
    groupId: groupId ?? id,
    version: version,
  );
}

void main() {
  group('buildCompressContextContent', () {
    test('短内容在限制内保持原样', () {
      const joined = 'User: hello\n\nAssistant: hi';

      expect(
        buildCompressContextContent(
          joined,
          const CompressContextOptions(
            mode: CompressContextLimitMode.start,
            maxChars: 6000,
          ),
        ),
        joined,
      );
    });

    test('超长内容可保留开头', () {
      final early = 'User: first round\n\nAssistant: early answer\n\n';
      final middle = 'x' * 6000;
      final latest = '\n\nUser: thirtieth round\n\nAssistant: latest answer';
      final joined = '$early$middle$latest';

      final content = buildCompressContextContent(
        joined,
        const CompressContextOptions(
          mode: CompressContextLimitMode.start,
          maxChars: 6000,
        ),
      );

      expect(content.length, 6000);
      expect(content, contains('first round'));
      expect(content, isNot(contains('thirtieth round')));
    });

    test('超长内容可保留最近尾部', () {
      final early = 'User: first round\n\nAssistant: early answer\n\n';
      final middle = 'x' * 6000;
      final latest = '\n\nUser: thirtieth round\n\nAssistant: latest answer';
      final joined = '$early$middle$latest';

      final content = buildCompressContextContent(
        joined,
        const CompressContextOptions(
          mode: CompressContextLimitMode.recent,
          maxChars: 6000,
        ),
      );

      expect(content.length, 6000);
      expect(content, isNot(contains('first round')));
      expect(content, contains('thirtieth round'));
    });

    test('无限制保留完整内容', () {
      final joined = 'a' * 7000;

      final content = buildCompressContextContent(
        joined,
        const CompressContextOptions(mode: CompressContextLimitMode.unlimited),
      );

      expect(content, joined);
    });

    test('keepRecent 直通原文，不按字符窗截断', () {
      final joined = 'a' * 7000;

      final content = buildCompressContextContent(
        joined,
        const CompressContextOptions(
          mode: CompressContextLimitMode.keepRecent,
          keepUserMessages: 2,
        ),
      );

      expect(content, joined);
    });

    test('截断不劈开 emoji 代理对', () {
      // '😀' occupies two UTF-16 code units. A raw cut at 4 would tear it.
      const joined = 'abc😀def';

      final start = buildCompressContextContent(
        joined,
        const CompressContextOptions(
          mode: CompressContextLimitMode.start,
          maxChars: 4,
        ),
      );
      expect(start, 'abc');
      expect(() => jsonEncode(start), returnsNormally);

      final recent = buildCompressContextContent(
        joined,
        const CompressContextOptions(
          mode: CompressContextLimitMode.recent,
          maxChars: 4,
        ),
      );
      expect(recent, 'def');
      expect(() => jsonEncode(recent), returnsNormally);
    });
  });

  group('compressWeightTextForMessage', () {
    test('无工具调用时等于消息正文', () {
      final message = _message(id: 'a1', role: 'assistant', content: 'answer');

      expect(
        compressWeightTextForMessage(message, toolEvents: const []),
        'answer',
      );
    });

    test('带上工具调用的名字、参数与结果', () {
      final message = _message(id: 'a1', role: 'assistant', content: 'answer');

      final text = compressWeightTextForMessage(
        message,
        toolEvents: const [
          {
            'name': 'read_file',
            'arguments': {'path': 'lib/main.dart'},
            'content': 'void main() {}',
          },
        ],
      );

      expect(text, startsWith('answer'));
      expect(text, contains('[read_file]'));
      expect(text, contains('{"path":"lib/main.dart"}'));
      expect(text, contains('void main() {}'));
    });

    test('工具结果为空时只留名字', () {
      final text = compressWeightTextForMessage(
        _message(id: 'a1', role: 'assistant', content: ''),
        toolEvents: const [
          {'name': 'noop', 'content': '   '},
        ],
      );

      expect(text.trim(), '[noop]');
    });

    test('参数是未解析的字符串时照样计入', () {
      final text = compressWeightTextForMessage(
        _message(id: 'a1', role: 'assistant', content: ''),
        toolEvents: const [
          {'name': 'read_file', 'arguments': '{"path":"lib/main.dar'},
        ],
      );

      expect(text, contains('{"path":"lib/main.dar'));
    });

    test('typed 图片的结果行按模型所见剥离，只留文本', () {
      final text = compressWeightTextForMessage(
        _message(id: 'a1', role: 'assistant', content: ''),
        toolEvents: const [
          {
            'name': 'view_image',
            'content': 'Image (1024 x 768).\n![](/images/x.png)',
            'metadata': {
              'mcpResult': {
                'version': 1,
                'imageUris': ['/images/x.png'],
              },
            },
          },
        ],
      );

      expect(text, contains('Image (1024 x 768).'));
      expect(text, isNot(contains('![](')));
    });
  });

  group('compressWeightImageCountForMessage', () {
    test('附件图片计入，不可用与空 uri 不计', () {
      final message = ChatMessage(
        id: 'u1',
        role: 'user',
        parts: const [
          ImagePart(uri: '/images/a.png'),
          ImagePart(uri: '/images/b.png', unavailable: true),
          ImagePart(uri: '   '),
        ],
        conversationId: 'conversation-1',
      );

      expect(
        compressWeightImageCountForMessage(message, toolEvents: const []),
        1,
      );
    });

    test('只认 metadata.mcpResult 的 typed 图片', () {
      final message = _message(id: 'a1', role: 'assistant', content: 'done');

      expect(
        compressWeightImageCountForMessage(
          message,
          toolEvents: const [
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
        ),
        2,
      );
      // 同样的 markdown 行，但没有 typed metadata：路径只是文本。
      expect(
        compressWeightImageCountForMessage(
          message,
          toolEvents: const [
            {
              'name': 'mcp_search',
              'content': 'found:\n![](https://example.test/a.png)',
            },
          ],
        ),
        0,
      );
    });

    test('legacy envelope 的 imageUris 不会送到模型，不计图片', () {
      final message = _message(id: 'a1', role: 'assistant', content: 'done');
      final legacy = encodeLegacyMcpToolResultEnvelope(
        text: 'ok',
        imageUris: ['/images/y.png'],
      );

      expect(
        compressWeightImageCountForMessage(
          message,
          toolEvents: [
            {'name': 'mcp_tool', 'content': legacy},
          ],
        ),
        0,
      );
    });
  });

  group('HomeViewModel.computeClearContextRemainingMessageCount', () {
    test('计数来自持久化总数，与窗口缓存无关', () {
      final count = HomeViewModel.computeClearContextRemainingMessageCount(
        totalMessages: 100,
        truncateIndex: -1,
      );

      expect(count, 100);
    });

    test('已有清空点时从持久化截断位置开始计数', () {
      final count = HomeViewModel.computeClearContextRemainingMessageCount(
        totalMessages: 100,
        truncateIndex: 90,
      );

      expect(count, 10);
    });

    test('截断位置越界时按未清空处理', () {
      final beyond = HomeViewModel.computeClearContextRemainingMessageCount(
        totalMessages: 100,
        truncateIndex: 101,
      );
      final atEnd = HomeViewModel.computeClearContextRemainingMessageCount(
        totalMessages: 100,
        truncateIndex: 100,
      );

      expect(beyond, 100);
      expect(atEnd, 0);
    });
  });

  group('selectKeepRecentMessages', () {
    test('保留最近 N 条用户消息及其后的全部消息，边界以用户消息开始', () {
      final messages = <ChatMessage>[
        _message(id: 'u1', role: 'user', content: 'q1'),
        _message(id: 'a1', role: 'assistant', content: 'a1'),
        _message(id: 'u2', role: 'user', content: 'q2'),
        _message(id: 'a2', role: 'assistant', content: 'a2'),
        _message(id: 'u3', role: 'user', content: 'q3'),
        _message(id: 'a3', role: 'assistant', content: 'a3'),
      ];

      final kept = selectKeepRecentMessages(messages, 2);

      expect(kept.map((m) => m.id).toList(), ['u2', 'a2', 'u3', 'a3']);
    });

    test('保留区可包含未答复的尾部用户消息', () {
      final messages = <ChatMessage>[
        _message(id: 'u1', role: 'user', content: 'q1'),
        _message(id: 'a1', role: 'assistant', content: 'a1'),
        _message(id: 'u2', role: 'user', content: 'q2'),
      ];

      final kept = selectKeepRecentMessages(messages, 1);

      expect(kept.map((m) => m.id).toList(), ['u2']);
    });

    test('N 覆盖全部用户消息时返回完整列表（无可压缩内容）', () {
      final messages = <ChatMessage>[
        _message(id: 'u1', role: 'user', content: 'q1'),
        _message(id: 'a1', role: 'assistant', content: 'a1'),
        _message(id: 'u2', role: 'user', content: 'q2'),
      ];

      final kept = selectKeepRecentMessages(messages, 3);

      expect(kept.length, messages.length);
    });

    test('空内容的用户消息不参与计数', () {
      final messages = <ChatMessage>[
        _message(id: 'u1', role: 'user', content: 'q1'),
        _message(id: 'a1', role: 'assistant', content: 'a1'),
        _message(id: 'u2', role: 'user', content: '   '),
        _message(id: 'u3', role: 'user', content: 'q3'),
        _message(id: 'a3', role: 'assistant', content: 'a3'),
      ];

      final kept = selectKeepRecentMessages(messages, 1);

      expect(kept.map((m) => m.id).toList(), ['u3', 'a3']);
    });

    test('保留区内的空内容助手消息（纯工具调用）严格保留为空气泡', () {
      final messages = <ChatMessage>[
        _message(id: 'u1', role: 'user', content: 'q1'),
        _message(id: 'a1', role: 'assistant', content: ''),
        _message(id: 'u2', role: 'user', content: 'q2'),
        _message(id: 'a2', role: 'assistant', content: ''),
      ];

      final kept = selectKeepRecentMessages(messages, 1);

      expect(kept.map((m) => m.id).toList(), ['u2', 'a2']);
    });

    test('空输入 / 无 user / N ≤ 0 返回空', () {
      expect(
        selectKeepRecentMessages([
          _message(id: 'a1', role: 'assistant', content: 'a1'),
        ], 1),
        isEmpty,
      );
      expect(selectKeepRecentMessages(const [], 1), isEmpty);

      final messages = [
        _message(id: 'u1', role: 'user', content: 'q1'),
        _message(id: 'a1', role: 'assistant', content: 'a1'),
      ];
      expect(selectKeepRecentMessages(messages, 0), isEmpty);
      expect(selectKeepRecentMessages(messages, -1), isEmpty);
    });
  });

  group('countUserMessages', () {
    test('只统计内容非空的用户消息', () {
      final messages = <ChatMessage>[
        _message(id: 'u1', role: 'user', content: 'q1'),
        _message(id: 'a1', role: 'assistant', content: 'a1'),
        _message(id: 'u2', role: 'user', content: '   '),
        _message(id: 'u3', role: 'user', content: 'q3'),
      ];

      expect(countUserMessages(messages), 2);
    });
  });

  group('defaultKeepUserMessageCountFor', () {
    test('少于 5 条用户消息时默认 1', () {
      expect(defaultKeepUserMessageCountFor(0), 1);
      expect(defaultKeepUserMessageCountFor(1), 1);
      expect(defaultKeepUserMessageCountFor(2), 1);
      expect(defaultKeepUserMessageCountFor(4), 1);
    });

    test('5-9 条用户消息时默认 2', () {
      expect(defaultKeepUserMessageCountFor(5), 2);
      expect(defaultKeepUserMessageCountFor(9), 2);
    });

    test('10 条及以上用户消息时默认 3', () {
      expect(defaultKeepUserMessageCountFor(10), 3);
      expect(defaultKeepUserMessageCountFor(100), 3);
    });
  });

  group('CompressContextWeights.splitAt', () {
    test('模型口径切 token，摘要区间底数取正文列', () {
      final weights = CompressContextWeights(
        modelTokens: const [100, 200, 300, 400],
        summaryInputTokens: const [10, 20, 30, 40],
      );

      final split = weights.splitAt(2);

      expect(split.totalTokens, 1000);
      expect(split.keptTokens, 700);
      expect(split.summaryInputTokens, 30);
    });

    test('下标为 0 / 越界的边界', () {
      final weights = CompressContextWeights(
        modelTokens: const [10, 20],
        summaryInputTokens: const [1, 2],
      );

      expect(weights.splitAt(0).keptTokens, 30);
      expect(weights.splitAt(0).summaryInputTokens, 0);
      expect(weights.splitAt(9).keptTokens, 0);
      expect(weights.splitAt(9).summaryInputTokens, 3);
    });

    test('空列表得到全零', () {
      final split = const CompressContextWeights(
        modelTokens: [],
        summaryInputTokens: [],
      ).splitAt(0);

      expect(split.totalTokens, 0);
      expect(split.keptTokens, 0);
      expect(split.summaryInputTokens, 0);
      expect(split.reductionPercent, 0);
    });

    test('两列长度不一致时断言失败', () {
      final weights = CompressContextWeights(
        modelTokens: const [10],
        summaryInputTokens: const [1, 2],
      );

      expect(() => weights.splitAt(1), throwsA(isA<AssertionError>()));
    });
  });

  group('CompressContextSplit', () {
    test('结果区间 = 保留段 + 被总结段正文 token 的 10%–30%', () {
      const split = CompressContextSplit(
        totalTokens: 1000,
        keptTokens: 400,
        summaryInputTokens: 600,
      );

      expect(split.minResultTokens, 460);
      expect(split.maxResultTokens, 580);
      expect(split.midResultTokens, 520);
      expect(split.reductionPercent, 48);
    });

    test('含工具的总量不做底数：区间只随正文列走', () {
      const split = CompressContextSplit(
        totalTokens: 1000,
        keptTokens: 400,
        summaryInputTokens: 100,
      );

      expect(split.minResultTokens, 410);
      expect(split.maxResultTokens, 430);
      expect(split.midResultTokens, 420);
      expect(split.reductionPercent, 58);
    });

    test('无可压缩内容时降幅为 0', () {
      const split = CompressContextSplit(
        totalTokens: 500,
        keptTokens: 500,
        summaryInputTokens: 0,
      );

      expect(split.reductionPercent, 0);
    });
  });

  group('CompressContextWeights.tokensFromChars', () {
    test('按保守比值回退', () {
      expect(CompressContextWeights.tokensFromChars(const [16, 0, 7]), [
        10,
        0,
        5,
      ]);
    });

    test('非法比值退回默认常量', () {
      expect(
        CompressContextWeights.tokensFromChars(const [8], charsPerToken: 0),
        [5],
      );
    });
  });

  group('读数按 token 而不是字符', () {
    test('中文头部 + 密集 ASCII 尾部：token 比例 ≠ 字符比例', () {
      final head = _message(id: 'u1', role: 'user', content: '汉' * 115);
      final tail = _message(id: 'a1', role: 'assistant', content: 'a' * 700);

      // tokenx: 115 个汉字 ≈ 100 token，700 个小写字母 ≈ 100 token。
      final weights = CompressContextWeights(
        modelTokens: [
          estimateTokens(head.content),
          estimateTokens(tail.content),
        ],
        summaryInputTokens: [
          estimateTokens(conversationLineForCompression(head) ?? ''),
          estimateTokens(conversationLineForCompression(tail) ?? ''),
        ],
      );
      final split = weights.splitAt(1);
      final charKeptShare =
          tail.content.length / (head.content.length + tail.content.length);
      final tokenKeptShare = split.keptTokens / split.totalTokens;

      expect(tokenKeptShare, isNot(closeTo(charKeptShare, 0.1)));
      expect(split.keptTokens, estimateTokens(tail.content));
    });
  });

  group('keepRecentStartIndex', () {
    test('从倒数第 N 条用户消息开始', () {
      final messages = <ChatMessage>[
        _message(id: 'u1', role: 'user', content: 'q1'),
        _message(id: 'a1', role: 'assistant', content: 'a1'),
        _message(id: 'u2', role: 'user', content: 'q2'),
        _message(id: 'a2', role: 'assistant', content: 'a2'),
        _message(id: 'u3', role: 'user', content: 'q3'),
      ];

      expect(keepRecentStartIndex(messages, 1), 4);
      expect(keepRecentStartIndex(messages, 2), 2);
      expect(keepRecentStartIndex(messages, 3), 0);
    });

    test('覆盖全部 / 无用户消息 / N ≤ 0', () {
      final messages = <ChatMessage>[
        _message(id: 'a0', role: 'assistant', content: 'leading'),
        _message(id: 'u1', role: 'user', content: 'q1'),
        _message(id: 'a1', role: 'assistant', content: 'a1'),
      ];

      expect(keepRecentStartIndex(messages, 5), 0);
      expect(keepRecentStartIndex(messages, 0), isNull);
      expect(keepRecentStartIndex(messages, -1), isNull);
      expect(
        keepRecentStartIndex([
          _message(id: 'a1', role: 'assistant', content: 'a1'),
        ], 1),
        isNull,
      );
      expect(keepRecentStartIndex(const [], 1), isNull);
    });

    test('与 selectKeepRecentMessages 保持同一套边界', () {
      final messages = <ChatMessage>[
        _message(id: 'a0', role: 'assistant', content: 'leading'),
        _message(id: 'u1', role: 'user', content: 'q1'),
        _message(id: 'a1', role: 'assistant', content: 'a1'),
        _message(id: 'u2', role: 'user', content: 'q2'),
        _message(id: 'a2', role: 'assistant', content: 'a2'),
      ];

      for (final keep in [0, 1, 2, 3, 5]) {
        final start = keepRecentStartIndex(messages, keep);
        final kept = selectKeepRecentMessages(messages, keep);
        expect(
          kept.length,
          start == null ? 0 : messages.length - start,
          reason: 'keep=$keep',
        );
        if (start != null && start > 0) {
          expect(kept.first.id, messages[start].id, reason: 'keep=$keep');
        }
      }
    });
  });

  group('buildBoundedConversationText', () {
    test('start 与先拼接再截断在常规长度上语义一致', () {
      final messages = [
        _message(id: 'u1', role: 'user', content: 'first round'),
        _message(id: 'a1', role: 'assistant', content: 'early answer'),
        _message(id: 'u2', role: 'user', content: 'x' * 7000),
        _message(id: 'a2', role: 'assistant', content: 'thirtieth round'),
      ];
      const options = CompressContextOptions(
        mode: CompressContextLimitMode.start,
        maxChars: 6000,
      );
      // The joined reference the incremental window must agree with: roles plus
      // bodies, blank-content messages dropped.
      final joined = messages
          .map(conversationLineForCompression)
          .whereType<String>()
          .join('\n\n');

      expect(
        buildBoundedConversationText(
          messages,
          mode: CompressContextLimitMode.start,
          maxChars: 6000,
        ),
        buildCompressContextContent(joined, options),
      );
    });

    test('recent 与先拼接再截断在常规长度上语义一致', () {
      final messages = [
        _message(id: 'u1', role: 'user', content: 'first round'),
        _message(id: 'a1', role: 'assistant', content: 'early answer'),
        _message(id: 'u2', role: 'user', content: 'x' * 7000),
        _message(id: 'a2', role: 'assistant', content: 'thirtieth round'),
      ];
      const options = CompressContextOptions(
        mode: CompressContextLimitMode.recent,
        maxChars: 6000,
      );
      // The joined reference the incremental window must agree with: roles plus
      // bodies, blank-content messages dropped.
      final joined = messages
          .map(conversationLineForCompression)
          .whereType<String>()
          .join('\n\n');

      expect(
        buildBoundedConversationText(
          messages,
          mode: CompressContextLimitMode.recent,
          maxChars: 6000,
        ),
        buildCompressContextContent(joined, options),
      );
    });

    test('超长历史增量截断且不超过窗口，无需先拼接全文', () {
      final messages = [
        for (var i = 0; i < 200; i++)
          _message(
            id: 'm$i',
            role: i.isEven ? 'user' : 'assistant',
            content: 'block-$i ${'x' * 500}',
          ),
      ];

      final start = buildBoundedConversationText(
        messages,
        mode: CompressContextLimitMode.start,
        maxChars: 6000,
      );
      expect(start.length, lessThanOrEqualTo(6000));
      expect(start, contains('block-0'));
      expect(start, isNot(contains('block-199')));

      final recent = buildBoundedConversationText(
        messages,
        mode: CompressContextLimitMode.recent,
        maxChars: 6000,
      );
      expect(recent.length, lessThanOrEqualTo(6000));
      expect(recent, contains('block-199'));
      expect(recent, isNot(contains('block-0')));
    });
  });

  group('chunkMessagesForCompression', () {
    test('超过预算的多条消息按消息边界拆成多块', () {
      final messages = [
        _message(id: 'u1', role: 'user', content: 'aaa'),
        _message(id: 'a1', role: 'assistant', content: 'bbb'),
        _message(id: 'u2', role: 'user', content: 'ccc'),
      ];

      final chunks = chunkMessagesForCompression(messages, maxChars: 20);

      expect(chunks, hasLength(greaterThan(1)));
      expect(chunks.every((chunk) => chunk.length <= 20), isTrue);
      expect(chunks.join('\n\n'), contains('User: aaa'));
      expect(chunks.join('\n\n'), contains('User: ccc'));
    });

    test('单条超长消息按 UTF-16 安全切分且不劈开 emoji', () {
      const emoji = '😀';
      final messages = [
        _message(id: 'u1', role: 'user', content: 'aa$emoji${'b' * 30}'),
      ];
      final line = conversationLineForCompression(messages.single)!;

      final chunks = chunkMessagesForCompression(messages, maxChars: 9);

      expect(chunks, hasLength(greaterThan(1)));
      expect(chunks.join(), line);
      expect(chunks.join(), contains(emoji));
      for (final chunk in chunks) {
        expect(() => jsonEncode(chunk), returnsNormally);
      }
    });
  });

  group('buildCompressRequestContents', () {
    test('unlimited 超过安全上限时按消息边界分块且不丢内容', () {
      final messages = [
        for (var i = 0; i < 5; i++)
          _message(id: 'u$i', role: 'user', content: 'msg-$i ${'x' * 40}'),
      ];

      final chunks = buildCompressRequestContents(
        messages,
        const CompressContextOptions(mode: CompressContextLimitMode.unlimited),
        safeRequestChars: 50,
      );

      expect(chunks, hasLength(greaterThan(1)));
      expect(chunks.every((chunk) => chunk.length <= 50), isTrue);
      expect(chunks.join('\n\n'), contains('msg-0'));
      expect(chunks.join('\n\n'), contains('msg-4'));
    });

    test('keepRecent 旧侧同样受安全上限约束', () {
      final messages = [
        for (var i = 0; i < 4; i++)
          _message(id: 'u$i', role: 'user', content: 'old-$i ${'y' * 40}'),
      ];

      final chunks = buildCompressRequestContents(
        messages,
        const CompressContextOptions(
          mode: CompressContextLimitMode.keepRecent,
          keepUserMessages: 1,
        ),
        safeRequestChars: 50,
      );

      expect(chunks, hasLength(greaterThan(1)));
      expect(chunks.join('\n\n'), contains('old-0'));
    });
  });

  group('compressRequestCharBudget', () {
    test('unknown context uses the conservative 32k default', () {
      expect(compressRequestCharBudget(), 35840);
      expect(compressRequestCharBudget(contextWindowTokens: 0), 35840);
      expect(compressRequestCharBudget(contextWindowTokens: -1), 35840);
    });

    test('32k window stays at window-minus-reserves', () {
      const window = 32000;
      final budget = compressRequestCharBudget(contextWindowTokens: window);
      final maxInputTokens =
          (window * (1 - CompressContextOptions.contextReserveFraction))
              .floor();

      expect(budget, 35840);
      expect(budget, lessThan(window * CompressContextOptions.charsPerToken));
      expect(
        (budget / CompressContextOptions.charsPerToken).ceil(),
        lessThanOrEqualTo(maxInputTokens),
      );
    });

    test('128k+ is larger than the 32k default but still hard-capped', () {
      final budget128k = compressRequestCharBudget(contextWindowTokens: 128000);
      final budget1m = compressRequestCharBudget(contextWindowTokens: 1000000);

      expect(budget128k, greaterThan(compressRequestCharBudget()));
      expect(budget128k, CompressContextOptions.safeRequestChars);
      expect(budget1m, CompressContextOptions.safeRequestChars);
      expect(
        budget128k,
        lessThanOrEqualTo(CompressContextOptions.safeRequestChars),
      );
    });
  });

  group('resolveCompressContextModel', () {
    test('优先使用显式压缩模型', () {
      final resolved = resolveCompressContextModel(
        compressProvider: 'OpenAI',
        compressModelId: 'gpt-4o-mini',
        summaryProvider: 'Gemini',
        summaryModelId: 'gemini-2.5-flash',
        currentProvider: 'DeepSeek',
        currentModelId: 'deepseek-chat',
      );

      expect(resolved.providerKey, 'OpenAI');
      expect(resolved.modelId, 'gpt-4o-mini');
    });

    test('未设置压缩模型时按 summary → title → assistant → current 回退', () {
      expect(
        resolveCompressContextModel(
          summaryProvider: 'Gemini',
          summaryModelId: 'gemini-2.5-flash',
          titleProvider: 'OpenAI',
          titleModelId: 'gpt-4o-mini',
          currentProvider: 'DeepSeek',
          currentModelId: 'deepseek-chat',
        ),
        (providerKey: 'Gemini', modelId: 'gemini-2.5-flash'),
      );
      expect(
        resolveCompressContextModel(
          titleProvider: 'OpenAI',
          titleModelId: 'gpt-4o-mini',
          assistantProvider: 'Claude',
          assistantModelId: 'claude-sonnet',
          currentProvider: 'DeepSeek',
          currentModelId: 'deepseek-chat',
        ),
        (providerKey: 'OpenAI', modelId: 'gpt-4o-mini'),
      );
      expect(
        resolveCompressContextModel(
          assistantProvider: 'Claude',
          assistantModelId: 'claude-sonnet',
          currentProvider: 'DeepSeek',
          currentModelId: 'deepseek-chat',
        ),
        (providerKey: 'Claude', modelId: 'claude-sonnet'),
      );
      expect(
        resolveCompressContextModel(
          currentProvider: 'DeepSeek',
          currentModelId: 'deepseek-chat',
        ),
        (providerKey: 'DeepSeek', modelId: 'deepseek-chat'),
      );
    });

    test('全部未设置时返回空', () {
      final resolved = resolveCompressContextModel();

      expect(resolved.providerKey, isNull);
      expect(resolved.modelId, isNull);
    });
  });

  group('isContextLengthError', () {
    test('matches likely input-token overflow phrases', () {
      const overflowing = <String>[
        'HTTP 400: context_length_exceeded',
        "This model's maximum context length is 8192 tokens",
        'The request exceeds the context window',
        'max context size exceeded',
        'too many tokens in the prompt',
        'prompt is too long: 40000 tokens > 32000 maximum',
        'prompt too long',
        'input is too long',
        'input too long for this model',
        'Please reduce the length of the messages',
        'Please reduce the length of the prompt',
        'The input token count exceeds the maximum number of tokens allowed',
        'HttpException: max_tokens exceeded for this request',
      ];
      for (final message in overflowing) {
        expect(
          isContextLengthError(Exception(message)),
          isTrue,
          reason: message,
        );
      }
    });

    test('does not match unrelated or max_tokens config errors', () {
      const unrelated = <String>[
        '401 unauthorized',
        'rate limit exceeded',
        'empty_summary',
        'max_tokens is required',
        'max_tokens must be at least 1',
        'invalid api key',
        'network timeout',
      ];
      for (final message in unrelated) {
        expect(
          isContextLengthError(Exception(message)),
          isFalse,
          reason: message,
        );
      }
    });
  });

  group('summarizeWithContextRetry', () {
    test('splits on a context error, retries each half, then merges', () async {
      final calls = <String>[];
      final result = await summarizeWithContextRetry(
        'A' * 32,
        minSplitChars: 4,
        summarize: (text) async {
          calls.add(text);
          if (text.contains('A') && text.length > 16) {
            throw Exception('maximum context length exceeded');
          }
          if (text.contains('S:')) return 'M';
          return 'S:${text.length}';
        },
      );

      expect(calls, ['A' * 32, 'A' * 16, 'A' * 16, 'S:16\n\nS:16']);
      expect(result, 'M');
    });

    test('UTF-16 halves stay valid when naive mid would tear a pair', () async {
      final text = 'x${'😀' * 20}';
      expect(text.length ~/ 2, 20);
      final naive = text.substring(0, text.length ~/ 2);
      final naiveLast = naive.codeUnitAt(naive.length - 1);
      expect(naiveLast >= 0xD800 && naiveLast <= 0xDBFF, isTrue);

      final seen = <String>[];
      final result = await summarizeWithContextRetry(
        text,
        minSplitChars: 4,
        summarize: (chunk) async {
          seen.add(chunk);
          _expectValidUtf16(chunk);
          if (chunk == text) {
            throw Exception('context_length_exceeded');
          }
          return 'ok';
        },
      );

      expect(seen.length, 4);
      expect(seen.first, text);
      expect('${seen[1]}${seen[2]}', text);
      expect(result, 'ok');
    });

    test('does not split-retry non-context errors', () async {
      var calls = 0;
      await expectLater(
        summarizeWithContextRetry(
          'A' * 32,
          minSplitChars: 4,
          summarize: (text) async {
            calls++;
            throw Exception('401 unauthorized');
          },
        ),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'toString',
            contains('401 unauthorized'),
          ),
        ),
      );
      expect(calls, 1);
    });

    test('stops after the split budget instead of looping', () async {
      var calls = 0;
      var splits = 0;
      await expectLater(
        summarizeWithContextRetry(
          'A' * 32,
          maxSplits: 2,
          minSplitChars: 4,
          onSplitRetry: (e, st, text) => splits++,
          summarize: (text) async {
            calls++;
            throw Exception('prompt is too long');
          },
        ),
        throwsA(isA<Exception>()),
      );
      expect(splits, 2);
      expect(calls, 3);
    });

    test('does not split when a half would be below minSplitChars', () async {
      var calls = 0;
      await expectLater(
        summarizeWithContextRetry(
          'A' * 20,
          minSplitChars: 16,
          summarize: (text) async {
            calls++;
            throw Exception('too many tokens');
          },
        ),
        throwsA(isA<Exception>()),
      );
      expect(calls, 1);
    });
  });
}

void _expectValidUtf16(String value) {
  for (var i = 0; i < value.length; i++) {
    final codeUnit = value.codeUnitAt(i);
    if (codeUnit >= 0xD800 && codeUnit <= 0xDBFF) {
      expect(
        i + 1 < value.length &&
            value.codeUnitAt(i + 1) >= 0xDC00 &&
            value.codeUnitAt(i + 1) <= 0xDFFF,
        isTrue,
        reason: 'lone high surrogate at $i',
      );
      i++;
    } else if (codeUnit >= 0xDC00 && codeUnit <= 0xDFFF) {
      fail('lone low surrogate at $i');
    }
  }
}
