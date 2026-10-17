import 'package:Cuplivo/features/chat/utils/selection_markdown_memory.dart';
import 'package:flutter/material.dart' show TextDirection;
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// The same walk the app's copy path builds, minus the settings: the plain
/// component set is enough to exercise the mapping.
MdDocument _document(String source) => MarkdownComponent.walkDocument(
  source,
  config: const GptMarkdownConfig(textDirection: TextDirection.ltr),
);

/// The surface a capture is filed under.
const Object _owner = 'assistant_message-1';

void main() {
  final memory = SelectionMarkdownMemory.instance;

  tearDown(memory.clear);

  group('SelectionMarkdownMemory', () {
    test('returns nothing before a selection is recorded', () {
      expect(memory.markdownForSelection(), isNull);
    });

    test('returns the markdown the IR re-emits for the selection', () {
      memory.capture(
        owner: _owner,
        messageId: 'message-1',
        document: () => _document('**bold** text'),
        selectedText: 'bold text',
      );
      // The IR completes the markers the selection cut. The branch's old
      // matcher returned `bold** text` — an orphaned closing delimiter.
      expect(memory.markdownForSelection(), '**bold** text');
    });

    test('keeps the list marker a selection starts after', () {
      memory.capture(
        owner: _owner,
        messageId: 'message-1',
        document: () => _document('- first item\n- second item'),
        selectedText: 'first item\nsecond item',
      );
      expect(memory.markdownForSelection(), '- first item\n- second item');
    });

    test('completes the link a selection ends inside', () {
      memory.capture(
        owner: _owner,
        messageId: 'message-1',
        document: () => _document('plain [a link](https://x.dev/p)'),
        selectedText: 'a link',
      );
      expect(memory.markdownForSelection(), '[a link](https://x.dev/p)');
    });

    test('falls back to the plain text when nothing matches', () {
      // The rendered selection has no counterpart in the display space at all:
      // markdown copy must never be worse than a plain copy.
      memory.capture(
        owner: _owner,
        messageId: 'message-1',
        document: () => _document('alpha beta'),
        selectedText: 'gamma',
      );
      expect(memory.markdownForSelection(), 'gamma');
    });

    test('sanitizes the fallback', () {
      memory.capture(
        owner: _owner,
        messageId: 'message-1',
        document: () => _document('alpha beta'),
        selectedText: 'gam\u200Bma',
      );
      expect(memory.markdownForSelection(), 'gamma');
    });

    test('forgets the selection on clear', () {
      memory.capture(
        owner: _owner,
        messageId: 'message-1',
        document: () => _document('**bold** text'),
        selectedText: 'bold text',
      );
      memory.clear();
      expect(memory.markdownForSelection(), isNull);
    });

    test('drops a whitespace-only selection', () {
      memory.capture(
        owner: _owner,
        messageId: 'message-1',
        document: () => _document('a b'),
        selectedText: '   ',
      );
      expect(memory.markdownForSelection(), isNull);
    });

    test('rebuilds the document per copy rather than caching one', () {
      var builds = 0;
      memory.capture(
        owner: _owner,
        messageId: 'message-1',
        document: () {
          builds++;
          return _document('**bold** text');
        },
        selectedText: 'bold text',
      );
      expect(memory.markdownForSelection(), '**bold** text');
      expect(memory.markdownForSelection(), '**bold** text');
      expect(builds, 2);
    });

    test('a surface retires only its own selection', () {
      // The hotkey acts on the last selection made, so a surface that goes away
      // has to take its own recording with it — and only its own: another
      // bubble's live selection must survive this one's dispose.
      final other = Object();
      memory.capture(
        owner: other,
        messageId: 'message-2',
        document: () => _document('**bold** text'),
        selectedText: 'bold text',
      );

      memory.clearIfOwner(_owner);
      expect(memory.markdownForSelection(), '**bold** text');

      memory.clearIfOwner(other);
      expect(memory.markdownForSelection(), isNull);
    });

    test('a reply source carries the message the selection was made in', () {
      memory.capture(
        owner: _owner,
        messageId: 'message-1',
        document: () => _document('**bold** text'),
        selectedText: 'bold text',
      );
      final source = memory.replySourceForSelection();
      expect(source?.messageId, 'message-1');
      expect(source?.markdown, '**bold** text');
    });

    test('a reply source agrees with what the copy path would write', () {
      // One mapping for both hotkeys: a reply can never cite markdown the
      // copy-as-Markdown path would not have produced.
      memory.capture(
        owner: _owner,
        messageId: 'message-1',
        document: () => _document('- one\n- two'),
        selectedText: 'one\ntwo',
      );
      expect(
        memory.replySourceForSelection()?.markdown,
        memory.markdownForSelection(),
      );
    });

    test('an empty recording leaves no reply source', () {
      expect(memory.replySourceForSelection(), isNull);
      memory.capture(
        owner: _owner,
        messageId: 'message-1',
        document: () => _document('   '),
        selectedText: '   ',
      );
      expect(memory.replySourceForSelection(), isNull);
    });
  });
}
