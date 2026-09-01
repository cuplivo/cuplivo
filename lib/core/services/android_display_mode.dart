import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_displaymode/flutter_displaymode.dart';

/// Requests the highest available refresh rate on Android.
///
/// Android 15+ (SDK >= 35): the native side hints the Flutter rendering
/// surface via `Surface.setFrameRate` and reports `true`. Older versions
/// fall back to the [FlutterDisplayMode] plugin. Every failure path is
/// recoverable: logged, never thrown, never blocking startup or resume.
class AndroidDisplayModeService {
  AndroidDisplayModeService._();

  static final AndroidDisplayModeService instance =
      AndroidDisplayModeService._();

  static const MethodChannel _channel = MethodChannel('app.display_mode');

  bool debugForceAndroidForTest = false;
  AppLifecycleListener? _lifecycleListener;

  bool get _isAndroid => debugForceAndroidForTest || Platform.isAndroid;

  /// Registers the resume re-request hook and fires one initial request.
  /// Idempotent; no-op on non-Android platforms.
  void install() {
    if (!_isAndroid || _lifecycleListener != null) return;

    // Some Android variants clear refresh-rate requests in background.
    _lifecycleListener = AppLifecycleListener(
      onResume: () => unawaited(requestHighRefreshRate()),
    );
    unawaited(requestHighRefreshRate());
  }

  /// Asks the native side for a high refresh rate. `false` means the native
  /// path is unavailable (SDK < 35), so the legacy plugin takes over.
  Future<void> requestHighRefreshRate() async {
    if (!_isAndroid) return;
    try {
      final handledNatively =
          await _channel.invokeMethod<bool>('requestHighRefreshRate') ?? false;
      if (!handledNatively) {
        await FlutterDisplayMode.setHighRefreshRate();
      }
    } catch (error) {
      debugPrint('[DisplayMode] High refresh rate request failed: $error');
    }
  }

  @visibleForTesting
  void debugResetForTest() {
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
    debugForceAndroidForTest = false;
  }
}
