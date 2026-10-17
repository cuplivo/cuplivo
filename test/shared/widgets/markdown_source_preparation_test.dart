import 'package:Cuplivo/shared/widgets/markdown_with_highlight.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// The stage a source goes through before the walk, and the two readings it
/// shares with its consumers.
///
/// It matters because the screen walks the *prepared* source and a consumer with
/// no widget tree — the PDF exporter — has to run the same stage: these are the
/// rewrites whose absence made an export print `[cite:id]`, a link's title and a
/// display formula as raw markdown, so each one is pinned here rather than only
/// observed through the renderer.
void main() {
  group('the preparation stage', () {
    String prepared(String source) => markdownPreprocessFences(
      source,
      enableMath: true,
      enableDollarLatex: true,
    );

    test('turns citation markers into the links the walk understands', () {
      expect(
        prepared('See [cite:abc123] here.'),
        'See [citation](abc123) here.',
      );
      // Cherry's style carries several ids in one marker.
      expect(
        prepared('See [cite:a1b2, d4e5].'),
        'See [citation](a1b2) [citation](d4e5).',
      );
      // The `[citation:…]` shape keeps the index the marker already had.
      expect(prepared('See [citation:3:abc].'), 'See [citation](3:abc).');
    });

    test('strips a link title the link pattern cannot carry', () {
      expect(
        prepared('[text](https://example.com "the title")'),
        '[text](https://example.com)',
      );
    });

    test('gives a display formula written inside a line a block of its own', () {
      final out = prepared(r'Inline $$\frac{a}{b} + \frac{c}{d}$$ in prose.');
      // Blank lines around it are what the walk needs to see a block: `\n` here
      // is a real newline, which is why this expectation is concatenated rather
      // than written as one raw string.
      expect(
        out,
        contains('${r'$$'}\n${r'\frac{a}{b} + \frac{c}{d}'}\n${r'$$'}'),
      );
      // A short pair is left alone: the renderer treats it as text, and an export
      // that moved it would disagree with the screen about the same message.
      expect(
        prepared(r'Inline $$x^2$$ in prose.'),
        r'Inline $$x^2$$ in prose.',
      );
    });

    test('keeps a dollar inside inline code out of the math passes', () {
      final out = prepared('costs `\$5` a day');
      expect(out, contains('___CODE_DOLLAR_MASK___'));
      // The mask is the walk's own business; a consumer that shows the code
      // restores it, which is what `unmaskCodeSpanDollars` is for.
      expect(unmaskCodeSpanDollars(out), contains(r'`$5`'));
    });

    test('masks an html tag inside a fence and restores it on demand', () {
      const masked = '\uE002details';
      expect(unmaskFencedHtmlTagStarts(masked), '<details');
      expect(unmaskFencedHtmlTagStarts('plain'), 'plain');
    });
  });

  group('image elements', () {
    test(
      'reads the size an alt spells, and the target with its parentheses',
      () {
        final sized = parseMarkdownImageElement('![300x200](a.png)')!;
        expect(sized.alt, '300x200');
        expect(sized.url, 'a.png');
        expect(sized.width, 300);
        expect(sized.height, 200);

        final widthOnly = parseMarkdownImageElement('![300](a.png)')!;
        expect(widthOnly.width, 300);
        expect(widthOnly.height, isNull);

        final heightOnly = parseMarkdownImageElement('![x200](a.png)')!;
        expect(heightOnly.width, isNull);
        expect(heightOnly.height, 200);

        final text = parseMarkdownImageElement('![a picture](shot://x)')!;
        expect(text.alt, 'a picture');
        expect(text.width, isNull);
        expect(text.height, isNull);

        // A target may hold balanced parentheses, which is why the element is
        // scanned rather than matched a second time.
        expect(
          parseMarkdownImageElement('![a](dir/(1).png)')!.url,
          'dir/(1).png',
        );
        expect(parseMarkdownImageElement('not an image'), isNull);
      },
    );

    test('turns a local path with a space into a URI the pattern matches', () {
      // The image pattern's target is `[^\s\n]*`, so a path with a space in it
      // never matches at all and reaches the walk as literal text.
      const source = r'![a](C:\pics\my shot.png)';
      final sanitized = markdownSanitizeImageLinks(source);
      expect(sanitized, contains('my%20shot.png'));
      expect(sanitized, isNot(contains(' ')));

      // A remote target is left exactly as it was: the rewrite can only lose.
      const remote = '![a](https://example.com/a b.png)';
      expect(markdownSanitizeImageLinks(remote), remote);
    });
  });

  group('citation links', () {
    test('are the links labelled citation, and only those', () {
      expect(markdownCitationRefForLink('citation', 'abc')?.id, 'abc');
      expect(markdownCitationRefForLink('Citation', 'abc')?.id, 'abc');
      expect(markdownCitationRefForLink('citation', '3:abc')?.indexText, '3');
      expect(markdownCitationRefForLink('docs', 'abc'), isNull);
      expect(markdownCitationRefForLink('citation', ''), isNull);
    });

    test('show the resolved index, the marker index, or a question mark', () {
      final ref = markdownCitationRef('abc')!;
      expect(markdownCitationLabel(ref, (id) => '4'), '4');
      expect(markdownCitationLabel(ref, (id) => null), '?');
      expect(markdownCitationLabel(ref, null), '?');

      // A marker that carried its own index keeps it when nothing resolves.
      expect(markdownCitationLabel(markdownCitationRef('3:abc')!, null), '3');
      // And a bare number is a citation by position.
      expect(markdownCitationLabel(markdownCitationRef('3')!, null), '3');
    });
  });
}
