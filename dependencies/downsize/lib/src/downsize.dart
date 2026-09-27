import 'dart:typed_data';

import 'package:downsize/downsize.dart';
import 'package:image/image.dart';

/// Output encoding format.
enum DownsizeFormat { jpeg, png }

/// Config class holds raw data with compression options.
class Config {
  /// initial image data.
  ///
  /// Required by [Downsize.compress]; unused by [Downsize.compressDecoded],
  /// which works on an already-decoded [Image].
  final Uint8List? data;

  /// Output encoding format. JPEG flattens any alpha onto white; PNG keeps it.
  final DownsizeFormat format;

  /// JPEG encoding quality.
  final int quality;

  /// minimum image quality.
  final int minQuality;

  /// desired file size.
  final double? maxSize;

  /// Maximum length of the image's longest edge.
  final int? maxLongEdge;

  Config({
    this.data,
    this.format = DownsizeFormat.jpeg,
    this.quality = 90,
    this.minQuality = 60,
    this.maxSize,
    this.maxLongEdge,
  });
}

class Downsize {
  static Future<Uint8List?> downsize({
    required Uint8List data,
    DownsizeFormat format = DownsizeFormat.jpeg,
    int quality = 90,
    int minQuality = 60,
    double? maxSize,
    int? maxLongEdge,
  }) async {
    if (data.isEmpty) return data;
    return Downsize().compress(
      Config(
        data: data,
        format: format,
        quality: quality,
        minQuality: minQuality,
        maxSize: maxSize,
        maxLongEdge: maxLongEdge,
      ),
    );
  }

  /// Decode and Compress image data.
  Uint8List? compress(Config config) {
    final bytes = config.data;
    if (bytes == null) {
      throw ArgumentError('Config.data is required for compress()');
    }
    Image? image = decodeImage(bytes, frame: 0);
    if (image == null) {
      throw Exception("Unsupported image type.");
    }

    return compressDecoded(image, config);
  }

  /// Runs the same prepare + encode pipeline as [compress] on an
  /// already-decoded image, so callers that cache the decode can preview and
  /// produce artifacts through one identical parameter path.
  Uint8List compressDecoded(Image image, Config config) {
    switch (config.format) {
      case DownsizeFormat.png:
        return encodePng(_prepareImage(image, config), level: 6);
      case DownsizeFormat.jpeg:
        return compressJpg(image: image, config: config);
    }
  }

  /// Compress JPG image.
  Uint8List compressJpg({
    required Image image,
    required Config config,
    int? quality,
    bool preTreatment = true,
  }) {
    if (preTreatment) {
      image = _prepareImage(image, config);
    }

    final currentQuality = (quality ?? config.quality).clamp(1, 100).toInt();
    final minQuality = config.minQuality.clamp(1, 100).toInt();
    final im = encodeJpg(image, quality: currentQuality);
    final nextQuality = currentQuality - 10;
    if (config.maxSize != null &&
        im.sizeKb > config.maxSize! &&
        nextQuality >= minQuality) {
      return compressJpg(
        image: image,
        config: config,
        quality: nextQuality,
        preTreatment: false,
      );
    }

    return im;
  }

  /// Compress PNG image.
  ///
  /// PNG is lossless: there is no quality search, and `maxSize`/`minQuality`
  /// do not apply. Transparency is preserved.
  Uint8List compressPng({
    required Image image,
    required Config config,
    int level = 6,
  }) =>
      encodePng(_prepareImage(image, config), level: level);

  /// Resize the image to fit within [maxLongEdge].
  Image dynamicResize(Image image, {int? maxLongEdge}) {
    if (maxLongEdge == null ||
        maxLongEdge <= 0 ||
        (image.width <= maxLongEdge && image.height <= maxLongEdge)) {
      return image;
    }

    return copyResize(
      image,
      width: image.width >= image.height ? maxLongEdge : null,
      height: image.height > image.width ? maxLongEdge : null,
      interpolation: Interpolation.average,
    );
  }

  Image _prepareImage(Image image, Config config) {
    image = bakeOrientation(image);
    image.exif.clear();

    // JPEG has no alpha channel; flatten onto white so transparent regions do
    // not turn black. PNG output keeps transparency as-is.
    if (config.format == DownsizeFormat.jpeg && image.hasAlpha) {
      final background = Image(
        width: image.width,
        height: image.height,
        numChannels: 3,
      )..clear(ColorRgb8(255, 255, 255));
      image = compositeImage(background, image);
    }

    return dynamicResize(image, maxLongEdge: config.maxLongEdge);
  }
}
