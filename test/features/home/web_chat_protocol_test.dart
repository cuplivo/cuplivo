import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/home/webview/web_chat_protocol.dart';

void main() {
  test('Web chat uses protocol v4 and bundled assets v18', () {
    expect(webChatProtocolVersion, 4);
    expect(webChatAssetVersion, 'web-chat-v18');
  });

  group('Web streaming patch buffer', () {
    test('keeps only the latest patch and permits one in-flight batch', () {
      final buffer = WebChatStreamingPatchBuffer();

      expect(buffer.enqueue('m', <String, dynamic>{'content': 'a'}), 1);
      expect(buffer.enqueue('m', <String, dynamic>{'content': 'ab'}), 2);
      final first = buffer.takeBatch();
      expect(first, hasLength(1));
      expect(first!.single['content'], 'ab');
      expect(first.single['streamRevision'], 2);
      expect(buffer.takeBatch(), isNull);

      expect(buffer.enqueue('m', <String, dynamic>{'content': 'abc'}), 3);
      expect(buffer.takeBatch(), isNull);
      buffer.completeBatch();
      final second = buffer.takeBatch();
      expect(second!.single['content'], 'abc');
      expect(second.single['streamRevision'], 3);
    });

    test('clear drops pending and revision state', () {
      final buffer = WebChatStreamingPatchBuffer();
      buffer.enqueue('m', <String, dynamic>{'content': 'a'});
      buffer.clear();

      expect(buffer.hasPending, isFalse);
      expect(buffer.enqueue('m', <String, dynamic>{'content': 'b'}), 1);
    });

    test('session clearing does not overlap an existing platform send', () {
      final buffer = WebChatStreamingPatchBuffer();
      buffer.enqueue('old', <String, dynamic>{'content': 'old'});
      expect(buffer.takeBatch(), isNotNull);

      buffer.clear();
      buffer.enqueue('new', <String, dynamic>{'content': 'new'});
      expect(buffer.takeBatch(), isNull);

      buffer.completeBatch();
      final next = buffer.takeBatch();
      expect(next, hasLength(1));
      expect(next!.single['id'], 'new');
      expect(next.single['streamRevision'], 1);
    });
  });

  group('Web snapshot send queue', () {
    test('keeps one in flight and replaces pending with the latest', () {
      final queue = WebChatSnapshotSendQueue();
      queue.enqueue(<String, dynamic>{
        'renderSessionId': 's',
        'conversationId': 'c',
        'renderRevision': 1,
      });
      expect(queue.takeNext()?['renderRevision'], 1);

      queue.enqueue(<String, dynamic>{
        'renderSessionId': 's',
        'conversationId': 'c',
        'renderRevision': 2,
      });
      queue.enqueue(<String, dynamic>{
        'renderSessionId': 's',
        'conversationId': 'c',
        'renderRevision': 3,
      });
      expect(queue.takeNext(), isNull);
      expect(
        queue.acknowledge(
          renderSessionId: 's',
          conversationId: 'c',
          renderRevision: 1,
        ),
        isTrue,
      );
      expect(queue.takeNext()?['renderRevision'], 3);
    });

    test('ignores stale acknowledgements', () {
      final queue = WebChatSnapshotSendQueue()
        ..enqueue(<String, dynamic>{
          'renderSessionId': 'new',
          'conversationId': 'c',
          'renderRevision': 1,
        });
      queue.takeNext();

      expect(
        queue.acknowledge(
          renderSessionId: 'old',
          conversationId: 'c',
          renderRevision: 1,
        ),
        isFalse,
      );
      expect(queue.hasInFlight, isTrue);
    });
  });

  group('Web chat transfer protocol', () {
    test('round-trips a UTF-8 payload across bounded chunks', () {
      final payload = <String, dynamic>{
        'conversationId': '对话-1',
        'content': List<String>.filled(30, '消息内容').join(),
      };

      final chunks = chunkWebChatEnvelope(
        payload: payload,
        transferId: 'transfer-1',
        maxChunkBytes: 31,
      );

      expect(chunks.length, greaterThan(1));
      for (final chunk in chunks) {
        expect(
          utf8.encode(jsonEncode(chunk)).length,
          lessThanOrEqualTo(webChatMaxChunkBytes),
        );
      }
      expect(_reassembleWebChatChunks(chunks), payload);
    });

    test('rejects incomplete transfers', () {
      final chunks = chunkWebChatEnvelope(
        payload: <String, dynamic>{
          'value': List<String>.filled(100, 'x').join(),
        },
        transferId: 'transfer-2',
        maxChunkBytes: 16,
      )..removeLast();

      expect(
        () => _reassembleWebChatChunks(chunks),
        throwsA(isA<WebChatProtocolException>()),
      );
    });
  });

  group('Web chat action gate', () {
    test('accepts once and rejects duplicates and stale epochs', () {
      final gate = WebChatActionGate(
        renderSessionId: 'session',
        conversationId: 'conversation',
        actionEpoch: 4,
      );
      const valid = WebChatActionRequest(
        requestId: 'request',
        renderSessionId: 'session',
        conversationId: 'conversation',
        actionEpoch: 4,
        action: 'copy',
      );

      expect(gate.accept(valid), isTrue);
      expect(gate.accept(valid), isFalse);
      expect(
        gate.accept(
          const WebChatActionRequest(
            requestId: 'other',
            renderSessionId: 'session',
            conversationId: 'conversation',
            actionEpoch: 3,
            action: 'copy',
          ),
        ),
        isFalse,
      );
    });
  });

  group('Web chat reasoning target', () {
    test('parses idempotent single and segmented target states', () {
      final single = WebChatReasoningTarget.fromPayload(<String, dynamic>{
        'kind': 'single',
        'index': 0,
        'expanded': true,
      });
      final segment = WebChatReasoningTarget.fromPayload(<String, dynamic>{
        'kind': 'segment',
        'index': 2,
        'expanded': false,
      });

      expect(single.kind, WebChatReasoningKind.single);
      expect(single.index, 0);
      expect(single.expanded, isTrue);
      expect(segment.kind, WebChatReasoningKind.segment);
      expect(segment.index, 2);
      expect(segment.expanded, isFalse);
    });

    test('rejects local legacy state and malformed indices', () {
      expect(
        () => WebChatReasoningTarget.fromPayload(<String, dynamic>{
          'kind': 'legacy',
          'index': 0,
          'expanded': true,
        }),
        throwsA(isA<WebChatProtocolException>()),
      );
      expect(
        () => WebChatReasoningTarget.fromPayload(<String, dynamic>{
          'kind': 'segment',
          'index': -1,
          'expanded': true,
        }),
        throwsA(isA<WebChatProtocolException>()),
      );
      expect(
        () => WebChatReasoningTarget.fromPayload(<String, dynamic>{
          'kind': 'single',
          'index': 0,
          'expanded': 'yes',
        }),
        throwsA(isA<WebChatProtocolException>()),
      );
      expect(
        () => WebChatReasoningTarget.fromPayload(<String, dynamic>{
          'kind': 'single',
          'index': 1,
          'expanded': true,
        }),
        throwsA(isA<WebChatProtocolException>()),
      );
      expect(
        () => WebChatReasoningTarget.fromPayload(<String, dynamic>{
          'kind': 'segment',
          'index': 1.5,
          'expanded': true,
        }),
        throwsA(isA<WebChatProtocolException>()),
      );
      expect(
        () => WebChatReasoningTarget.fromPayload(<String, dynamic>{
          'kind': 'segment',
          'index': double.nan,
          'expanded': true,
        }),
        throwsA(isA<WebChatProtocolException>()),
      );
    });
  });
}

Map<String, dynamic> _reassembleWebChatChunks(
  List<Map<String, dynamic>> chunks,
) {
  if (chunks.isEmpty) {
    throw const WebChatProtocolException('missing chunks');
  }
  final ordered = List<Map<String, dynamic>>.of(chunks)
    ..sort(
      (left, right) => (left['index'] as num).toInt().compareTo(
        (right['index'] as num).toInt(),
      ),
    );
  final total = (ordered.first['total'] as num).toInt();
  if (ordered.length != total ||
      ordered.indexed.any(
        (entry) =>
            (entry.$2['index'] as num).toInt() != entry.$1 ||
            (entry.$2['total'] as num).toInt() != total,
      )) {
    throw const WebChatProtocolException('incomplete transfer');
  }
  final bytes = <int>[
    for (final chunk in ordered) ...base64Decode(chunk['data'] as String),
  ];
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map) {
    throw const WebChatProtocolException('invalid transfer payload');
  }
  return decoded.map((key, value) => MapEntry(key.toString(), value));
}
