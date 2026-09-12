import 'package:Cuplivo/core/models/knowledge.dart';
import 'package:Cuplivo/core/services/knowledge/knowledge_prompt_injector.dart';
import 'package:Cuplivo/core/services/knowledge/knowledge_store.dart';
import 'package:flutter_test/flutter_test.dart';

KnowledgeSearchHit _hit({
  required String id,
  required String content,
  String documentName = 'doc.txt',
  double score = -1.0,
}) => KnowledgeSearchHit(
  chunk: KnowledgeChunk(
    id: id,
    documentId: 'd1',
    knowledgeBaseId: 'kb1',
    chunkIndex: 0,
    content: content,
    charCount: content.length,
  ),
  documentName: documentName,
  score: score,
);

void main() {
  test('appends an excerpt block to the latest user message', () {
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': 'sys'},
      {'role': 'user', 'content': 'first'},
      {'role': 'assistant', 'content': 'answer'},
      {'role': 'user', 'content': '脾胃虚弱怎么办'},
    ];

    final injected = KnowledgePromptInjector.inject(
      messages: messages,
      hits: [_hit(id: 'c1', content: '脾胃虚弱者宜温补', documentName: '中医.txt')],
    );

    expect(injected, isTrue);
    expect(messages[0]['content'], 'sys');
    expect(messages[1]['content'], 'first');
    expect(messages[2]['content'], 'answer');
    final last = messages[3]['content'] as String;
    expect(last, startsWith('脾胃虚弱怎么办'));
    expect(last, contains('<knowledge>'));
    expect(last, contains('<excerpt source="中医.txt">'));
    expect(last, contains('脾胃虚弱者宜温补'));
    expect(last, endsWith('</knowledge>'));
  });

  test('escapes XML-significant characters in the source attribute', () {
    final messages = <Map<String, dynamic>>[
      {'role': 'user', 'content': 'q'},
    ];
    KnowledgePromptInjector.inject(
      messages: messages,
      hits: [_hit(id: 'c1', content: 'body', documentName: 'a"b<c>&d')],
    );
    expect(
      messages[0]['content'],
      contains('source="a&quot;b&lt;c&gt;&amp;d"'),
    );
  });

  test('is a no-op without user messages or hits', () {
    final noUser = <Map<String, dynamic>>[
      {'role': 'system', 'content': 'sys'},
    ];
    expect(
      KnowledgePromptInjector.inject(
        messages: noUser,
        hits: [_hit(id: 'c1', content: 'x')],
      ),
      isFalse,
    );
    expect(noUser[0]['content'], 'sys');

    final withUser = <Map<String, dynamic>>[
      {'role': 'user', 'content': 'q'},
    ];
    expect(
      KnowledgePromptInjector.inject(
        messages: withUser,
        hits: const <KnowledgeSearchHit>[],
      ),
      isFalse,
    );
    expect(withUser[0]['content'], 'q');
  });
}
