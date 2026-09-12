import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/utils/multimodal_input_utils.dart';

void main() {
  group('inferMediaMimeFromSource', () {
    test('maps extended raster image extensions', () {
      expect(inferMediaMimeFromSource('photo.heic'), 'image/heic');
      expect(inferMediaMimeFromSource('photo.HEIF'), 'image/heif');
      expect(inferMediaMimeFromSource('scan.bmp'), 'image/bmp');
      expect(inferMediaMimeFromSource('scan.tif'), 'image/tiff');
      expect(inferMediaMimeFromSource('scan.tiff'), 'image/tiff');
      expect(inferMediaMimeFromSource('next.avif'), 'image/avif');
    });

    test('keeps existing mappings intact', () {
      expect(inferMediaMimeFromSource('a.jpg'), 'image/jpeg');
      expect(inferMediaMimeFromSource('a.jpeg'), 'image/jpeg');
      expect(inferMediaMimeFromSource('a.png'), 'image/png');
      expect(inferMediaMimeFromSource('a.webp'), 'image/webp');
      expect(inferMediaMimeFromSource('a.gif'), 'image/gif');
    });
  });

  group('sniffImageMimeFromBytes', () {
    test('recognizes png / jpeg / gif / bmp / webp / tiff', () {
      expect(
        sniffImageMimeFromBytes(const [0x89, 0x50, 0x4E, 0x47, 0x00]),
        'image/png',
      );
      expect(
        sniffImageMimeFromBytes(const [0xFF, 0xD8, 0xFF, 0xE0]),
        'image/jpeg',
      );
      expect(
        sniffImageMimeFromBytes(const [0x47, 0x49, 0x46, 0x38, 0x39]),
        'image/gif',
      );
      expect(sniffImageMimeFromBytes(const [0x42, 0x4D, 0x00]), 'image/bmp');
      expect(
        sniffImageMimeFromBytes(const [
          0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, //
          0x57, 0x45, 0x42, 0x50,
        ]),
        'image/webp',
      );
      // Little-endian II*\0 / big-endian MM\0*
      expect(
        sniffImageMimeFromBytes(const [0x49, 0x49, 0x2A, 0x00]),
        'image/tiff',
      );
      expect(
        sniffImageMimeFromBytes(const [0x4D, 0x4D, 0x00, 0x2A]),
        'image/tiff',
      );
    });

    test('recognizes ISO BMFF brands heic / heif / avif', () {
      List<int> isoBmff(String brand) => [
        0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, //
        ...brand.codeUnits,
      ];
      expect(sniffImageMimeFromBytes(isoBmff('heic')), 'image/heic');
      expect(sniffImageMimeFromBytes(isoBmff('heix')), 'image/heic');
      expect(sniffImageMimeFromBytes(isoBmff('hevc')), 'image/heic');
      expect(sniffImageMimeFromBytes(isoBmff('hevx')), 'image/heic');
      expect(sniffImageMimeFromBytes(isoBmff('heif')), 'image/heif');
      expect(sniffImageMimeFromBytes(isoBmff('mif1')), 'image/heif');
      expect(sniffImageMimeFromBytes(isoBmff('msf1')), 'image/heif');
      expect(sniffImageMimeFromBytes(isoBmff('avif')), 'image/avif');
      expect(sniffImageMimeFromBytes(isoBmff('avis')), 'image/avif');
      // Non-image ISO BMFF (e.g. mp4) stays unrecognized.
      expect(sniffImageMimeFromBytes(isoBmff('isom')), isNull);
    });

    test('returns null for an unrecognized or empty payload', () {
      expect(sniffImageMimeFromBytes(const []), isNull);
      expect(sniffImageMimeFromBytes(const [0x00, 0x01, 0x02, 0x03]), isNull);
    });
  });

  group('inferImageExtension', () {
    test('trusts a known subtype', () {
      expect(inferImageExtension('image/jpeg', const []), 'jpg');
      expect(inferImageExtension('image/jpg', const []), 'jpg');
      expect(inferImageExtension('image/png', const []), 'png');
      expect(inferImageExtension('image/gif', const []), 'gif');
      expect(inferImageExtension('image/webp', const []), 'webp');
      expect(inferImageExtension('image/heic', const []), 'heic');
      expect(inferImageExtension('image/heif', const []), 'heif');
      expect(inferImageExtension('image/bmp', const []), 'bmp');
      expect(inferImageExtension('image/tiff', const []), 'tiff');
      expect(inferImageExtension('image/avif', const []), 'avif');
    });

    test('sniffs the literal wildcard mime', () {
      expect(inferImageExtension('image/*', const [0xFF, 0xD8, 0xFF]), 'jpg');
      expect(
        inferImageExtension('image/*', const [0x89, 0x50, 0x4E, 0x47]),
        'png',
      );
      expect(
        inferImageExtension('image/*', const [0x49, 0x49, 0x2A, 0x00]),
        'tiff',
      );
      expect(
        inferImageExtension('image/*', const [
          0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, //
          0x6D, 0x69, 0x66, 0x31,
        ]),
        'heif',
      );
    });

    test('sniffs an unknown subtype and falls back to png', () {
      expect(
        inferImageExtension('image/x-weird', const [0x47, 0x49, 0x46, 0x38]),
        'gif',
      );
      expect(inferImageExtension('image/x-weird', const [0x01]), 'png');
    });
  });
}
