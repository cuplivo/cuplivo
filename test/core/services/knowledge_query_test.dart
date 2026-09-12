import 'package:Cuplivo/core/services/knowledge/knowledge_query.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('attachment markers are stripped and whitespace collapsed', () {
    expect(
      KnowledgeQuery.stripAttachmentMarkers(
        '看下 [image:/a/b.png] 这个 [file:/c/d.pdf|d.pdf|application/pdf] 内容',
      ),
      '看下 这个 内容',
    );
    expect(KnowledgeQuery.stripAttachmentMarkers('[image:/a/b.png]'), isEmpty);
    expect(KnowledgeQuery.stripAttachmentMarkers('  plain  '), 'plain');
  });

  test('short terms are not indexable and force the LIKE fallback', () {
    expect(KnowledgeQuery.buildFtsMatch('脾胃'), isNull);
    expect(KnowledgeQuery.buildFtsMatch('a'), isNull);
    expect(KnowledgeQuery.buildFtsMatch('   '), isNull);
  });

  test('indexable terms are quoted and AND-joined', () {
    expect(KnowledgeQuery.buildFtsMatch('中医药'), '"中医药"');
    expect(KnowledgeQuery.buildFtsMatch('foo bar'), '"foo" AND "bar"');
    expect(KnowledgeQuery.buildFtsMatch('a foo'), '"foo"');
  });

  test('CJK sentences expand into OR-joined trigram windows', () {
    final match = KnowledgeQuery.buildFtsMatch('战争对经济的影响有哪些？');
    expect(match, isNotNull);
    expect(match, contains(' OR '));
    // Topical slices are present; the trailing question particle is a slice too
    // but OR keeps recall.
    expect(match, contains('"战争对"'));
    expect(match, contains('"对经济"'));
    // A punctuation mark is a delimiter, never an indexable term.
    expect(match, isNot(contains('？"')));
  });

  test('CJK question still matches when windows are sampled (bounded)', () {
    final longRun = '中' * 60;
    final match = KnowledgeQuery.buildFtsMatch(longRun);
    expect(match, isNotNull);
    final windowCount = RegExp(r'"[^"]*"').allMatches(match!).length;
    // maxWindowsPerRun sampled windows + at most the appended tail.
    expect(windowCount, lessThanOrEqualTo(KnowledgeQuery.maxWindowsPerRun + 1));
  });

  test('mixed CJK and ASCII tokens keep AND between tokens', () {
    final match = KnowledgeQuery.buildFtsMatch('战争 report file');
    expect(match, isNotNull);
    expect(match, contains('"report"'));
    expect(match, contains('"file"'));
    expect(match, contains(' AND '));
  });

  test('a two-character CJK term has no indexable window', () {
    expect(KnowledgeQuery.buildFtsMatch('战争'), isNull);
  });

  test('embedded quotes are doubled inside a phrase', () {
    expect(
      KnowledgeQuery.buildFtsMatch('say "hi" there'),
      r'"say" AND """hi""" AND "there"',
    );
  });

  test('likePattern escapes wildcard characters', () {
    expect(KnowledgeQuery.likePattern('50%'), r'%50\%%');
    expect(KnowledgeQuery.likePattern('a_b'), r'%a\_b%');
    expect(KnowledgeQuery.likePattern('c\\d'), r'%c\\d%');
  });
}
