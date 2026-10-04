import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import '../models/assistant.dart';
import '../models/conversation.dart';
import 'desktop_power_state.dart';
import 'proactive_care_conversation_policy.dart';

/// In-process timer-based proactive care scheduler for desktop and foreground platforms.
///
/// Dispatches when `DateTime.now() >= dueAt`, taking native system sleep/wake
/// transitions into account through [DesktopPowerState].
class DesktopProactiveCareScheduler {
  DesktopProactiveCareScheduler({
    DateTime Function()? now,
    Future<DesktopPowerState> Function()? readPowerState,
  }) : _now = now ?? DateTime.now,
       _readPowerState = readPowerState ?? _defaultReadPowerState;

  static const _pollInterval = Duration(seconds: 1);
  final DateTime Function() _now;
  final Future<DesktopPowerState> Function() _readPowerState;

  static Future<DesktopPowerState> _defaultReadPowerState() async {
    if (kIsWeb ||
        !(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      return const DesktopPowerState();
    }
    try {
      return await DesktopPowerState.read();
    } catch (_) {
      return const DesktopPowerState();
    }
  }

  Timer? _timer;
  DateTime? _lastTick;
  Duration? _lastTimeZoneOffset;
  Future<void> Function(String conversationId, DateTime expectedAt)? _onFire;
  final Map<String, DateTime> _schedules = {};
  bool _disposed = false;

  @visibleForTesting
  Map<String, DateTime> get schedules => Map.unmodifiable(_schedules);

  Future<void> attach(
    Future<void> Function(String conversationId, DateTime expectedAt) onFire,
  ) async {
    _onFire = onFire;
    _updateTimer();
  }

  Future<void> detach() async {
    _timer?.cancel();
    _timer = null;
    _onFire = null;
    _lastTick = null;
    _lastTimeZoneOffset = null;
  }

  Future<void> sync({
    required Conversation conversation,
    required Assistant? assistant,
  }) async {
    if (_disposed) return;
    final at =
        assistant != null &&
            ProactiveCareConversationPolicy.isEligible(conversation, assistant)
        ? conversation.proactiveCareNextMessageAt
        : null;
    if (at == null || !at.isAfter(_now())) {
      _schedules.remove(conversation.id);
    } else {
      _schedules[conversation.id] = at;
    }
    _updateTimer();
  }

  Future<void> cancelFor(String conversationId) async {
    _schedules.remove(conversationId);
    _updateTimer();
  }

  Future<void> rescheduleAll({
    required List<Conversation> conversations,
    required List<Assistant> assistants,
  }) async {
    if (_disposed) return;
    final pending = ProactiveCareConversationPolicy.pending(
      conversations: conversations,
      assistants: assistants,
      now: _now(),
    );
    _schedules.clear();
    for (final target in pending) {
      _schedules[target.conversation.id] = target.expectedAt;
    }
    _updateTimer();
  }

  void _updateTimer() {
    if (_onFire == null || _schedules.isEmpty) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    if (_timer != null || _disposed) return;
    final now = _now();
    _lastTick = now;
    _lastTimeZoneOffset = now.timeZoneOffset;
    _timer = Timer.periodic(_pollInterval, (_) => unawaited(_tick()));
  }

  @visibleForTesting
  Future<void> tickForTesting() => _tick();

  Future<void> _tick() async {
    if (_disposed || _onFire == null || _schedules.isEmpty) return;
    final power = await _readPowerState();
    if (_disposed || _onFire == null || power.sleeping) return;

    final now = _now();
    final previous = _lastTick ?? now;
    final previousOffset = _lastTimeZoneOffset ?? now.timeZoneOffset;
    _lastTick = now;
    _lastTimeZoneOffset = now.timeZoneOffset;

    // Detect clock rollback or timeZone changes
    if (now.isBefore(previous) || now.timeZoneOffset != previousOffset) {
      // Re-evaluate future eligibility on clock jump
      _schedules.removeWhere((_, at) => !at.isAfter(now));
      _updateTimer();
      return;
    }

    final due = _schedules.entries
        .where((e) => !e.value.isAfter(now))
        .map((e) => MapEntry(e.key, e.value))
        .toList();

    for (final entry in due) {
      _schedules.remove(entry.key);

      // Only native wake evidence skips a missed occurrence.
      if (power.lastWakeAt != null &&
          !power.lastWakeAt!.isAfter(now) &&
          !entry.value.isAfter(power.lastWakeAt!)) {
        continue;
      }

      try {
        await _onFire?.call(entry.key, entry.value);
      } catch (e, st) {
        debugPrint(
          '[DesktopProactiveCare] fire failed for ${entry.key}: $e\n$st',
        );
      }
    }
    _updateTimer();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _schedules.clear();
    _onFire = null;
  }
}
