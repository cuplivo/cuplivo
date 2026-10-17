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
