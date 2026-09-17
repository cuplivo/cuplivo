import 'package:Cuplivo/utils/quote_plain_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('quotePlainText', () {
    test('strips inline emphasis', () {
      expect(
        quotePlainText('hello **bold** and *italic*'),
        'hello bold and italic',
      );
      expect(quotePlainText('`code` and ~~strike~~'), 'code and strike');
    });

    test('keeps underscores and dollar signs verbatim', () {
      expect(quotePlainText(r'snake_case costs $5'), r'snake_case costs $5');
    });

    test('links and images resolve to label/alt', () {
      expect(quotePlainText('[click here](https://x)'), 'click here');
      expect(quotePlainText('![alt text](img.png)'), 'alt text');
    });

    test('strips line markers and horizontal rules', () {
      expect(quotePlainText('> quote line'), 'quote line');
      expect(quotePlainText('## Heading'), 'Heading');
      expect(quotePlainText('- item\n* item2\n1. item3'), 'item\nitem2\nitem3');
      expect(quotePlainText('----'), '');
    });

    test('fenced code keeps the body, drops markers', () {
      expect(quotePlainText('```dart\nfinal x = 1;\n```'), 'final x = 1;');
    });

    test('backslash escapes unescape', () {
      expect(quotePlainText(r'\*escaped\*'), 'escaped');
      expect(quotePlainText(r'\[not math]'), '[not math]');
    });

    test('math delimiters and HTML are untouched (conservative)', () {
      expect(quotePlainText(r'$x_1$ and <b>tag</b>'), r'$x_1$ and <b>tag</b>');
    });
  });

  group('quoteFlatten / quoteClipText', () {
    test('flattens newlines and whitespace runs', () {
      expect(quoteFlatten('line1\n\n  line2\t end'), 'line1 line2 end');
    });

    test('clips with trailing ellipsis at budget', () {
      expect(quoteClipText('a' * 100, budget: 80), '${'a' * 80}…');
      expect(quoteClipText('short', budget: 80), 'short');
    });
  });

  group('quoteWindowText', () {
    test('keeps the span fully visible inside the budget', () {
      final win = quoteWindowText(
        fullPlain: '${'a' * 40}${'SPAN HERE'}${'b' * 40}',
        spanPlain: 'SPAN HERE',
      );
      expect(win, isNotNull);
      expect(win!.text.contains('SPAN HERE'), isTrue);
      expect(win.spanStart >= 0, isTrue);
      expect(win.text.length, lessThanOrEqualTo(quoteClipBudget + 4));
      expect(win.text.substring(win.spanStart, win.spanEnd), 'SPAN HERE');
    });

    test('span longer than budget stays whole (never clipped)', () {
      final span = 'c' * 200;
      final win = quoteWindowText(fullPlain: 'x$span', spanPlain: span);
      expect(win, isNotNull);
      expect(win!.text, span);
      expect(win.spanStart, 0);
      expect(win.spanEnd, 200);
    });

    test('ellipses appear only at cut boundaries', () {
      final win = quoteWindowText(
        fullPlain:
            '${'before'.padRight(100, 'a')}SPAN${'after'.padRight(100, 'b')}',
        spanPlain: 'SPAN',
      );
      expect(win, isNotNull);
      expect(win!.text.startsWith('…'), isTrue);
      expect(win.text.endsWith('…'), isTrue);
    });

    test('returns null when the span cannot be located', () {
      expect(
        quoteWindowText(fullPlain: 'hello world', spanPlain: 'not here'),
        isNull,
      );
    });
  });
}
