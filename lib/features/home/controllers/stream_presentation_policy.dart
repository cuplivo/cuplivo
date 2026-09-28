import 'dart:math' as math;

import '../../../utils/utf16_safe_cut.dart';

/// Converts bursty provider output into small, append-only presentation steps.
///
/// Network ingestion remains lossless and immediate. This module only decides
/// how much of the already-received text is exposed to the renderer per tick,
/// keeping the perceived cadence stable without ever tearing a UTF-16 pair.
final class StreamPresentationPolicy {
  StreamPresentationPolicy({
    this.minUnitsPerTick = 2,
    this.initialUnitsPerTick = 6,
    this.baseBacklog = 40,
    this.maxUnitsPerTick = 96,
    this.pickRate = 0.1,
    this.movingAverageLength = 8,
    this.acceleration = 1.45,
  });

  final int minUnitsPerTick;
  final int initialUnitsPerTick;
  final int baseBacklog;
  final int maxUnitsPerTick;
  final double pickRate;
  final int movingAverageLength;
  final double acceleration;

  final List<int> _recentPicks = <int>[];
  int _lastPick = 0;

  /// Returns the next visible prefix, or `null` when nothing changed.
  String? advance({required String target, required String visible}) {
    if (target == visible) return null;
    if (!target.startsWith(visible)) {
      reset();
      return target;
    }

    final backlog = target.length - visible.length;
    if (backlog <= 0) return null;
    final count = _nextCount(backlog);
    var end = math.min(target.length, visible.length + count);
    end = utf16SafeHeadEnd(target, end);
    if (end <= visible.length) {
      // A single supplementary character may be wider than the nominal step.
      end = math.min(target.length, visible.length + 2);
    }
    return target.substring(0, end);
  }

  void reset() {
    _recentPicks.clear();
    _lastPick = 0;
  }

  int _nextCount(int backlog) {
    if (backlog <= minUnitsPerTick) return backlog;

    final raw = _rawCount(backlog);
    _recentPicks.add(raw);
    if (_recentPicks.length > movingAverageLength) {
      _recentPicks.removeAt(0);
    }
    final average =
        _recentPicks.reduce((left, right) => left + right) /
        _recentPicks.length;

    // Start gently, then accelerate while a large provider burst remains.
    // This avoids the first update painting a whole screen of Markdown.
    final accelerationLimit = _lastPick == 0
        ? initialUnitsPerTick
        : math.max(minUnitsPerTick, (_lastPick * acceleration).ceil());
    final limit = math.min(maxUnitsPerTick, accelerationLimit);
    final next = math
        .min(average.round(), limit)
        .clamp(minUnitsPerTick, backlog)
        .toInt();
    _lastPick = next;
    return next;
  }

  int _rawCount(int backlog) {
    if (backlog <= minUnitsPerTick) return backlog;

    final double effectiveRate;
    if (backlog < baseBacklog) {
      effectiveRate = pickRate * backlog / baseBacklog;
    } else if (backlog >= maxUnitsPerTick) {
      effectiveRate = math.max((backlog - baseBacklog) / backlog, pickRate);
    } else {
      final t = (backlog - baseBacklog) / (maxUnitsPerTick - baseBacklog);
      effectiveRate = pickRate + (0.5 - pickRate) * t;
    }
    return math.max(minUnitsPerTick, (backlog * effectiveRate).round());
  }
}
