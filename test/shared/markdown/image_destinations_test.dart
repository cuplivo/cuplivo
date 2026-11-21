import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/shared/markdown/image_destinations.dart';

/// The destinations the renderer will draw for [source] — the map's keys, which
/// is all most questions need.
Set<String> _destinations(String source) =>
    markdownImageFirstOffsets(source).keys.toSet();

void main() {
  const uri = 'kelivo-file:///images/img_abc.png';

  test('prose and a bare placeholder both count', () {
    expect(_destinations('see ![]($uri) above'), {uri});
    expect(_destinations('![]($uri)'), {uri});
  });

  test('a destination inside a fenced block is text, not a picture', () {
    expect(_destinations('```\n![]($uri)\n```'), isEmpty);
    expect(_destinations('~~~md\n![]($uri)\n~~~'), isEmpty);
  });

  test('inline code and plain links are text too', () {
    expect(_destinations('`![]($uri)`'), isEmpty);
    expect(_destinations('[here]($uri)'), isEmpty);
  });

  test('a title is not part of the destination', () {
    // The renderer gets the destination alone; anything that keeps the title in
    // it would ask for a picture at a uri that does not exist.
    expect(_destinations('![a](https://host/x.png "a title")'), {
      'https://host/x.png',
    });
  });

  test('the same uri written twice is one destination', () {
    expect(_destinations('![]($uri)\n\ntext\n\n![]($uri)'), {uri});
  });

  test('the first mention keeps the offset, later ones do not', () {
    // The offset is the identity that lets the renderer give the card to the
    // first mention only: the node it builds carries its own span.start — in the
    // document it belongs to, which is why the caller asks per document.
    const body = 'BEFORE\n\n![]($uri)\n\nMIDDLE\n\n![]($uri)\n\nAFTER';
    final offsets = markdownImageFirstOffsets(body);

    expect(offsets.keys, [uri]);
    final first = offsets[uri]!;
    expect(body.substring(first, first + 3), '![]');
    expect(first, body.indexOf('![]'));
    expect(body.indexOf('![]', first + 1), greaterThan(first));
  });

  test('nothing to parse is nothing to draw', () {
    expect(markdownImageFirstOffsets(''), isEmpty);
  });
}
