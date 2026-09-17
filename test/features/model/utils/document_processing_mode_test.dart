import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/utils/multimodal_input_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Assistant document processing fields', () {
    test('defaults are extract/extract/extract/auto', () {
      final a = Assistant(id: 'a', name: 'A');
      expect(a.docxMode, 'extract');
      expect(a.pdfMode, 'extract');
      expect(a.otherOfficeMode, 'extract');
      expect(a.ocrMode, 'auto');
    });

    test('JSON roundtrip preserves all four modes', () {
      final a = Assistant(
        id: 'a',
        name: 'A',
        docxMode: 'direct',
        pdfMode: 'discard',
        otherOfficeMode: 'direct',
        ocrMode: 'always',
      );
      final restored = Assistant.fromJson(a.toJson());
      expect(restored.docxMode, 'direct');
      expect(restored.pdfMode, 'discard');
      expect(restored.otherOfficeMode, 'direct');
      expect(restored.ocrMode, 'always');
    });

    test('fromJson tolerates legacy payloads without the fields', () {
      final restored = Assistant.fromJson({'id': 'a', 'name': 'A'});
      expect(restored.docxMode, 'extract');
      expect(restored.ocrMode, 'auto');
    });

    test('copyWith updates modes individually', () {
      final a = Assistant(id: 'a', name: 'A');
      expect(a.copyWith(ocrMode: 'never').ocrMode, 'never');
      expect(a.copyWith(docxMode: 'direct').docxMode, 'direct');
      expect(a.copyWith(pdfMode: 'discard').pdfMode, 'discard');
      expect(a.copyWith(otherOfficeMode: 'direct').otherOfficeMode, 'direct');
    });
  });

  group('isOfficeDocumentMime', () {
    test('matches office families and rejects others', () {
      expect(isOfficeDocumentMime('application/msword'), isTrue);
      expect(
        isOfficeDocumentMime(
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        ),
        isTrue,
      );
      expect(
        isOfficeDocumentMime('application/vnd.ms-excel.sheet.macroenabled.12'),
        isTrue,
      );
      expect(isOfficeDocumentMime('application/pdf'), isFalse);
      expect(isOfficeDocumentMime('image/png'), isFalse);
      expect(isOfficeDocumentMime('text/plain'), isFalse);
    });
  });
}
