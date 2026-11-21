import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/image_job/models/image_job.dart';
import 'package:Cuplivo/features/image_job/services/image_backends.dart';
import 'package:Cuplivo/features/image_job/services/image_job_manager.dart';

ImageJobManager _manager({
  ImageJobRunner? runner,
  Duration timeout = const Duration(seconds: 5),
}) {
  return ImageJobManager(
    runner ?? (_) async => const ImageJobOutcome(uri: '/tmp/done.png'),
    jobTimeout: timeout,
  );
}

ImageJob _create(
  ImageJobManager manager, {
  String key = 'job-1',
  String conversationId = 'c1',
  String messageId = 'm1',
  String toolCallId = 't1',
}) {
  return manager.create(
    idempotencyKey: key,
    conversationId: conversationId,
    messageId: messageId,
    toolCallId: toolCallId,
    prompt: 'a quiet bookshop',
    assetId: 'asset-1',
    uri: '/tmp/asset-1.png',
    aspectRatio: '3:2',
  );
}

void main() {
  test('create is idempotent: the same key hands back the same job', () {
    final manager = _manager();
    final first = _create(manager);
    final second = _create(manager);
    expect(identical(first, second), true);
    expect(manager.jobs.length, 1);
    expect(first.state, ImageJobState.queued);
    expect(first.aspectRatio, '3:2');
  });

  test('there is no cap: a model in a loop is refused by nobody', () {
    final manager = _manager();
    for (var i = 0; i < 5; i++) {
      _create(manager, key: 'job-$i');
    }
    expect(manager.jobs.length, 5);
  });

  group('jobDuration', () {
    test('a job still running has no duration', () {
      expect(jobDuration(_create(_manager())), isNull);
    });

    test('a backwards clock step reports zero, not a negative', () {
      // `startedAt`/`finishedAt` are wall-clock readings. A negative durationMs
      // is not cosmetic: `ImagePart` decodes it as `invalid_duration`, so the
      // whole part hydrates as MalformedPart and the picture disappears.
      final job = _create(_manager()).copyWith(
        startedAt: DateTime(2026, 11, 18, 12, 0, 30),
        finishedAt: DateTime(2026, 11, 18, 12, 0, 0),
      );

      expect(jobDuration(job), Duration.zero);
    });

    test('an ordinary job measures from start to finish', () {
      final job = _create(_manager()).copyWith(
        startedAt: DateTime(2026, 11, 18, 12, 0, 0),
        finishedAt: DateTime(2026, 11, 18, 12, 0, 12, 600),
      );

      expect(jobDuration(job), const Duration(milliseconds: 12600));
    });
  });

  test('a finished job stays, so a re-render does not pay twice', () async {
    final manager = _manager();
    final job = _create(manager, key: 'a');
    await manager.start(job.id);
    expect(manager.byId(job.id)!.state, ImageJobState.completed);
    final again = _create(manager, key: 'a');
    expect(identical(again, manager.byId(job.id)), true);
    expect(again.state, ImageJobState.completed);
  });

  test(
    'start resolves with the runner result and notifies listeners',
    () async {
      var notifications = 0;
      final manager = _manager(
        runner: (_) async => const ImageJobOutcome(uri: '/tmp/final.png'),
      )..addListener(() => notifications += 1);

      final job = _create(manager);
      final settled = await manager.start(job.id);

      expect(settled.state, ImageJobState.completed);
      expect(settled.resultUri, '/tmp/final.png');
      expect(settled.uri, '/tmp/asset-1.png');
      expect(settled.startedAt, isNotNull);
      expect(settled.finishedAt, isNotNull);
      expect(notifications, greaterThanOrEqualTo(2));
    },
  );

  test('a runner that outlives the timeout sees it is no longer wanted', () async {
    // `Future.timeout` completes the manager's wrapper, not the runner's future:
    // a late answer keeps running and would write its bytes at the promised path
    // for a job the user was told had failed. The coordinator checks liveness
    // before writing; this pins the contract that check relies on — by the time
    // the runner continues, the job is already terminal.
    late ImageJobState stateSeenByRunner;
    // `late` so the runner can read the manager it is being installed on.
    late final ImageJobManager manager;
    manager = _manager(
      timeout: const Duration(milliseconds: 20),
      runner: (job) async {
        await Future<void>.delayed(const Duration(milliseconds: 120));
        stateSeenByRunner = manager.byId(job.id)!.state;
        return const ImageJobOutcome(uri: '/tmp/late.png');
      },
    );
    final job = _create(manager);

    final settled = await manager.start(job.id);
    expect(settled.state, ImageJobState.failed);
    expect(settled.errorCode, 'timeout');

    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(stateSeenByRunner, ImageJobState.failed);
    expect(manager.byId(job.id)!.resultUri, isNull);
  });

  test('a job that outlives the timeout fails, it does not hang', () async {
    final gate = Completer<ImageJobOutcome>();
    final manager = _manager(
      runner: (_) => gate.future,
      timeout: const Duration(milliseconds: 30),
    );
    final job = _create(manager);

    final settled = await manager.start(job.id);

    expect(settled.state, ImageJobState.failed);
    expect(settled.errorCode, 'timeout');
    // The card shows this line, so it has to be a sentence, not a category.
    expect(settled.error, contains('seconds'));
  });

  test('a throwing runner is a provider failure, not a crash', () async {
    final manager = _manager(
      runner: (_) async => throw const ImageBackendException(
        ImageBackendFailure.noImage,
        'The reply contained no image link.',
      ),
    );
    final job = _create(manager);

    final settled = await manager.start(job.id);

    expect(settled.state, ImageJobState.failed);
    expect(settled.errorCode, 'provider_error');
    // The backend's own words survive to the part the card reads.
    expect(settled.error, 'The reply contained no image link.');
  });

  test('the backend\'s mime travels on the job', () async {
    // The promised file is named `.png` whatever came back, so the type has to
    // ride on the job — otherwise a JPEG is stored and re-sent as `image/png`.
    final manager = _manager(
      runner: (_) async =>
          const ImageJobOutcome(uri: '/tmp/out.png', mime: 'image/jpeg'),
    );
    final job = _create(manager);

    final settled = await manager.start(job.id);

    expect(settled.state, ImageJobState.completed);
    expect(settled.mime, 'image/jpeg');
  });
}
