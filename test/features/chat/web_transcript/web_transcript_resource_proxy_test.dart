import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/chat/web_transcript/web_transcript_models.dart';
import 'package:Cuplivo/features/chat/web_transcript/web_transcript_resource_proxy.dart';

void main() {
  test('rejects non-HTTPS remote resources before network access', () async {
    final proxy = WebTranscriptResourceProxy();
    addTearDown(proxy.dispose);
    await expectLater(
      proxy.load(
        const WebTranscriptResource(
          id: 'image',
          source: 'http://example.com/image.png',
          kind: WebTranscriptResourceKind.image,
        ),
      ),
      throwsA(
        isA<WebTranscriptResourceException>().having(
          (error) => error.code,
          'code',
          'unsupported_scheme',
        ),
      ),
    );
  });

  test('never sends attachment bytes into WebView', () async {
    final proxy = WebTranscriptResourceProxy();
    addTearDown(proxy.dispose);
    await expectLater(
      proxy.load(
        const WebTranscriptResource(
          id: 'file',
          source: '/private/file.pdf',
          kind: WebTranscriptResourceKind.attachment,
        ),
      ),
      throwsA(
        isA<WebTranscriptResourceException>().having(
          (error) => error.code,
          'code',
          'attachment_not_embeddable',
        ),
      ),
    );
  });

  test('rejects loopback hosts to prevent local-network reads', () async {
    final proxy = WebTranscriptResourceProxy();
    addTearDown(proxy.dispose);
    await expectLater(
      proxy.load(
        const WebTranscriptResource(
          id: 'image',
          source: 'https://127.0.0.1/image.png',
          kind: WebTranscriptResourceKind.image,
        ),
      ),
      throwsA(
        isA<WebTranscriptResourceException>().having(
          (error) => error.code,
          'code',
          'private_remote_host',
        ),
      ),
    );
  });
}
