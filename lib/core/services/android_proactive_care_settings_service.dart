import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import 'notification_service.dart';

/// Readiness of an Android setting needed by proactive care.
enum AndroidProactiveCareSettingState {
  ready,
  notReady,
  unknown,
  manual,
  notApplicable,
}

/// Current Android settings relevant to proactive care.
class AndroidProactiveCareSettingsStatus {
  const AndroidProactiveCareSettingsStatus({
    required this.appNotifications,
    required this.proactiveCareChannel,
    required this.exactAlarms,
    required this.batteryOptimizationExemption,
    required this.autoStart,
  });

  final AndroidProactiveCareSettingState appNotifications;
  final AndroidProactiveCareSettingState proactiveCareChannel;
  final AndroidProactiveCareSettingState exactAlarms;
  final AndroidProactiveCareSettingState batteryOptimizationExemption;

  /// Always [AndroidProactiveCareSettingState.manual] on Android because OEMs
  /// do not expose a truthful grant query for auto-start settings.
  final AndroidProactiveCareSettingState autoStart;
}

/// Destination opened by [AndroidProactiveCareSettingsService.openAutoStartSettings].
enum AndroidAutoStartSettingsDestination {
  manufacturerSettings,
  applicationDetails,
  unavailable,
}

/// Narrow platform seam for direct service tests.
abstract interface class AndroidProactiveCareSettingsPlatform {
  bool get isAndroid;

  Future<bool?> areNotificationsEnabled();

  Future<bool?> requestNotifications();

  Future<PermissionStatus> exactAlarmStatus();

  Future<PermissionStatus> requestExactAlarm();

  Future<PermissionStatus> batteryOptimizationStatus();

  Future<PermissionStatus> requestBatteryOptimizationExemption();

  Future<void> ensureNotificationInfrastructure();

  Future<int> androidSdkInt();

  Future<List<AndroidNotificationChannel>?> notificationChannels();

  Future<Object?> invokeSettingsMethod(
    String method, [
    Map<String, Object?>? arguments,
  ]);
}

/// Android-only permission and system-settings actions for proactive care.
///
/// Status methods never request permission. Request/open methods are intended
/// for explicit settings-row actions, not feature toggles.
class AndroidProactiveCareSettingsService {
  AndroidProactiveCareSettingsService({
    AndroidProactiveCareSettingsPlatform? platform,
  }) : _platform = platform ?? _PluginAndroidProactiveCareSettingsPlatform();

  static const settingsChannelName = 'cuplivo/proactive_care_settings';

  final AndroidProactiveCareSettingsPlatform _platform;

  bool get isSupported => _platform.isAndroid;

  Future<AndroidProactiveCareSettingsStatus> queryStatus() async {
    if (!isSupported) {
      return const AndroidProactiveCareSettingsStatus(
        appNotifications: AndroidProactiveCareSettingState.notApplicable,
        proactiveCareChannel: AndroidProactiveCareSettingState.notApplicable,
        exactAlarms: AndroidProactiveCareSettingState.notApplicable,
        batteryOptimizationExemption:
            AndroidProactiveCareSettingState.notApplicable,
        autoStart: AndroidProactiveCareSettingState.notApplicable,
      );
    }

    final appNotifications = _queryAppNotifications();
    final proactiveCareChannel = _queryProactiveCareChannel();
    final exactAlarms = _queryPermission(
      'exact alarm status',
      _platform.exactAlarmStatus,
    );
    final batteryOptimization = _queryBatteryOptimization();

    return AndroidProactiveCareSettingsStatus(
      appNotifications: await appNotifications,
      proactiveCareChannel: await proactiveCareChannel,
      exactAlarms: await exactAlarms,
      batteryOptimizationExemption: await batteryOptimization,
      autoStart: AndroidProactiveCareSettingState.manual,
    );
  }

  Future<AndroidProactiveCareSettingState> requestNotifications() async {
    if (!isSupported) return AndroidProactiveCareSettingState.notApplicable;
    try {
      await _platform.requestNotifications();
      return await _queryAppNotifications();
    } catch (error) {
      _logFailure('notification permission request', error);
      return AndroidProactiveCareSettingState.unknown;
    }
  }

  Future<AndroidProactiveCareSettingState> requestExactAlarm() =>
      _requestPermission('exact alarm request', _platform.requestExactAlarm);

  Future<AndroidProactiveCareSettingState>
  requestBatteryOptimizationExemption() async {
    if (!isSupported) return AndroidProactiveCareSettingState.notApplicable;
    try {
      if (await _platform.androidSdkInt() < 23) {
        return AndroidProactiveCareSettingState.ready;
      }
    } catch (error) {
      _logFailure('battery optimization exemption request', error);
      return AndroidProactiveCareSettingState.unknown;
    }
    return _requestPermission(
      'battery optimization exemption request',
      _platform.requestBatteryOptimizationExemption,
    );
  }

  Future<bool> openAppNotificationSettings() =>
      _openBooleanSettings('openAppNotificationSettings');

  Future<bool> openProactiveCareChannelSettings() async {
    if (!isSupported) return false;
    try {
      await _platform.ensureNotificationInfrastructure();
      final opened = await _platform.invokeSettingsMethod(
        'openNotificationChannelSettings',
        <String, Object?>{'channelId': proactiveCareNotificationChannelId},
      );
      if (opened is bool) return opened;
      _logFailure(
        'open notification channel settings',
        StateError('Native bridge returned ${opened.runtimeType}.'),
      );
    } catch (error) {
      _logFailure('open notification channel settings', error);
    }
    return false;
  }

  Future<AndroidAutoStartSettingsDestination> openAutoStartSettings() async {
    if (!isSupported) {
      return AndroidAutoStartSettingsDestination.unavailable;
    }
    try {
      final destination = await _platform.invokeSettingsMethod(
        'openAutoStartSettings',
      );
      return switch (destination) {
        'manufacturerSettings' =>
          AndroidAutoStartSettingsDestination.manufacturerSettings,
        'applicationDetails' =>
          AndroidAutoStartSettingsDestination.applicationDetails,
        _ => _invalidAutoStartDestination(destination),
      };
    } catch (error) {
      _logFailure('open auto-start settings', error);
      return AndroidAutoStartSettingsDestination.unavailable;
    }
  }

  Future<AndroidProactiveCareSettingState> _queryAppNotifications() async {
    try {
      final enabled = await _platform.areNotificationsEnabled();
      if (enabled == null) {
        _logFailure(
          'notification permission status',
          StateError('Android notification plugin returned null.'),
        );
        return AndroidProactiveCareSettingState.unknown;
      }
      return enabled
          ? AndroidProactiveCareSettingState.ready
          : AndroidProactiveCareSettingState.notReady;
    } catch (error) {
      _logFailure('notification permission status', error);
      return AndroidProactiveCareSettingState.unknown;
    }
  }

  Future<AndroidProactiveCareSettingState> _queryProactiveCareChannel() async {
    try {
      await _platform.ensureNotificationInfrastructure();
      if (await _platform.androidSdkInt() < 26) {
        return AndroidProactiveCareSettingState.ready;
      }
      final channels = await _platform.notificationChannels();
      if (channels == null) {
        _logFailure(
          'proactive-care notification channel status',
          StateError('Android notification plugin returned null.'),
        );
        return AndroidProactiveCareSettingState.unknown;
      }
      for (final channel in channels) {
        if (channel.id == proactiveCareNotificationChannelId) {
          return channel.importance == Importance.none
              ? AndroidProactiveCareSettingState.notReady
              : AndroidProactiveCareSettingState.ready;
        }
      }
      return AndroidProactiveCareSettingState.notReady;
    } catch (error) {
      _logFailure('proactive-care notification channel status', error);
      return AndroidProactiveCareSettingState.unknown;
    }
  }

  Future<AndroidProactiveCareSettingState> _queryBatteryOptimization() async {
    try {
      if (await _platform.androidSdkInt() < 23) {
        return AndroidProactiveCareSettingState.ready;
      }
    } catch (error) {
      _logFailure('battery optimization exemption status', error);
      return AndroidProactiveCareSettingState.unknown;
    }
    return _queryPermission(
      'battery optimization exemption status',
      _platform.batteryOptimizationStatus,
    );
  }

  Future<AndroidProactiveCareSettingState> _queryPermission(
    String operation,
    Future<PermissionStatus> Function() query,
  ) async {
    try {
      return _permissionState(await query());
    } catch (error) {
      _logFailure(operation, error);
      return AndroidProactiveCareSettingState.unknown;
    }
  }

  Future<AndroidProactiveCareSettingState> _requestPermission(
    String operation,
    Future<PermissionStatus> Function() request,
  ) async {
    if (!isSupported) return AndroidProactiveCareSettingState.notApplicable;
    try {
      return _permissionState(await request());
    } catch (error) {
      _logFailure(operation, error);
      return AndroidProactiveCareSettingState.unknown;
    }
  }

  Future<bool> _openBooleanSettings(String method) async {
    if (!isSupported) return false;
    try {
      final opened = await _platform.invokeSettingsMethod(method);
      if (opened is bool) return opened;
      _logFailure(
        method,
        StateError('Native bridge returned ${opened.runtimeType}.'),
      );
    } catch (error) {
      _logFailure(method, error);
    }
    return false;
  }

  AndroidAutoStartSettingsDestination _invalidAutoStartDestination(
    Object? destination,
  ) {
    _logFailure(
      'open auto-start settings',
      StateError('Native bridge returned "$destination".'),
    );
    return AndroidAutoStartSettingsDestination.unavailable;
  }

  static AndroidProactiveCareSettingState _permissionState(
    PermissionStatus status,
  ) => status.isGranted
      ? AndroidProactiveCareSettingState.ready
      : AndroidProactiveCareSettingState.notReady;

  static void _logFailure(String operation, Object error) {
    debugPrint('[AndroidProactiveCareSettings] $operation failed: $error');
  }
}

class _PluginAndroidProactiveCareSettingsPlatform
    implements AndroidProactiveCareSettingsPlatform {
  static const MethodChannel _settingsChannel = MethodChannel(
    AndroidProactiveCareSettingsService.settingsChannelName,
  );

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  @override
  bool get isAndroid => Platform.isAndroid;

  AndroidFlutterLocalNotificationsPlugin? get _androidNotifications =>
      _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();

  @override
  Future<bool?> areNotificationsEnabled() =>
      _androidNotifications?.areNotificationsEnabled() ?? Future.value(null);

  @override
  Future<bool?> requestNotifications() =>
      _androidNotifications?.requestNotificationsPermission() ??
      Future.value(null);

  @override
  Future<PermissionStatus> exactAlarmStatus() =>
      Permission.scheduleExactAlarm.status;

  @override
  Future<PermissionStatus> requestExactAlarm() =>
      Permission.scheduleExactAlarm.request();

  @override
  Future<PermissionStatus> batteryOptimizationStatus() =>
      Permission.ignoreBatteryOptimizations.status;

  @override
  Future<PermissionStatus> requestBatteryOptimizationExemption() =>
      Permission.ignoreBatteryOptimizations.request();

  @override
  Future<void> ensureNotificationInfrastructure() =>
      NotificationService.ensureInitialized();

  @override
  Future<int> androidSdkInt() async =>
      (await DeviceInfoPlugin().androidInfo).version.sdkInt;

  @override
  Future<List<AndroidNotificationChannel>?> notificationChannels() =>
      _androidNotifications?.getNotificationChannels() ?? Future.value(null);

  @override
  Future<Object?> invokeSettingsMethod(
    String method, [
    Map<String, Object?>? arguments,
  ]) => _settingsChannel.invokeMethod<Object?>(method, arguments);
}
