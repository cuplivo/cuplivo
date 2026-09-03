import 'dart:async';

import 'package:http/http.dart' as http;

import '../../models/auto_retry_options.dart';
import 'retry_policy.dart';

/// Replays [attempt] with exponential backoff while the inner stream has not
/// produced any *visible* output.
///
/// An attempt is considered to have produced output when it yields an item for
/// which [isOutput] returns true (e.g. a chunk carrying text, reasoning or
/// tool activity). Empty keep-alive items never block a retry. When
/// [isOutput] is null, any yielded item counts as output (conservative
/// fallback).
///
/// [retryEvent]/[attemptStartEvent] flow through the outer stream so UI layers
/// can show an in-bubble countdown without touching the content path.
/// Cancellation is observed at every await point: the session's [cancelled]
/// future wakes the backoff sleep immediately and a cancelled run terminates
/// with `http.ClientException('cancelled')` instead of an error retry.
Stream<T> retryingStream<T>({
  required Stream<T> Function(int attempt) attempt,
  required AutoRetryOptions options,
  required bool Function() isCancelled,
  required bool Function(Object error) shouldRetry,
  bool Function(T item)? isOutput,
  T Function(int attempt, Duration delay, Object error)? retryEvent,
  T Function()? attemptStartEvent,
  Future<void>? cancelled,
}) async* {
  final maxRetries = options.enabled ? options.maxRetries : 0;
  Object? lastError;

  for (var i = 0; i <= maxRetries; i++) {
    if (isCancelled()) {
      throw http.ClientException('cancelled');
    }
    var producedOutput = false;
    try {
      await for (final item in attempt(i)) {
        if (isOutput?.call(item) ?? true) producedOutput = true;
        yield item;
      }
      return;
    } catch (e) {
      lastError = e;
      if (isCancelled()) {
        throw http.ClientException('cancelled');
      }
      if (producedOutput) rethrow;
      if (i >= maxRetries || !shouldRetry(e)) rethrow;
      final delay = backoffDelay(i, options);
      // retryEvent is built here, at backoff start, so a delayed consumer
      // (e.g. persistence) receives a stamped absolute deadline instead of a
      // "now + delay" extrapolation.
      final event = retryEvent?.call(i, delay, e);
      if (event != null) yield event;
      await interruptibleDelay(
        delay,
        isCancelled: isCancelled,
        cancelled: cancelled,
      );
      if (isCancelled()) {
        throw http.ClientException('cancelled');
      }
      final start = attemptStartEvent?.call();
      if (start != null) yield start;
    }
  }

  throw lastError!;
}

/// Returns as soon as [delay] elapses OR the run is cancelled.
Future<void> interruptibleDelay(
  Duration delay, {
  required bool Function() isCancelled,
  Future<void>? cancelled,
}) async {
  if (delay <= Duration.zero || isCancelled()) return;
  if (cancelled != null) {
    await Future.any<void>([Future<void>.delayed(delay), cancelled]);
    return;
  }
  const slice = Duration(milliseconds: 20);
  var remaining = delay;
  while (remaining > Duration.zero) {
    if (isCancelled()) return;
    final step = remaining < slice ? remaining : slice;
    await Future<void>.delayed(step);
    remaining -= step;
  }
}
