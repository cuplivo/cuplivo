import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/harness/services/dsh_preview_kind.dart';

void main() {
  test('extensions route to the documented renderer', () {
    expect(
      classifyDshRemotePreview('docs/report.pdf'),
      DshRemotePreviewKind.pdf,
    );
    expect(
      classifyDshRemotePreview('assets/pixel.png'),
      DshRemotePreviewKind.image,
    );
    expect(classifyDshRemotePreview('notes.md'), DshRemotePreviewKind.text);
    expect(
      classifyDshRemotePreview('data/table.csv'),
      DshRemotePreviewKind.text,
    );
    expect(classifyDshRemotePreview('hello.txt'), DshRemotePreviewKind.text);
    expect(
      classifyDshRemotePreview('data/blob.bin'),
      DshRemotePreviewKind.text,
      reason: 'unknown bodies try the text read, then fall back honestly',
    );
    expect(
      classifyDshRemotePreview('docs/spec.docx'),
      DshRemotePreviewKind.office,
    );
  });

  test('a specific media type wins over the extension', () {
    expect(
      classifyDshRemotePreview('download', mediaType: 'image/webp'),
      DshRemotePreviewKind.image,
    );
    expect(
      classifyDshRemotePreview('download', mediaType: 'application/pdf'),
      DshRemotePreviewKind.pdf,
    );
    expect(
      classifyDshRemotePreview(
        'download',
        mediaType:
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      ),
      DshRemotePreviewKind.office,
    );
  });

  test('an unknown path attempts text instead of claiming a binary kind', () {
    expect(classifyDshRemotePreview('LICENSE'), DshRemotePreviewKind.text);
  });
}
