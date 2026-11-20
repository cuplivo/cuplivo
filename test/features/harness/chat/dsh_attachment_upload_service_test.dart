import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/features/harness/controllers/dsh_chat_session.dart';
import 'package:Cuplivo/features/harness/services/dsh_attachment_upload_service.dart';

void main() {
  group('DshAttachmentUploadService', () {
    late Map<String, Uint8List> files;
    late List<({String name, String? mediaType, int bytes})> uploads;

    DshAttachmentUploadService service({DshImageLimits? limits}) {
      return DshAttachmentUploadService(
        readFile: (path) async {
          final bytes = files[path];
          if (bytes == null) throw const FileNotFoundFailure();
          return bytes;
        },
        uploadFile: (bytes, {required name, mediaType}) async {
          uploads.add((name: name, mediaType: mediaType, bytes: bytes.length));
          return 'receipt-1';
        },
        imageLimits: () => limits,
      );
    }

    ChatInputData input({
      String text = 'hi',
      List<String> images = const <String>[],
      List<DocumentAttachment> documents = const <DocumentAttachment>[],
    }) {
      return ChatInputData(
        text: text,
        imagePaths: images,
        documents: documents,
      );
    }

    setUp(() {
      files = <String, Uint8List>{};
      uploads = <({String name, String? mediaType, int bytes})>[];
    });

    test('an image travels inline with an inferred media type', () async {
      files['/tmp/a.jpg'] = Uint8List.fromList(<int>[1, 2, 3]);

      final prepared = await service().prepare(
        input(images: <String>['/tmp/a.jpg']),
      );

      expect(prepared, hasLength(1));
      expect(prepared.single.isImage, isTrue);
      expect(prepared.single.name, 'a.jpg');
      expect(prepared.single.mediaType, 'image/jpeg');
      expect(prepared.single.bytes, <int>[1, 2, 3]);
      expect(uploads, isEmpty);
    });

    test('a data-URL image is decoded, not uploaded', () async {
      final encoded = base64Encode(<int>[9, 8, 7]);
      final prepared = await service().prepare(
        input(images: <String>['data:image/png;base64,$encoded']),
      );

      expect(prepared.single.bytes, <int>[9, 8, 7]);
      expect(uploads, isEmpty);
    });

    test('a document is uploaded and referenced by its receipt', () async {
      files['/tmp/notes.txt'] = Uint8List.fromList(<int>[4, 5, 6]);

      final prepared = await service().prepare(
        input(
          documents: <DocumentAttachment>[
            const DocumentAttachment(
              path: '/tmp/notes.txt',
              fileName: 'notes.txt',
              mime: 'text/plain',
            ),
          ],
        ),
      );

      expect(prepared, hasLength(1));
      expect(prepared.single.isImage, isFalse);
      expect(prepared.single.receiptId, 'receipt-1');
      expect(prepared.single.name, 'notes.txt');
      expect(uploads.single.name, 'notes.txt');
      expect(uploads.single.mediaType, 'text/plain');
    });

    test('more images than the Host allows is refused', () async {
      files['/tmp/a.png'] = Uint8List.fromList(<int>[1]);
      files['/tmp/b.png'] = Uint8List.fromList(<int>[2]);

      await expectLater(
        service(
          limits: const DshImageLimits(maxImagesPerMessage: 1),
        ).prepare(input(images: <String>['/tmp/a.png', '/tmp/b.png'])),
        throwsA(
          isA<DshAttachmentFailure>().having(
            (failure) => failure.kind,
            'kind',
            DshAttachmentFailureKind.tooManyImages,
          ),
        ),
      );
    });

    test('a single image over maxImageBytes is refused', () async {
      files['/tmp/a.png'] = Uint8List.fromList(<int>[1, 2, 3, 4]);

      await expectLater(
        service(
          limits: const DshImageLimits(maxImageBytes: 3),
        ).prepare(input(images: <String>['/tmp/a.png'])),
        throwsA(
          isA<DshAttachmentFailure>().having(
            (failure) => failure.kind,
            'kind',
            DshAttachmentFailureKind.imageTooLarge,
          ),
        ),
      );
    });

    test('images over maxMessageImageBytes are refused together', () async {
      files['/tmp/a.png'] = Uint8List.fromList(<int>[1, 2]);
      files['/tmp/b.png'] = Uint8List.fromList(<int>[3, 4]);

      await expectLater(
        service(
          limits: const DshImageLimits(maxMessageImageBytes: 3),
        ).prepare(input(images: <String>['/tmp/a.png', '/tmp/b.png'])),
        throwsA(
          isA<DshAttachmentFailure>().having(
            (failure) => failure.kind,
            'kind',
            DshAttachmentFailureKind.imagesTooLarge,
          ),
        ),
      );
    });

    test('a media type the Host does not accept is refused', () async {
      files['/tmp/a.gif'] = Uint8List.fromList(<int>[1]);

      await expectLater(
        service(
          limits: const DshImageLimits(mediaTypes: <String>['image/png']),
        ).prepare(input(images: <String>['/tmp/a.gif'])),
        throwsA(
          isA<DshAttachmentFailure>().having(
            (failure) => failure.kind,
            'kind',
            DshAttachmentFailureKind.unsupportedImageType,
          ),
        ),
      );
    });

    test('an unreadable staged path is refused', () async {
      await expectLater(
        service().prepare(input(images: <String>['/tmp/missing.png'])),
        throwsA(
          isA<DshAttachmentFailure>().having(
            (failure) => failure.kind,
            'kind',
            DshAttachmentFailureKind.readFailed,
          ),
        ),
      );
    });
  });
}

class FileNotFoundFailure implements Exception {
  const FileNotFoundFailure();
}
