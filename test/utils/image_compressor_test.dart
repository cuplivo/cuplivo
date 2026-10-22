import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:Cuplivo/utils/image_compressor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  const config = ImageCompressConfig(
    enabled: true,
    quality: 70,
    maxLongEdge: 1024,
    includeTransparent: false,
  );

  test('compresses a large JPEG and limits its longest edge', () async {
    final source = img.encodeJpg(_noiseImage(1600, 1000), quality: 100);

    final result = await ImageCompressor.compressBytes(source, config);

    expect(result, isNotNull);
    expect(result!.lengthInBytes, lessThan(source.lengthInBytes));
    expect(img.JpegDecoder().isValidFile(result), isTrue);
    final decoded = img.decodeJpg(result)!;
    expect(max(decoded.width, decoded.height), 1024);
  });

  test(
    'uses PNG metadata to gate alpha, transparency, and animation',
    () async {
      final opaque = _noiseImage(512, 512);
      final opaqueBytes = img.encodePng(opaque);
      final opaqueResult = await ImageCompressor.compressBytes(
        opaqueBytes,
        config,
      );
      expect(opaqueResult, isNotNull);

      final opaqueWithAlpha = img.encodePng(
        _noiseImage(512, 512, withAlpha: true),
      );
      expect(
        await ImageCompressor.compressBytes(opaqueWithAlpha, config),
        isNull,
      );

      final indexedWithTransparencyChunk = img.encodePng(
        _opaqueIndexedImage(512, 512),
      );
      expect(
        await ImageCompressor.compressBytes(
          indexedWithTransparencyChunk,
          config,
        ),
        isNull,
      );

      final transparent = _noiseImage(512, 512, withAlpha: true);
      for (var y = 0; y < transparent.height; y++) {
        for (var x = 0; x < transparent.width ~/ 4; x++) {
          final pixel = transparent.getPixel(x, y);
          transparent.setPixelRgba(x, y, pixel.r, pixel.g, pixel.b, 0);
        }
      }
      final transparentBytes = img.encodePng(transparent);
      expect(
        await ImageCompressor.compressBytes(transparentBytes, config),
        isNull,
      );

      final flattened = await ImageCompressor.compressBytes(
        transparentBytes,
        const ImageCompressConfig(
          enabled: true,
          quality: 70,
          maxLongEdge: 1024,
          includeTransparent: true,
        ),
      );
      expect(flattened, isNotNull);
      final decoded = img.decodeJpg(flattened!)!;
      final whitePixel = decoded.getPixel(20, decoded.height ~/ 2);
      expect(whitePixel.r, greaterThan(240));
      expect(whitePixel.g, greaterThan(240));
      expect(whitePixel.b, greaterThan(240));

      final animated = _noiseImage(320, 320)..addFrame(_noiseImage(320, 320));
      final animatedBytes = img.encodePng(animated);
      expect(img.decodePng(animatedBytes)!.hasAnimation, isTrue);
      expect(
        await ImageCompressor.compressBytes(animatedBytes, config),
        isNull,
      );
      expect(
        await ImageCompressor.compressBytes(
          animatedBytes,
          const ImageCompressConfig(
            enabled: true,
            quality: 70,
            maxLongEdge: 1024,
            includeTransparent: true,
          ),
        ),
        isNotNull,
      );
    },
  );

  test('gates other formats and safely skips unusable inputs', () async {
    final sourceImage = _noiseImage(512, 512);
    final gif = img.encodeGif(sourceImage);
    final bmp = img.encodeBmp(sourceImage);

    expect(await ImageCompressor.compressBytes(gif, config), isNull);
    expect(await ImageCompressor.compressBytes(bmp, config), isNull);
    expect(
      await ImageCompressor.compressBytes(
        gif,
        const ImageCompressConfig(
          enabled: true,
          quality: 70,
          maxLongEdge: 1024,
          includeTransparent: true,
        ),
      ),
      isNotNull,
    );
    expect(
      await ImageCompressor.compressBytes(
        bmp,
        const ImageCompressConfig(
          enabled: true,
          quality: 70,
          maxLongEdge: 1024,
          includeTransparent: true,
        ),
      ),
      isNotNull,
    );
    expect(
      await ImageCompressor.compressBytes(
        img.encodeJpg(sourceImage, quality: 100),
        const ImageCompressConfig(
          enabled: false,
          quality: 70,
          maxLongEdge: 1024,
          includeTransparent: true,
        ),
      ),
      isNull,
    );
    expect(
      await ImageCompressor.compressBytes(
        Uint8List(ImageCompressor.kMinBytesToCompress),
        const ImageCompressConfig(
          enabled: true,
          quality: 70,
          maxLongEdge: 1024,
          includeTransparent: true,
        ),
      ),
      isNull,
    );
    expect(
      await ImageCompressor.compressBytes(
        img.encodeJpg(img.Image(width: 16, height: 16)),
        config,
      ),
      isNull,
    );

    final lowQualityJpeg = img.encodeJpg(_noiseImage(1600, 1000), quality: 1);
    expect(
      lowQualityJpeg.lengthInBytes,
      greaterThanOrEqualTo(ImageCompressor.kMinBytesToCompress),
    );
    expect(
      await ImageCompressor.compressBytes(
        lowQualityJpeg,
        const ImageCompressConfig(
          enabled: true,
          quality: 100,
          maxLongEdge: 2000,
          includeTransparent: false,
        ),
      ),
      isNull,
    );
  });

  test('reuses stored uploads and keeps differing images apart', () async {
    final temp = await Directory.systemTemp.createTemp(
      'kelivo_image_compressor_test_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final sourceDir = Directory(p.join(temp.path, 'source'))
      ..createSync(recursive: true);
    final uploadDir = Directory(p.join(temp.path, 'upload'));
    final source = File(p.join(sourceDir.path, 'photo.png'));
    await source.writeAsBytes(img.encodePng(_noiseImage(512, 512)));

    final first = await ImageCompressor.compressToUploadDir(
      source.path,
      uploadDir,
      config,
    );
    expect(first, isNotNull);
    final firstPath = first!.path;
    expect(first.reused, isFalse);
    expect(p.basename(firstPath), 'photo.jpg');

    // Re-importing the very same picture reuses the stored copy.
    final again = await ImageCompressor.compressToUploadDir(
      source.path,
      uploadDir,
      config,
    );
    expect(again?.path, firstPath);
    expect(again?.reused, isTrue);
    expect(uploadDir.listSync().whereType<File>(), hasLength(1));

    // A different picture under the same name gets a versioned name.
    final firstBytes = await File(firstPath).readAsBytes();
    final other = File(p.join(sourceDir.path, 'photo.png'));
    await other.writeAsBytes(img.encodePng(_noiseImage(480, 480)));
    final second = await ImageCompressor.compressToUploadDir(
      other.path,
      uploadDir,
      config,
    );
    expect(second, isNotNull);
    expect(second!.reused, isFalse);
    expect(p.basename(second.path), 'photo(1).jpg');
    expect(await File(firstPath).readAsBytes(), orderedEquals(firstBytes));

    // Re-importing a stored upload never rewrites it in place.
    expect(
      await ImageCompressor.compressToUploadDir(firstPath, uploadDir, config),
      isNotNull,
    );
    expect(await File(firstPath).readAsBytes(), orderedEquals(firstBytes));

    expect(
      await ImageCompressor.compressToUploadDir(
        p.join(sourceDir.path, 'missing.png'),
        uploadDir,
        config,
      ),
      isNull,
    );
  });

  test('concurrent imports never clobber each other', () async {
    final temp = await Directory.systemTemp.createTemp(
      'kelivo_image_compressor_test_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final sourceDir = Directory(p.join(temp.path, 'source'))
      ..createSync(recursive: true);
    final uploadDir = Directory(p.join(temp.path, 'upload'));
    final first = File(p.join(sourceDir.path, 'photo.png'));
    final second = File(p.join(sourceDir.path, 'other.png'));
    await first.writeAsBytes(img.encodePng(_noiseImage(512, 512)));
    await second.writeAsBytes(img.encodePng(_noiseImage(400, 400)));

    final paths = await Future.wait([
      ImageCompressor.compressToUploadDir(first.path, uploadDir, config),
      ImageCompressor.compressToUploadDir(second.path, uploadDir, config),
    ]);

    expect(paths, everyElement(isNotNull));
    expect(paths.map((write) => write?.path).toSet(), hasLength(2));
    for (final path in paths.nonNulls.map((write) => write.path)) {
      expect(
        img.JpegDecoder().isValidFile(await File(path).readAsBytes()),
        isTrue,
      );
    }
  });
}

img.Image _noiseImage(int width, int height, {bool withAlpha = false}) {
  final image = img.Image(
    width: width,
    height: height,
    numChannels: withAlpha ? 4 : 3,
  );
  final random = Random(7);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgba(
        x,
        y,
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
        255,
      );
    }
  }
  return image;
}

img.Image _opaqueIndexedImage(int width, int height) {
  final random = Random(7);
  final palette = img.PaletteUint8(256, 4);
  for (var i = 0; i < palette.numColors; i++) {
    palette.setRgba(
      i,
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      255,
    );
  }
  final image = img.Image(width: width, height: height, palette: palette);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelIndex(x, y, random.nextInt(256));
    }
  }
  return image;
}
