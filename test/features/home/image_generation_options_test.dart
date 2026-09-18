import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/home/widgets/image_generation_options.dart';

void main() {
  group('ImageGenerationOptionsController', () {
    test('fresh controller is not customized and emits nothing', () {
      final c = ImageGenerationOptionsController();
      expect(c.customized, isFalse);
      expect(c.toExtraBody(), isEmpty);
    });

    test('only explicitly touched fields are emitted', () {
      final c = ImageGenerationOptionsController();
      c.quality = 'low';
      expect(c.toExtraBody(), containsPair('quality', 'low'));
      expect(c.toExtraBody().containsKey('size'), isFalse);
      expect(c.toExtraBody().containsKey('output_format'), isFalse);
      expect(c.toExtraBody().containsKey('n'), isFalse);
    });

    test('count is emitted and reset restores defaults', () {
      final c = ImageGenerationOptionsController();
      c.count = 3;
      expect(c.toExtraBody(), containsPair('n', 3));
      c.reset();
      expect(c.customized, isFalse); // values back to defaults
      expect(c.toExtraBody(), containsPair('n', 1)); // still explicit
    });

    test('applyDefaultsFromBody inherits defaults without customizing', () {
      final c = ImageGenerationOptionsController();
      c.applyDefaultsFromBody(const {
        'quality': 'medium',
        'output_format': 'webp',
      });
      expect(c.customized, isFalse);
      expect(c.toExtraBody(), isEmpty);
      // defaults now reflect the body: untouched fields still not emitted
    });

    test('explicit user fields survive a defaults refresh', () {
      final c = ImageGenerationOptionsController();
      c.quality = 'low'; // diverges from the default -> customized
      c.applyDefaultsFromBody(const {'quality': 'medium'});
      expect(c.toExtraBody(), containsPair('quality', 'low'));
    });

    test('a value equal to default is not customized', () {
      final c = ImageGenerationOptionsController();
      c.quality = 'high'; // equals the default value
      expect(c.customized, isFalse);
      expect(c.toExtraBody(), containsPair('quality', 'high'));
    });

    test('restoreFromBody marks fields customized', () {
      final c = ImageGenerationOptionsController();
      c.restoreFromBody(const {'quality': 'low', 'size': '1024x1024', 'n': 2});
      expect(c.customized, isTrue);
      final body = c.toExtraBody();
      expect(body, containsPair('quality', 'low'));
      expect(body, containsPair('n', 2));
      expect(body.containsKey('output_format'), isFalse);
    });

    test('png with explicit compression emits null compression', () {
      final c = ImageGenerationOptionsController();
      c.outputFormat = 'png';
      c.outputCompression = 80;
      expect(c.toExtraBody(), containsPair('output_format', 'png'));
      expect(c.toExtraBody()['output_compression'], isNull);
    });
  });
}
