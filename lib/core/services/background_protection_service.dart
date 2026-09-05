import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Recognized OEMs for the keep-alive guide. Mirrors the vendor keys of the
/// native [BackgroundProtectionHandler.kt] jump table.
enum KeepAliveVendor {
  xiaomi,
  huawei,
  honor,
  oppo,
  oneplus,
  vivo,
  samsung,
  meizu,
  other;

  /// Normalizes a `Build.MANUFACTURER`-style string into a vendor. Pure and
  /// case-insensitive; `other` for anything unrecognized.
  static KeepAliveVendor fromManufacturer(String manufacturer) {
    final m = manufacturer.toLowerCase();
    if (m.contains('xiaomi') || m.contains('redmi') || m.contains('poco')) {
      return KeepAliveVendor.xiaomi;
    }
    if (m.contains('huawei')) return KeepAliveVendor.huawei;
    if (m.contains('honor')) return KeepAliveVendor.honor;
    if (m.contains('oppo') || m.contains('realme')) return KeepAliveVendor.oppo;
    if (m.contains('oneplus')) return KeepAliveVendor.oneplus;
    if (m.contains('vivo') || m.contains('iqoo')) return KeepAliveVendor.vivo;
    if (m.contains('samsung')) return KeepAliveVendor.samsung;
    if (m.contains('meizu')) return KeepAliveVendor.meizu;
    return KeepAliveVendor.other;
  }
}

/// Which vendor settings page to jump to.
enum KeepAliveSettingsKind { autostart, battery }

/// Result of a vendor settings jump attempt.
enum VendorSettingsOpenResult {
  /// A vendor-specific page opened.
  opened,

  /// Vendor page unavailable; a generic settings page (battery list / app
  /// details) opened instead. The user must navigate manually.
  fallback,

  /// Nothing could be opened.
  failed,
}

/// Thin Dart wrapper around the `app.background_protection` MethodChannel plus
/// device-local status checks used by the keep-alive guide page.
/// All calls are no-ops / safe defaults on non-Android platforms.
class BackgroundProtectionService {
  BackgroundProtectionService._();

  static final BackgroundProtectionService instance =
      BackgroundProtectionService._();

  static const MethodChannel _channel = MethodChannel(
    'app.background_protection',
  );

  bool debugForceAndroidForTest = false;
  String? debugManufacturerOverrideForTest;

  bool get _isAndroid => debugForceAndroidForTest || Platform.isAndroid;

  /// Clears caches so unit tests can re-run scenarios deterministically.
  void resetForTest() {
    _batteryOptimizationIgnoredFuture = null;
    _detectedVendorFuture = null;
  }

  Future<bool?>? _batteryOptimizationIgnoredFuture;
  Future<String>? _detectedVendorFuture;

  /// Cached (per process) manufacturer string; null until first call.
  Future<String> detectVendor() {
    final cached = _detectedVendorFuture;
    if (cached != null) return cached;
    final future = _detectVendorOnce();
    _detectedVendorFuture = future;
    return future;
  }

  Future<String> _detectVendorOnce() async {
    final override = debugManufacturerOverrideForTest;
    if (override != null) return override;
    if (!_isAndroid) return '';
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return info.manufacturer;
    } catch (e) {
      debugPrint(
        '[BackgroundProtectionService] manufacturer lookup failed: $e',
      );
      return '';
    }
  }

  /// True when the app is exempt from battery optimization.
  Future<bool?> isIgnoringBatteryOptimizations() {
    return _batteryOptimizationIgnoredFuture ??= _queryBatteryOptimization();
  }

  Future<bool?> _queryBatteryOptimization() async {
    if (!_isAndroid) return null;
    try {
      return await _channel.invokeMethod<bool>(
        'isIgnoringBatteryOptimizations',
      );
    } on PlatformException catch (e) {
      debugPrint(
        '[BackgroundProtectionService] battery status query failed: ${e.message}',
      );
      return null;
    } catch (e) {
      debugPrint(
        '[BackgroundProtectionService] battery status query failed: $e',
      );
      return null;
    }
  }

  /// Clears the cached battery status so the next read is fresh (used when the
  /// app resumes from background after the user changed the exemption).
  Future<bool?> refreshBatteryOptimizationStatus() {
    _batteryOptimizationIgnoredFuture = null;
    return isIgnoringBatteryOptimizations();
  }

  /// Opens the system dialog that requests the battery-optimization exemption.
  /// Returns whether the dialog launch succeeded.
  Future<bool> requestIgnoreBatteryOptimization() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'requestIgnoreBatteryOptimization',
          ) ??
          false;
    } catch (e) {
      debugPrint(
        '[BackgroundProtectionService] battery exemption request failed: $e',
      );
      return false;
    }
  }

  /// Attempts to open the vendor settings page. Returns the resolved outcome
  /// (opened vendor page / generic fallback / failed).
  Future<VendorSettingsOpenResult> openVendorSettings({
    required KeepAliveVendor vendor,
    required KeepAliveSettingsKind kind,
  }) async {
    if (!_isAndroid) return VendorSettingsOpenResult.failed;
    try {
      final raw = await _channel.invokeMethod<String>(
        'openVendorSettings',
        <String, Object?>{'vendor': vendor.name, 'kind': kind.name},
      );
      switch (raw) {
        case 'opened':
          return VendorSettingsOpenResult.opened;
        case 'fallback':
          return VendorSettingsOpenResult.fallback;
        default:
          return VendorSettingsOpenResult.failed;
      }
    } catch (e) {
      debugPrint(
        '[BackgroundProtectionService] vendor settings jump failed: $e',
      );
      return VendorSettingsOpenResult.failed;
    }
  }

  /// Whether notifications are currently allowed (Android 13+). Safe default
  /// false on other platforms.
  Future<bool> areNotificationsGranted() async {
    if (!_isAndroid) return false;
    try {
      return await Permission.notification.status.isGranted;
    } catch (e) {
      debugPrint(
        '[BackgroundProtectionService] notification status failed: $e',
      );
      return false;
    }
  }

  /// Requests notification permission (Android 13+) and returns the grant state.
  Future<bool> requestNotificationsPermission() async {
    if (!_isAndroid) return false;
    try {
      return await Permission.notification.request().isGranted;
    } catch (e) {
      debugPrint(
        '[BackgroundProtectionService] notification permission request failed: $e',
      );
      return false;
    }
  }
}
