import 'package:flutter/material.dart' show TextDirection;
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// v3's matcher suite (Cuplivo 3.x PR #122, carried onto
/// `feat/direct-select-text-v4`) ported to IR semantics.
///
/// The cases that asserted a *span* the sub-sequence walk happened to stop at
/// are gone: their expectations were the bug. `**bold** text` selected as
/// `bold text` used to return `bold** text` — an orphaned closing delimiter —
/// and now returns `**bold** text`. The cases that describe what the user
/// selected, CJK, normalization and the null cases are kept, with the IR's
/// answer asserted instead.
String? _emit(String source, String selection) =>
    MarkdownComponent.walkDocument(
      source,
      config: const GptMarkdownConfig(textDirection: TextDirection.ltr),
    ).emitSelectionMarkdown(selection);

void main() {
  group('what the user selected comes back as markdown', () {
    test('a plain word', () {
      expect(_emit('hello world', 'world'), 'world');
    });

    test('a single character', () {
      expect(_emit('hello', 'e'), 'e');
    });

    test('the whole source', () {
      expect(_emit('hello world', 'hello world'), 'hello world');
    });

    test('CJK content', () {
      expect(_emit('你好世界', '世界'), '世界');
    });

    test('a link label keeps its target', () {
      expect(_emit('[click here](url)', 'click here'), '[click here](url)');
    });

    test('a heading keeps its marker', () {
      // v3 returned `Title` here: the heading was lost on paste.
      expect(_emit('## Title', 'Title'), '## Title');
    });

    test('emphasis around the selection is completed, not orphaned', () {
      // v3 returned `bold** text`, which pastes with a stray `**`.
      expect(_emit('**bold** text', 'bold text'), '**bold** text');
    });

    test('emphasis inside the selection is preserved', () {
      expect(
        _emit('**bold** and *italic*', 'bold and italic'),
        '**bold** and *italic*',
      );
    });

    test('a code block stays fenced', () {
      expect(
        _emit('```dart\nvoid main() {}\n```', 'void main() {}'),
        '```dart\nvoid main() {}\n```',
      );
    });

    test('list items stay items', () {
      expect(
        _emit('- item one\n- item two\n- item three', 'item one\nitem two'),
        '- item one\n- item two',
      );
    });

    test('a later exact match wins over an earlier partial one', () {
      expect(
        _emit('the answer is 42. the question is unknown.', 'the question'),
        'the question',
      );
    });

    test('text repeated inside one paragraph resolves to the first', () {
      // The known limit the branch's ADR recorded: the offset-proximity
      // upgrade is deferred, so the first occurrence is the one that comes
      // back.
      expect(_emit('**the** cat and **the** dog', 'the'), '**the**');
    });

    test('a selection across blocks keeps both', () {
      expect(
        _emit('# heading\n\n**bold** and `code`', 'heading\n\nbold and code'),
        '# heading\n\n**bold** and `code`',
      );
    });
  });

  group('normalization', () {
    test('CRLF folds to LF in the query', () {
      // The component's own pattern absorbs the `\r` as content and trims it,
      // so a re-emitted line ends with LF — the same form the renderer
      // normalizes CRLF to before it parses.
      expect(_emit('- a\r\n- b', 'a\nb'), '- a\n- b');
    });

    test('consecutive newlines fold in the query', () {
      expect(_emit('- a\n- b', 'a\n\nb'), '- a\n- b');
    });

    test('a zero-width non-joiner in the source is matched through', () {
      expect(_emit('hello\u200c world', 'hello world'), 'hello\u200c world');
    });

    test('a zero-width space in the query is stripped', () {
      expect(_emit('hello', 'h\u200bello'), 'hello');
    });

    test('a bullet in the query is stripped', () {
      // v3 stripped the bullet and matched the rest, expecting ` item text`.
      // A list bullet is a widget here, so it occupies no display space at
      // all: the query has a leading space the display space does not, and
      // the miss falls back to plain text rather than to a wrong span.
      expect(_emit('- item text', '• item text'), isNull);
      expect(_emit('- item text', 'item text'), '- item text');
    });
  });

  group('misses', () {
    test('an empty query', () {
      expect(_emit('hello', ''), isNull);
    });

    test('an empty source', () {
      expect(_emit('', 'hello'), isNull);
    });

    test('a query longer than the source', () {
      expect(_emit('abc', 'abcd'), isNull);
    });

    test('a query that is not in the source', () {
      expect(_emit('hello', 'xyz'), isNull);
    });

    test('a query that normalization empties', () {
      expect(_emit('hello', '\u200b\u200c'), isNull);
    });
  });
}
