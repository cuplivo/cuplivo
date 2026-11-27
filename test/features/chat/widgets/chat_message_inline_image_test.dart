import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/features/chat/widgets/chat_message_widget.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('inline ImagePart render skips unavailable and empty URIs', () {
    expect(
      shouldInlineImagePart(const ImagePart(uri: 'https://example.com/a.png')),
      isTrue,
    );
    expect(
      shouldInlineImagePart(
        const ImagePart(uri: 'https://example.com/a.png', unavailable: true),
      ),
      isFalse,
    );
    expect(shouldInlineImagePart(const ImagePart(uri: '')), isFalse);
    expect(shouldInlineImagePart(const ImagePart(uri: '   ')), isFalse);
  });
}
