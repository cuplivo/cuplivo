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
    expect(manager.activeCount('c1'), 5);
    expect(manager.jobs.length, 5);
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

  test('cancel wins over a runner that finishes afterwards', () async {
    final gate = Completer<ImageJobOutcome>();
    final manager = _manager(runner: (_) => gate.future);
    final job = _create(manager);

    final running = manager.start(job.id);
    await Future<void>.delayed(Duration.zero);
    expect(manager.byId(job.id)!.state, ImageJobState.running);
    expect(manager.cancel(job.id), true);

    gate.complete(const ImageJobOutcome(uri: '/tmp/late.png'));
    final settled = await running;

    expect(settled.state, ImageJobState.cancelled);
    expect(settled.resultUri, isNull);
    expect(manager.cancel(job.id), false);
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
    expect(manager.activeCount('c1'), 0);
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

  test('job states describe liveness honestly', () {
    const terminal = [
      ImageJobState.completed,
      ImageJobState.failed,
      ImageJobState.cancelled,
      ImageJobState.interrupted,
    ];
    for (final state in terminal) {
      expect(state.isTerminal, true);
      expect(state.isActive, false);
    }
    expect(ImageJobState.queued.isActive, true);
    expect(ImageJobState.running.isActive, true);
  });
}
