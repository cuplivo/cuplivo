import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/features/home/services/message_generation_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('persisted user message parts', () {
    test('builds text then image/file parts without markers', () async {
      final parts =
          await MessageGenerationService.buildPersistedUserMessageParts(
            const ChatInputData(
              text: '  edited prompt  ',
              imagePaths: ['C:/tmp/image.png'],
              documents: [
                DocumentAttachment(
                  path: 'C:/tmp/spec.pdf',
                  fileName: 'spec.pdf',
                  mime: 'application/pdf',
                ),
              ],
            ),
            assistant: null,
          );

      expect(parts, hasLength(3));
      expect(parts[0], isA<TextPart>());
      expect((parts[0] as TextPart).text, 'edited prompt');
      expect(parts[1], isA<ImagePart>());
      expect((parts[1] as ImagePart).uri, 'C:/tmp/image.png');
      expect((parts[1] as ImagePart).mime, 'image/png');
      expect(parts[2], isA<FilePart>());
      final file = parts[2] as FilePart;
      expect(file.uri, 'C:/tmp/spec.pdf');
      expect(file.name, 'spec.pdf');
      expect(file.mime, 'application/pdf');

      // No marker strings anywhere in payloads.
      for (final part in parts) {
        expect(part.encodePayload().contains('[image:'), isFalse);
        expect(part.encodePayload().contains('[file:'), isFalse);
      }
    });

    test('allows attachment-only messages with empty text part', () async {
      final parts =
          await MessageGenerationService.buildPersistedUserMessageParts(
            const ChatInputData(text: '', imagePaths: ['C:/tmp/image.png']),
            assistant: null,
          );

      expect(parts, hasLength(2));
      expect((parts[0] as TextPart).text, '');
      expect(parts[1], isA<ImagePart>());
    });

    test('filename with ] or | survives as FilePart name', () async {
      final parts =
          await MessageGenerationService.buildPersistedUserMessageParts(
            const ChatInputData(
              text: 'x',
              documents: [
                DocumentAttachment(
                  path: 'C:/tmp/a.pdf',
                  fileName: 'na|me].pdf',
                  mime: 'application/pdf',
                ),
              ],
            ),
            assistant: null,
          );
      expect((parts[1] as FilePart).name, 'na|me].pdf');
    });
  });
}
