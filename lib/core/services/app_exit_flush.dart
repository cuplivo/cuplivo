import 'dart:async';

import 'package:flutter/foundation.dart';

/// Process-exit flush registry (desktop only).
///
/// Handlers run from AppLifecycleListener.onExitRequested so in-memory write
/// queues reach durable storage before the process exits. Handlers must be
/// fast and idempotent; a failing handler is skipped so later ones still run.
///
/// These handlers only *drain* state, which is what lets them also run for a
/// window that is merely hiding (close to tray). Giving up a resource that
/// belongs to the process — closing the LAN sync listener, deleting its firewall
/// rule — is [AppShutdown]'s job instead: an exit *request* is not proof that
/// the process is going away.
final class AppExitFlush {
  AppExitFlush._();

  static final List<Future<void> Function()> _handlers =
      <Future<void> Function()>[];
  static Future<void> Function()? _prepare;
  static Future<void> Function()? _close;
  static Future<void>? _flushFuture;
  static Future<void>? _shutdownFuture;

  static bool get isExiting => _shutdownFuture != null;

  /// The process owner stops producers before flushing and closes the database
  /// afterwards. Ordinary flushes (for example before restart) do not close it.
  static void configureShutdown({
    required Future<void> Function() prepare,
    required Future<void> Function() close,
  }) {
    _prepare = prepare;
    _close = close;
  }

  static void register(Future<void> Function() handler) {
    _handlers.add(handler);
  }

  static void unregister(Future<void> Function() handler) {
    _handlers.remove(handler);
  }

  static Future<void> flushAll() => _shutdownFuture ?? _flush();

  static Future<void> _flush() =>
      _flushFuture ??= _flushHandlers().whenComplete(() => _flushFuture = null);

  static Future<void> _flushHandlers() async {
    for (final handler in List<Future<void> Function()>.of(_handlers)) {
      try {
        await handler();
      } catch (_) {}
    }
  }

  /// Tray and engine exit requests share one shutdown, including its deadline.
  /// A timeout does not start closing underneath a still-running write: the
  /// ordered work continues until the engine terminates the process.
  static Future<void> shutdown({
    Duration timeout = const Duration(seconds: 5),
  }) => _shutdownFuture ??=
      Future<void>.microtask(() async {
        try {
          await _prepare?.call();
        } finally {
          try {
            await _flush();
          } finally {
            await _close?.call();
          }
        }
      }).timeout(timeout).catchError((Object error) {
        debugPrint('App shutdown did not finish: $error');
      });

  @visibleForTesting
  static void debugReset() {
    _handlers.clear();
    _prepare = null;
    _close = null;
    _flushFuture = null;
    _shutdownFuture = null;
  }
}

/// Process-shutdown registry (desktop only).
///
/// Unlike [AppExitFlush], whose handlers are safe to run for a window that is
/// only hiding, these handlers give up resources that live with the process and
/// must run only when the process is really going away: the tray's Exit item,
/// and an exit request that was not answered as a hide. Handlers must be
/// idempotent, fast, and are skipped when they throw, exactly like the flush
/// registry they sit beside.
final class AppShutdown {
  AppShutdown._();

  static final List<Future<void> Function()> _handlers =
      <Future<void> Function()>[];

  static void register(Future<void> Function() handler) {
    _handlers.add(handler);
  }

  static void unregister(Future<void> Function() handler) {
    _handlers.remove(handler);
  }

  static Future<void> runAll() async {
    for (final handler in List<Future<void> Function()>.of(_handlers)) {
      try {
        await handler();
      } catch (_) {}
    }
  }

  @visibleForTesting
  static void debugReset() {
    _handlers.clear();
  }
}
