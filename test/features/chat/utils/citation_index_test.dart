import 'package:Cuplivo/features/chat/utils/citation_index.dart';
import 'package:flutter_test/flutter_test.dart';

/// How a citation id becomes the number a reader sees.
///
/// The screen and the exported page both ask these functions, so what is pinned
/// here is the rule itself rather than either surface's use of it: which tool
/// results a citation can resolve against, which of two results wins, and what
/// an id that resolves to nothing shows.
void main() {
  group('the items a message can cite', () {
    test('come from search results, newest first, deduplicated', () {
      final items = searchCitationItemsOf(<CitationToolResult>[
        (name: 'search_web', content: '{"items":[{"id":"a","index":"1"}]}'),
        (name: 'read_file', content: '{"items":[{"id":"x","index":"9"}]}'),
        (name: 'builtin_search', content: '{"items":[{"id":"a","index":"2"}]}'),
      ]);
      // The newest call that mentions "a" wins, and the unrelated tool is not a
      // search at all.
      expect(items, hasLength(1));
      expect(items.single['index'], '2');
    });

    test('fall back to the url when a builtin result carries no id', () {
      final items = searchCitationItemsOf(<CitationToolResult>[
        (
          name: 'builtin_search',
          content: '{"items":[{"url":"https://example.com","index":"1"}]}',
        ),
      ]);
      expect(items, hasLength(1));
      expect(items.single['url'], 'https://example.com');
    });

    test('an unreadable payload contributes nothing rather than throwing', () {
      final items = searchCitationItemsOf(<CitationToolResult>[
        (name: 'search_web', content: 'not json'),
        (name: 'search_web', content: '{"items":"not a list"}'),
        (name: 'search_web', content: null),
        (name: 'search_web', content: '{"items":[1,{"id":"a","index":"1"}]}'),
      ]);
      expect(items, hasLength(1));
      expect(items.single['id'], 'a');
    });
  });

  group('the index lookup', () {
    test('lets an exact id win over a result that sits at the same number', () {
      final lookup = citationIndexLookupOf(<Map<String, dynamic>>[
        {'id': '7', 'index': '1'},
        {'id': 'abc', 'index': '7'},
      ]);
      expect(lookup['7'], '1');
      expect(lookup['abc'], '7');
    });

    test('keeps the first index a result claims', () {
      final lookup = citationIndexLookupOf(<Map<String, dynamic>>[
        {'id': 'a', 'index': '1'},
        {'id': 'a', 'index': '2'},
      ]);
      expect(lookup['a'], '1');
    });
  });

  group('resolving a marker', () {
    const lookup = <String, String>{'abc': '3', '5': '5'};

    test('follows an id, and a number that names one by position', () {
      expect(resolveCitationIndex('abc', lookup), '3');
      expect(resolveCitationIndex(' 5 ', lookup), '5');
    });

    test('answers null for anything the results do not hold', () {
      expect(resolveCitationIndex('missing', lookup), isNull);
      expect(resolveCitationIndex('9', lookup), isNull);
      expect(resolveCitationIndex('   ', lookup), isNull);
    });
  });
}
