import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/utils/multimodal_input_utils.dart';

void main() {
  group('inferMediaMimeFromSource', () {
    test('maps heic / heif (picker-supported) extensions', () {
      expect(inferMediaMimeFromSource('photo.heic'), 'image/heic');
      expect(inferMediaMimeFromSource('photo.HEIF'), 'image/heif');
    });

    test('keeps existing mappings intact', () {
      expect(inferMediaMimeFromSource('a.jpg'), 'image/jpeg');
      expect(inferMediaMimeFromSource('a.jpeg'), 'image/jpeg');
      expect(inferMediaMimeFromSource('a.png'), 'image/png');
      expect(inferMediaMimeFromSource('a.webp'), 'image/webp');
      expect(inferMediaMimeFromSource('a.gif'), 'image/gif');
    });

    test('does not map formats outside the accepted image set', () {
      expect(inferMediaMimeFromSource('scan.bmp'), '');
      expect(inferMediaMimeFromSource('scan.tif'), '');
      expect(inferMediaMimeFromSource('scan.tiff'), '');
      expect(inferMediaMimeFromSource('next.avif'), '');
    });
  });

  group('imeImageMimeTypes', () {
    test('declares the wildcard plus every accepted concrete type', () {
      expect(
        imeImageMimeTypes,
        containsAll(<String>[
          'image/*',
          'image/png',
          'image/jpeg',
          'image/jpg',
          'image/gif',
          'image/webp',
          'image/heic',
          'image/heif',
        ]),
      );
    });

    test('stays aligned with the extension map and excludes others', () {
      expect(imeImageMimeTypes.toSet(), <String>{
        'image/*',
        ...imeImageExtensionByMime.keys,
      });
      expect(imeImageMimeTypes, isNot(contains('image/bmp')));
      expect(imeImageMimeTypes, isNot(contains('image/tiff')));
      expect(imeImageMimeTypes, isNot(contains('image/avif')));
    });
  });

  group('sniffImageMimeFromBytes', () {
    test('recognizes png / jpeg / gif / webp', () {
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
      expect(
        sniffImageMimeFromBytes(const [
          0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, //
          0x57, 0x45, 0x42, 0x50,
        ]),
        'image/webp',
      );
    });

    test('recognizes ISO BMFF brands heic / heif', () {
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
      // Formats outside the accepted set (avif) and non-image ISO BMFF
      // (mp4/isom) stay unrecognized.
      expect(sniffImageMimeFromBytes(isoBmff('avif')), isNull);
      expect(sniffImageMimeFromBytes(isoBmff('avis')), isNull);
      expect(sniffImageMimeFromBytes(isoBmff('isom')), isNull);
    });

    test('returns null for an unrecognized or empty payload', () {
      expect(sniffImageMimeFromBytes(const []), isNull);
      expect(sniffImageMimeFromBytes(const [0x00, 0x01, 0x02, 0x03]), isNull);
      // bmp / tiff are outside the accepted set and not detected here.
      expect(sniffImageMimeFromBytes(const [0x42, 0x4D, 0x00]), isNull);
      expect(sniffImageMimeFromBytes(const [0x49, 0x49, 0x2A, 0x00]), isNull);
    });
  });

  group('inferImageExtension', () {
    test('maps recognized bytes to the accepted extension', () {
      expect(inferImageExtension(const [0x89, 0x50, 0x4E, 0x47]), 'png');
      expect(inferImageExtension(const [0xFF, 0xD8, 0xFF, 0xE0]), 'jpg');
      expect(inferImageExtension(const [0x47, 0x49, 0x46, 0x38]), 'gif');
      expect(
        inferImageExtension(const [
          0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, //
          0x57, 0x45, 0x42, 0x50,
        ]),
        'webp',
      );
      expect(
        inferImageExtension(const [
          0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, //
          0x68, 0x65, 0x69, 0x63,
        ]),
        'heic',
      );
      expect(
        inferImageExtension(const [
          0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, //
          0x6D, 0x69, 0x66, 0x31,
        ]),
        'heif',
      );
    });

    test('rejects bytes outside the accepted set', () {
      // bmp / tiff / avif are not accepted and not sniffed.
      expect(inferImageExtension(const [0x42, 0x4D, 0x00]), isNull);
      expect(inferImageExtension(const [0x49, 0x49, 0x2A, 0x00]), isNull);
      expect(
        inferImageExtension(const [
          0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, //
          0x61, 0x76, 0x69, 0x66,
        ]),
        isNull,
      );
      // Vector / unknown / empty payloads are not guessed as png.
      expect(inferImageExtension(const []), isNull);
      expect(inferImageExtension(const [0x01, 0x02, 0x03]), isNull);
      expect(inferImageExtension('<svg/>'.codeUnits), isNull);
    });
  });
}
