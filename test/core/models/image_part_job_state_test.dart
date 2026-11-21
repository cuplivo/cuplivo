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

    test('a restore pass keeps every job field it was not asked to change', () {
      // Availability is local restore bookkeeping. Rebuilding the part field by
      // field there used to erase the job, which also flipped `hasBytes` back to
      // true for a picture that was still only a promise.
      const part = ImagePart(
        uri: '/data/assets/asset-3.png',
        mime: 'image/png',
        assetId: 'asset-3',
        jobId: 'job-3',
        state: ImagePartState.pending,
        prompt: 'a cat',
        model: 'gpt-image-1',
        durationMs: 12600,
      );

      final moved = part.copyWith(
        uri: '/data/assets/asset-3-restored.png',
        unavailable: true,
      );

      expect(moved.jobId, 'job-3');
      expect(moved.state, ImagePartState.pending);
      expect(moved.prompt, 'a cat');
      expect(moved.model, 'gpt-image-1');
      expect(moved.durationMs, 12600);
      expect(moved.assetId, 'asset-3');
      expect(moved.mime, 'image/png');
      expect(moved.uri, '/data/assets/asset-3-restored.png');
      expect(moved.unavailable, isTrue);
      // The promise is still a promise: no bytes to send yet.
      expect(moved.hasBytes, isFalse);
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
