import 'package:Cuplivo/features/chat/utils/markdown_pdf_emitter.dart';
import 'package:flutter_test/flutter_test.dart';

/// The key space the raster bridge and the layout have to agree on.
///
/// The layout looks a drawing up by the source it stands in for, and the bridge
/// draws whatever the keys name — so a key the walk names and the bridge cannot
/// draw is a formula printed as its own TeX, and a drawing the walk forgets is a
/// bitmap nobody embeds. Both are silent, which is what these pin.
///
/// The capture itself (an offscreen boundary plus `toImage`) is engine-level
/// async and cannot complete under the widget-test clock, so it is not asserted
/// here; the acceptance run on a device is what covers it.
void main() {
  test('a display formula is a math key, closed or open', () {
    final closed = pdfRasterKeysIn(
      'text\n\n\$\$\\int_0^1 x^2\\,dx\$\$\n',
      enableMathRendering: true,
      enableDollarLatex: true,
    );
    expect(closed, hasLength(1));
    expect(closed.single.kind, PdfRasterKind.math);
    expect(closed.single.source, r'\int_0^1 x^2\,dx');
    expect(closed.single.display, isTrue);

    final bracket = pdfRasterKeysIn(
      'text\n\n\\[a+b\\]\n',
      enableMathRendering: true,
      enableDollarLatex: true,
    );
    expect(bracket.single.source, 'a+b');
    expect(bracket.single.display, isTrue);
  });

  test('an inline formula is a math key too, without its delimiters', () {
    final keys = pdfRasterKeysIn(
      '速度 \$v = \\frac{s}{t}\$ 的公式。',
      enableMathRendering: true,
      enableDollarLatex: true,
    );
    expect(keys, hasLength(1));
    expect(keys.single.kind, PdfRasterKind.math);
    expect(keys.single.source, r'v = \frac{s}{t}');
    // Set in a line of prose rather than as a block of its own: the rasterizer
    // draws those two differently, so they are two different keys.
    expect(keys.single.display, isFalse);
  });

  test('the same TeX inline and as a block are two different drawings', () {
    final inline = pdfRasterKeysIn(
      'so \$x^2\$ holds',
      enableMathRendering: true,
      enableDollarLatex: true,
    ).single;
    final display = pdfRasterKeysIn(
      'text\n\n\$\$x^2\$\$\n',
      enableMathRendering: true,
      enableDollarLatex: true,
    ).single;

    expect(inline.source, display.source);
    expect(display.display, isTrue);
    expect(inline.display, isFalse);
    expect(pdfRasterLookupKey(inline), isNot(pdfRasterLookupKey(display)));
  });

  test('a diagram fence is a diagram key that names its language', () {
    final mermaid = pdfRasterKeysIn(
      '```mermaid\ngraph TD;\n  A-->B;\n```\n',
      enableMathRendering: true,
      enableDollarLatex: true,
    ).single;
    expect(mermaid.kind, PdfRasterKind.diagram);
    expect(mermaid.language, 'mermaid');
    // The code, not the fence: this is what the layout looks the bitmap up by.
    expect(mermaid.source.trim(), 'graph TD;\n  A-->B;');
    expect(pdfRasterLookupKey(mermaid), mermaid.source);

    final plantuml = pdfRasterKeysIn(
      '```plantuml\n@startuml\nA -> B\n@enduml\n```\n',
      enableMathRendering: true,
      enableDollarLatex: true,
    ).single;
    // Named as a diagram so the walk and the bridge share one vocabulary; the
    // bridge draws mermaid and SVG only, so this one keeps its code fallback.
    expect(plantuml.kind, PdfRasterKind.diagram);
    expect(plantuml.language, 'plantuml');
    expect(pdfRasterLookupKey(plantuml), plantuml.source);
  });

  test('a formula inside a quote, a table cell or a details body is a key', () {
    List<PdfRasterKey> keysOf(String markdown) => pdfRasterKeysIn(
      markdown,
      enableMathRendering: true,
      enableDollarLatex: true,
    );

    // A quote, a table and a `<details>` are opaque leaves in the IR: the node
    // declares the whole block and holds no children. The layout walks each
    // body again, so the key walk has to re-enter the same bodies — a key the
    // layout asks for and this walk never named is a formula the caller was
    // never told to draw, and it prints as its own TeX.
    final quoted = keysOf('> quoted prose\n>\n> \$\$x^2\$\$\n');
    expect(quoted, hasLength(1));
    expect(quoted.single.kind, PdfRasterKind.math);
    expect(quoted.single.source, 'x^2');
    expect(quoted.single.display, isTrue);

    // A cell is its own markdown surface, and `$…$` in a line is inline math.
    final cell = keysOf('| a | b |\n| --- | --- |\n| \$x^2\$ | c |\n');
    expect(cell, hasLength(1));
    expect(cell.single.kind, PdfRasterKind.math);
    expect(cell.single.source, 'x^2');
    expect(cell.single.display, isFalse);

    final details = keysOf(
      '<details>\n<summary>s</summary>\n\n\$\$x^2\$\$\n\n</details>\n',
    );
    expect(details, hasLength(1));
    expect(details.single.source, 'x^2');
    expect(details.single.display, isTrue);
  });

  test('a diagram fence inside a quote or a details body is a key', () {
    final quoted = pdfRasterKeysIn(
      '> ```mermaid\n> graph TD;\n> ```\n',
      enableMathRendering: true,
      enableDollarLatex: true,
    );
    expect(quoted, hasLength(1));
    expect(quoted.single.kind, PdfRasterKind.diagram);
    expect(quoted.single.language, 'mermaid');
    expect(quoted.single.source.contains('graph TD'), isTrue);

    final details = pdfRasterKeysIn(
      '<details>\n<summary>s</summary>\n\n```mermaid\ngraph TD;\n```\n\n'
      '</details>\n',
      enableMathRendering: true,
      enableDollarLatex: true,
    );
    expect(details, hasLength(1));
    expect(details.single.kind, PdfRasterKind.diagram);
    expect(details.single.source.contains('graph TD'), isTrue);
  });

  test(
    'math rendering off names no math key, because the walk claims none',
    () {
      final keys = pdfRasterKeysIn(
        'text\n\n\$\$x^2\$\$\n',
        enableMathRendering: false,
        enableDollarLatex: true,
      );
      expect(keys, isEmpty);
    },
  );
}
