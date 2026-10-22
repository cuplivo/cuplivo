import 'package:Cuplivo/features/chat/utils/selection_markdown_memory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markstream/markstream.dart' show DocumentNode, MarkdownParser;

/// One selection snippet: what `MarkstreamSelection.content` hands over —
/// already clipped to the selected text, with the containers kept.
DocumentNode _snippet(String source) => MarkdownParser().parse(source);

/// The surface a capture is filed under.
const Object _owner = 'assistant_message-1';

void main() {
  final memory = SelectionMarkdownMemory.instance;

  tearDown(memory.clear);

  group('SelectionMarkdownMemory', () {
    test('returns nothing before a selection is recorded', () {
      expect(memory.markdownForSelection(), isNull);
      expect(memory.replySourceForSelection(), isNull);
    });

    test('returns the recorded snippet as markdown', () {
      memory.capture(
        owner: _owner,
        messageId: 'message-1',
        content: [_snippet('**bold** text')],
      );
      // The AST carries the whole emphasis node, so the markers are complete
      // without any text matching: a selection inside bold text can never come
      // out as an orphaned delimiter.
      expect(memory.markdownForSelection(), '**bold** text');
    });

    test('joins multiple snippets the way the controller joins them', () {
      memory.capture(
        owner: _owner,
        messageId: 'message-1',
        content: [_snippet('first'), _snippet('second')],
      );
      expect(memory.markdownForSelection(), 'first\n\nsecond');
    });

    test('returns nothing when the selection is emptied', () {
      memory.capture(
        owner: _owner,
        messageId: 'message-1',
        content: [_snippet('text')],
      );
      expect(memory.markdownForSelection(), isNotNull);

      memory.capture(owner: _owner, messageId: 'message-1', content: const []);
      expect(memory.markdownForSelection(), isNull);
    });

    test('a surface only retires what it recorded', () {
      memory.capture(
        owner: _owner,
        messageId: 'message-1',
        content: [_snippet('kept')],
      );

      memory.clearIfOwner('another surface');
      expect(memory.markdownForSelection(), 'kept');

      memory.clearIfOwner(_owner);
      expect(memory.markdownForSelection(), isNull);
    });

    test('a menu cannot be answered by a sibling surface', () {
      memory.capture(
        owner: _owner,
        messageId: 'message-1',
        content: [_snippet('mine')],
      );

      expect(memory.markdownIfOwner('a sibling bubble'), isNull);
      expect(memory.markdownIfOwner(_owner), 'mine');
    });

    test('a reply carries the message the selection came from', () {
      memory.capture(
        owner: _owner,
        messageId: 'message-1',
        content: [_snippet('quoted')],
      );

      expect(memory.replySourceForSelection(), (
        messageId: 'message-1',
        markdown: 'quoted',
      ));
    });

    test('a recording with no citable message is not a reply source', () {
      memory.capture(owner: _owner, messageId: '', content: [_snippet('x')]);
      expect(memory.replySourceForSelection(), isNull);
    });
  });
}
