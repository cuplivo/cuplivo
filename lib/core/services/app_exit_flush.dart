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

  static void register(Future<void> Function() handler) {
    _handlers.add(handler);
  }

  static void unregister(Future<void> Function() handler) {
    _handlers.remove(handler);
  }

  static Future<void> flushAll() async {
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
