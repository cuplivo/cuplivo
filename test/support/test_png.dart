import 'dart:typed_data';

import 'package:image/image.dart' as image_lib;

/// A PNG of the given shape, so a test can hand the layout a picture without
/// carrying one in the repository.
///
/// The pixels are a gradient rather than a flat fill: the writer embeds the
/// bytes as they are, and a codec that happens to fold a uniform image into a
/// smaller one still has to carry a shape the test can rely on.
Uint8List pngForTest({required int width, required int height}) {
  final image = image_lib.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(x, y, x % 256, y % 256, 128);
    }
  }
  return Uint8List.fromList(image_lib.encodePng(image));
}
