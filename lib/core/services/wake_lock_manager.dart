import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:wakelock_plus/wakelock_plus.dart';

/// Keeps the mobile screen on while AI generation is running.
///
/// Platform-gated: only Android and iOS hold a wake lock; every other
/// platform is a no-op (desktop monitor sleep is out of scope, see
/// docs/adr/0041-screen-on-wake-lock-during-generation.md). Refcounted so
/// concurrent generation (Multi-AI N-slot rounds, sequential rounds) holds
/// the lock until the last slot settles.
///
/// User-gated via [isEnabled] (settings toggle, issue #552): when disabled at
/// the moment a lock would touch the platform the call is skipped — a
/// disabled manager never invokes `wakelock_plus` at all. The toggle is
/// re-checked at every slot start: an in-flight round keeps its lock until
/// settle, a new enabled slot turns the screen on even when an older disabled
/// round is still running (a new round can only *add* a lock — active rounds
/// keep the screen on until the last one settles, so an off-flip over
/// overlapping rounds only takes effect once they all settle). [`_platformOn`]
/// tracks whether an enable was actually requested, so the settle-time drop
/// still turns the screen off when the user toggled off mid-round, while a
/// never-enabled manager stays a silent no-op.
class WakeLockManager {
  WakeLockManager({
    bool Function()? isMobilePlatform,
    bool Function()? isEnabled,
    Future<void> Function(bool enabled)? applyLock,
  }) : _isMobile = isMobilePlatform ?? _defaultMobileCheck,
       _isEnabled = isEnabled ?? _defaultEnabled,
       _applyLock = applyLock ?? _defaultApplyLock;

  static bool _defaultMobileCheck() => Platform.isAndroid || Platform.isIOS;

  static bool _defaultEnabled() => true;

  static Future<void> _defaultApplyLock(bool enabled) =>
      WakelockPlus.toggle(enable: enabled);

  final bool Function() _isMobile;
  final bool Function() _isEnabled;
  final Future<void> Function(bool enabled) _applyLock;

  int _refCount = 0;
  bool _platformOn = false;

  /// True while a wake lock is logically held (an acquire is outstanding).
  /// Note: with the user toggle off, [refCount] can be positive without the
  /// platform lock actually being on — test-observability only.
  bool get isHeld => _refCount > 0;

  /// Acquires one reference to the screen-on wake lock. Safe to call
  /// repeatedly; the platform is touched only when some acquired reference
  /// has the user toggle enabled and the platform is not already on.
  void acquire() {
    if (!_isMobile()) return;
    if (!_platformOn && _isEnabled()) {
      _platformOn = true;
      unawaited(_setEnabled(true));
    }
    _refCount++;
  }

  /// Releases one reference. The lock is dropped when the last reference is
  /// released; extra releases are ignored (the count never goes negative).
  void release() {
    if (!_isMobile()) return;
    if (_refCount <= 0) return;
    _refCount--;
    if (_refCount == 0) {
      _dropPlatformLock();
    }
  }

  /// Drops every reference and forces the lock off. Used by the engine's
  /// `dispose`, where pending slot releases can no longer be awaited.
  void reset() {
    if (!_isMobile()) return;
    if (_refCount == 0) return;
    _refCount = 0;
    _dropPlatformLock();
  }

  void _dropPlatformLock() {
    if (!_platformOn) return;
    _platformOn = false;
    unawaited(_setEnabled(false));
  }

  Future<void> _setEnabled(bool enabled) async {
    try {
      await _applyLock(enabled);
    } catch (e) {
      // Recoverable: a failed wake lock must never break generation — the
      // worst case is the screen sleeping mid-stream.
      debugPrint(
        '[WakeLockManager] failed to '
        '${enabled ? 'enable' : 'disable'} wake lock: $e',
      );
    }
  }
}
