import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/message_part.dart';

void main() {
  group('ImagePart job progress', () {
    test('a promised image roundtrips its job id and state', () {
      const part = ImagePart(
        uri: '/data/assets/asset-1.png',
        assetId: 'asset-1',
        jobId: 'job-1',
        state: ImagePartState.pending,
      );

      final decoded = MessagePart.fromRow('image', part.encodePayload());

      expect(decoded, part);
      expect((decoded as ImagePart).jobId, 'job-1');
      expect(decoded.state, ImagePartState.pending);
    });

    test('a part without job fields decodes as a ready image', () {
      final decoded =
          MessagePart.fromRow(
                'image',
                '{"uri":"/data/assets/old.png","mime":"image/png"}',
              )
              as ImagePart;

      expect(decoded.state, isNull);
      expect(decoded.jobId, isNull);
      expect(decoded.unavailable, false);
    });

    test('an unknown future state degrades to ready, not a format error', () {
      final decoded =
          MessagePart.fromRow(
                'image',
                '{"uri":"/data/assets/a.png","state":"someday"}',
              )
              as ImagePart;

      expect(decoded.state, isNull);
    });

    test('the completed image keeps its job id and clears the state', () {
      const pending = ImagePart(
        uri: '/data/assets/asset-1.png',
        jobId: 'job-1',
        state: ImagePartState.pending,
      );

      final done = pending.withState(null, uri: '/data/assets/final.png');

      expect(done.jobId, 'job-1');
      expect(done.state, isNull);
      expect(done.uri, '/data/assets/final.png');
      expect(done.encodePayload(), isNot(contains('"state"')));
    });

    test('a failed job stays distinguishable from a missing file', () {
      const failed = ImagePart(
        uri: '/data/assets/asset-2.png',
        jobId: 'job-2',
        state: ImagePartState.failed,
      );

      final decoded =
          MessagePart.fromRow('image', failed.encodePayload()) as ImagePart;

      expect(decoded.state, ImagePartState.failed);
      expect(decoded.unavailable, false);
    });
  });
}
