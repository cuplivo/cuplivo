import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/image_job.dart';
import 'image_backends.dart' show ImageBackendException;

/// Runs one job: produce the bytes at `job.uri` (or elsewhere) and report where
/// they landed. Throwing is a failure; the manager owns the terminal state.
typedef ImageJobRunner = Future<ImageJobOutcome> Function(ImageJob job);

/// Owns every live image job and its state machine.
///
/// The manager is in-memory; the durable mirror of a job's state is the
/// `ImagePart` payload it belongs to (`state` + `jobId`). [interruptLive] is
/// what turns a stale mirror back into `interrupted` on the next app start.
///
/// There is deliberately **no concurrency cap**: refusing the third picture in
/// a conversation punishes the user for something the model did, and a refused
/// call is not a queue — it is an error the reply has to explain. What actually
/// ramps cost is a model calling in a loop, and the per-call cancel plus the
/// panel handle that; the tool description asks for one picture at a time.
///
/// Finished jobs stay in [_jobs] on purpose: the key is the identity, so a
/// re-render or a remount must find the *finished* job rather than start a
/// second, billable one.
class ImageJobManager extends ChangeNotifier {
  ImageJobManager(
    this._runner, {
    DateTime Function()? clock,
    this.jobTimeout = const Duration(seconds: 300),
  }) : _clock = clock ?? DateTime.now;

  final ImageJobRunner _runner;
  final DateTime Function() _clock;

  /// A backstop for "never returns", not a deadline for "slow". Image models
  /// routinely take 180s; the ceiling is configurable per instance and only
  /// exists so a dead request cannot spin forever.
  final Duration jobTimeout;

  final Map<String, ImageJob> _jobs = <String, ImageJob>{};

  Iterable<ImageJob> get jobs => _jobs.values;

  ImageJob? byId(String id) => _jobs[id];

  int activeCount(String conversationId) => _jobs.values
      .where(
        (job) => job.conversationId == conversationId && job.state.isActive,
      )
      .length;

  /// Idempotent by construction: the key *is* the job id, so a re-render or a
  /// remount hands back the job it already had instead of paying twice.
  ImageJob create({
    required String idempotencyKey,
    required String conversationId,
    required String messageId,
    required String toolCallId,
    required String prompt,
    required String assetId,
    required String uri,
    String? aspectRatio,
  }) {
    final existing = _jobs[idempotencyKey];
    if (existing != null) return existing;
    final job = ImageJob(
      id: idempotencyKey,
      conversationId: conversationId,
      messageId: messageId,
      toolCallId: toolCallId,
      idempotencyKey: idempotencyKey,
      prompt: prompt,
      aspectRatio: aspectRatio,
      assetId: assetId,
      uri: uri,
      createdAt: _clock(),
    );
    _jobs[job.id] = job;
    notifyListeners();
    return job;
  }

  /// Moves a queued job to `running` and resolves with its terminal state.
  Future<ImageJob> start(String id) {
    final job = _jobs[id];
    if (job == null) {
      throw StateError('unknown image job: $id');
    }
    if (job.state != ImageJobState.queued) return Future.value(job);
    _set(job.copyWith(state: ImageJobState.running, startedAt: _clock()));
    return _run(id);
  }

  /// A cancelled job stays cancelled: a runner that finishes afterwards is
  /// discarded, because the user already saw the cancellation.
  bool cancel(String id) {
    final job = _jobs[id];
    if (job == null || !job.state.isActive) return false;
    _set(
      job.copyWith(
        state: ImageJobState.cancelled,
        finishedAt: _clock(),
        error: null,
      ),
    );
    return true;
  }

  /// Called once on app start: every job the mirror still calls live was
  /// interrupted by the process going away. Returns how many were flipped.
  int interruptLive() {
    var flipped = 0;
    for (final job in _jobs.values.toList(growable: false)) {
      if (!job.state.isActive) continue;
      _set(
        job.copyWith(
          state: ImageJobState.interrupted,
          finishedAt: _clock(),
          error: null,
        ),
      );
      flipped += 1;
    }
    return flipped;
  }

  Future<ImageJob> _run(String id) async {
    try {
      final outcome = await _runner(_jobs[id]!).timeout(jobTimeout);
      final current = _jobs[id]!;
      if (current.state != ImageJobState.running) return current;
      _set(
        current.copyWith(
          state: ImageJobState.completed,
          resultUri: outcome.uri,
          finishedAt: _clock(),
        ),
      );
    } on TimeoutException {
      _fail(id, 'timeout', 'No answer within ${jobTimeout.inSeconds} seconds.');
    } catch (error) {
      // The reason is what the user sees on the card. A category alone ("failed")
      // tells nobody what to fix, so the runner's own message travels through.
      _fail(id, 'provider_error', _describe(error));
    }
    return _jobs[id]!;
  }

  /// A message a person can act on, without a stack trace or a type name.
  static String _describe(Object error) {
    if (error is ImageBackendException) return error.message;
    final text = error.toString().trim();
    if (text.startsWith('Exception: ')) {
      return text.substring('Exception: '.length).trim();
    }
    return text;
  }

  void _fail(String id, String category, String message) {
    final current = _jobs[id];
    if (current == null || current.state != ImageJobState.running) return;
    _set(
      current.copyWith(
        state: ImageJobState.failed,
        error: message.isEmpty ? category : message,
        errorCode: category,
        finishedAt: _clock(),
      ),
    );
  }

  void _set(ImageJob job) {
    _jobs[job.id] = job;
    notifyListeners();
  }
}
