import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/features/image_job/models/image_job.dart';
import 'package:Cuplivo/features/image_job/services/image_job_coordinator.dart';

ImageJob _job({
  String id = 'job-1',
  ImageJobState state = ImageJobState.completed,
  String? mime,
}) {
  return ImageJob(
    id: id,
    conversationId: 'c1',
    messageId: 'm1',
    toolCallId: 't1',
    idempotencyKey: 'key-1',
    prompt: 'a cat',
    assetId: 'img_abc',
    uri: '/data/images/img_abc.png',
    state: state,
    mime: mime,
    createdAt: DateTime(2026, 11, 18, 10),
    startedAt: DateTime(2026, 11, 18, 10),
  );
}

void main() {
  group('freshenImageParts', () {
    test('a picture that finished after the snapshot replaces the promise', () {
      // The reply froze its parts while drawing; the picture landed before the
      // write. Keeping the snapshot would make the finished file unreachable —
      // no bytes to send, and "interrupted" after a restart.
      final snapshot = <MessagePart>[
        TextPart('here you go'),
        const ImagePart(
          uri: '/data/images/img_abc.png',
          assetId: 'img_abc',
          jobId: 'job-1',
          state: ImagePartState.pending,
        ),
      ];
      final jobs = <String, ImageJob>{'job-1': _job(mime: 'image/jpeg')};

      final freshened = freshenImageParts(snapshot, (id) => jobs[id]);

      final part = freshened[1] as ImagePart;
      expect(part.state, isNull);
      expect(part.hasBytes, isTrue);
      // The type the backend returned, not the `.png` in the promised path.
      expect(part.mime, 'image/jpeg');
      expect(freshened[0], same(snapshot[0]));
    });

    test('a snapshot that already agrees is returned as the same list', () {
      // No churn: the caller compares by identity to decide whether to rewrite.
      final parts = <MessagePart>[
        const ImagePart(
          uri: '/data/images/img_abc.png',
          assetId: 'img_abc',
          jobId: 'job-1',
        ),
      ];
      final jobs = <String, ImageJob>{'job-1': _job()};

      expect(freshenImageParts(parts, (id) => jobs[id]), same(parts));
    });

    test('a job nobody knows leaves its part alone', () {
      // After a restart there is no job; the persisted part is all that is left.
      final parts = <MessagePart>[
        const ImagePart(
          uri: '/data/images/img_abc.png',
          assetId: 'img_abc',
          jobId: 'job-gone',
          state: ImagePartState.interrupted,
        ),
      ];

      expect(freshenImageParts(parts, (_) => null), same(parts));
    });

    test('a failed job explains itself even when the snapshot did not', () {
      final parts = <MessagePart>[
        const ImagePart(
          uri: '/data/images/img_abc.png',
          assetId: 'img_abc',
          jobId: 'job-1',
          state: ImagePartState.pending,
        ),
      ];
      final failed = _job(
        state: ImageJobState.failed,
      ).copyWith(error: 'The reply contained no image link.');

      final part = freshenImageParts(parts, (_) => failed).single as ImagePart;

      expect(part.state, ImagePartState.failed);
      expect(part.failureReason, 'The reply contained no image link.');
      expect(part.hasBytes, isFalse);
    });
  });
}
