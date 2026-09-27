import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../database/business_preferences.dart';

/// Refreshes the business state that LAN sync just changed, without a restart
/// (ADR-0002 decision 8: apply → one state reload).
///
/// Two layers, in order:
///
/// 1. [BusinessPreferences.reload] re-reads the database into the in-memory
///    key-value view every provider reads through.
/// 2. Each registered provider callback re-runs its own `_load()` so it
///    re-interprets that view — a provider that cached a parsed model list
///    must re-parse it, which the preference reload alone cannot do.
///
/// A failing callback is logged and skipped: one provider that cannot reload
/// must not leave the rest of the app showing pre-sync state.
class BusinessStateReloader {
  BusinessStateReloader(this.preferences);

  final BusinessPreferences preferences;
  final List<Future<void> Function()> _reloaders = [];

  /// Registers one provider's reload entry point. Called during app wiring.
  void register(Future<void> Function() reload) => _reloaders.add(reload);

  Future<void> reloadAll() async {
    await preferences.reload();
    for (final reload in List<Future<void> Function()>.of(_reloaders)) {
      try {
        await reload();
      } catch (error, stack) {
        debugPrint('sync: provider reload failed: $error\n$stack');
      }
    }
  }
}
