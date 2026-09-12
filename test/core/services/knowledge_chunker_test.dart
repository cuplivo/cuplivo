import 'package:Cuplivo/core/services/knowledge/knowledge_chunker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('empty and whitespace-only input yields no chunks', () {
    expect(KnowledgeChunker.chunk('', chunkSize: 64, chunkOverlap: 8), isEmpty);
    expect(
      KnowledgeChunker.chunk('  \n\t  ', chunkSize: 64, chunkOverlap: 8),
      isEmpty,
    );
  });

  test('short text is a single trimmed chunk', () {
    expect(
      KnowledgeChunker.chunk('  hello world  ', chunkSize: 64, chunkOverlap: 8),
      ['hello world'],
    );
  });

  test('text exactly at the window size stays a single chunk', () {
    final text = 'a' * 100;
    expect(KnowledgeChunker.chunk(text, chunkSize: 100, chunkOverlap: 10), [
      text,
    ]);
  });

  test('long unbroken text splits into bounded chunks', () {
    final text = 'x' * 500;
    final chunks = KnowledgeChunker.chunk(
      text,
      chunkSize: 100,
      chunkOverlap: 20,
    );
    expect(chunks.length, greaterThan(1));
    expect(chunks.every((c) => c.length <= 100), isTrue);
    // Overlap: the first 20 chars of chunk 2 repeat the last 20 of chunk 1.
    if (chunks.length >= 2) {
      expect(chunks[1].substring(0, 20), chunks[0].substring(80));
    }
  });

  test('boundaries snap to a newline in the second half of the window', () {
    final paragraph = 'a' * 60;
    final text = '$paragraph\n$paragraph\n';
    final chunks = KnowledgeChunker.chunk(
      text,
      chunkSize: 100,
      chunkOverlap: 0,
    );
    expect(chunks.first.length, 60);
    expect(chunks.first, paragraph);
  });

  test('CJK text without spaces chunks by character count', () {
    final text = '中医药知识百科' * 50; // 350 chars
    final chunks = KnowledgeChunker.chunk(
      text,
      chunkSize: 100,
      chunkOverlap: 10,
    );
    expect(chunks.length, greaterThan(1));
    expect(chunks.every((c) => c.length <= 100), isTrue);
    expect(chunks.every((c) => c.isNotEmpty), isTrue);
  });

  test('every source position is covered by at least one chunk', () {
    final text = List.generate(
      30,
      (i) => 'line $i with some body text',
    ).join('\n');
    final chunks = KnowledgeChunker.chunk(
      text,
      chunkSize: 80,
      chunkOverlap: 16,
    );
    final covered = <int>{};
    for (final chunk in chunks) {
      var from = 0;
      while (true) {
        final at = text.indexOf(chunk, from);
        if (at < 0) break;
        for (var i = at; i < at + chunk.length; i++) {
          covered.add(i);
        }
        from = at + 1;
      }
    }
    // Trimmed chunks lose leading/trailing whitespace, so only assert that the
    // non-whitespace positions appear somewhere.
    for (var i = 0; i < text.length; i++) {
      if (text[i].trim().isEmpty) continue;
      expect(covered.contains(i), isTrue, reason: 'position $i uncovered');
    }
  });

  test('overlap >= chunkSize is clamped so chunking terminates', () {
    final chunks = KnowledgeChunker.chunk(
      'a' * 200,
      chunkSize: 50,
      chunkOverlap: 500,
    );
    expect(chunks.length, greaterThan(1));
    expect(chunks.every((c) => c.length <= 50), isTrue);
  });
}
