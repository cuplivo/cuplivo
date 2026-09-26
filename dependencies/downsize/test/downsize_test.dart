import 'package:downsize/downsize.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

void main() {
  group('Downsize', () {
    test('applies quality and longest-edge limits and emits JPEG', () async {
      final input = img.encodePng(_patternImage(96, 48));

      final highQuality = await Downsize.downsize(
        data: input,
        quality: 90,
        maxLongEdge: 24,
      );
      final lowQuality = await Downsize.downsize(
        data: input,
        quality: 20,
        maxLongEdge: 24,
      );

      expect(highQuality, isNotNull);
      expect(lowQuality, isNotNull);
      expect(img.JpegDecoder().isValidFile(highQuality!), isTrue);
      final decoded = img.decodeJpg(highQuality);
      expect(decoded, isNotNull);
      expect(decoded!.width, 24);
      expect(decoded.height, 12);
      expect(highQuality.length, greaterThan(lowQuality!.length));
    });

    test('bakes orientation, strips EXIF, and composites alpha on white',
        () async {
      final oriented = _patternImage(12, 6)
        ..exif.imageIfd.orientation = 6
        ..exif.imageIfd.make = 'Kelivo test camera';
      final orientedInput = img.encodeJpg(oriented, quality: 100);

      final orientedOutput = await Downsize.downsize(
        data: orientedInput,
        quality: 100,
      );
      final decodedOriented = img.decodeJpg(orientedOutput!);
      expect(decodedOriented, isNotNull);
      expect(decodedOriented!.width, 6);
      expect(decodedOriented.height, 12);
      expect(img.decodeJpgExif(orientedOutput), isNull);

      final transparent = img.Image(width: 32, height: 32, numChannels: 4)
        ..clear(img.ColorRgba8(0, 0, 0, 0));
      for (var y = 10; y < 22; y++) {
        for (var x = 10; x < 22; x++) {
          transparent.setPixelRgba(x, y, 255, 0, 0, 255);
        }
      }

      final alphaOutput = await Downsize.downsize(
        data: img.encodePng(transparent),
        quality: 100,
      );
      final decodedAlpha = img.decodeJpg(alphaOutput!);
      expect(decodedAlpha, isNotNull);
      final corner = decodedAlpha!.getPixel(0, 0);
      expect(corner.r, greaterThan(245));
      expect(corner.g, greaterThan(245));
      expect(corner.b, greaterThan(245));
    });

    test('maxSize lowers quality by ten without crossing minQuality', () async {
      final input = img.encodePng(_patternImage(64, 64));
      final output = await Downsize.downsize(
        data: input,
        quality: 90,
        minQuality: 70,
        maxSize: 0,
      );

      final prepared = img.bakeOrientation(img.decodeImage(input, frame: 0)!);
      prepared.exif.clear();
      final expectedAtMinimum = img.encodeJpg(prepared, quality: 70);
      expect(output, orderedEquals(expectedAtMinimum));
    });

    test('png format emits PNG, resizes, and preserves alpha', () async {
      final transparent = img.Image(width: 32, height: 16, numChannels: 4)
        ..clear(img.ColorRgba8(0, 0, 0, 0));
      for (var y = 4; y < 12; y++) {
        for (var x = 4; x < 12; x++) {
          transparent.setPixelRgba(x, y, 255, 0, 0, 255);
        }
      }

      final output = await Downsize.downsize(
        data: img.encodePng(transparent),
        format: DownsizeFormat.png,
        maxLongEdge: 16,
      );

      expect(output, isNotNull);
      expect(img.PngDecoder().isValidFile(output!), isTrue);
      final decoded = img.decodePng(output);
      expect(decoded, isNotNull);
      expect(decoded!.width, 16);
      expect(decoded.height, 8);
      // Corner stays fully transparent instead of being composited on white.
      expect(decoded.getPixel(0, 0).a, 0);
      // Center stays opaque red.
      final center = decoded.getPixel(8, 4);
      expect(center.r, greaterThan(245));
      expect(center.g, lessThan(10));
      expect(center.a, 255);
    });

    test('compressDecoded matches compress through the full pipeline', () {
      final input = img.encodePng(_patternImage(96, 48));
      final downsize = Downsize();
      final config = Config(data: input, quality: 80, maxLongEdge: 24);

      final viaBytes = downsize.compress(config);
      final viaDecoded =
          downsize.compressDecoded(img.decodeImage(input, frame: 0)!, config);

      expect(viaBytes, isNotNull);
      expect(viaDecoded, orderedEquals(viaBytes));
    });
  });
}

img.Image _patternImage(int width, int height) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(
        x,
        y,
        (x * 37 + y * 17) % 256,
        (x * 11 + y * 43) % 256,
        (x * 29 + y * 7) % 256,
      );
    }
  }
  return image;
}
