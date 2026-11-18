import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/shared/markdown/image_destinations.dart';

void main() {
  const uri = 'kelivo-file:///images/img_abc.png';

  test('prose and a bare placeholder both count', () {
    expect(markdownImageDestinations('see ![]($uri) above'), {uri});
    expect(markdownImageDestinations('![]($uri)'), {uri});
  });

  test('a destination inside a fenced block is text, not a picture', () {
    expect(markdownImageDestinations('```\n![]($uri)\n```'), isEmpty);
    expect(markdownImageDestinations('~~~md\n![]($uri)\n~~~'), isEmpty);
  });

  test('inline code and plain links are text too', () {
    expect(markdownImageDestinations('`![]($uri)`'), isEmpty);
    expect(markdownImageDestinations('[here]($uri)'), isEmpty);
  });

  test('a title is not part of the destination', () {
    // The renderer gets the destination alone; anything that keeps the title in
    // it would ask for a picture at a uri that does not exist.
    expect(markdownImageDestinations('![a](https://host/x.png "a title")'), {
      'https://host/x.png',
    });
  });

  test('the same uri written twice is one destination', () {
    expect(markdownImageDestinations('![]($uri)\n\ntext\n\n![]($uri)'), {uri});
  });
}
