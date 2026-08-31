import 'package:Cuplivo/core/services/android_proactive_care_settings_service.dart';
import 'package:Cuplivo/core/services/notification_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  group('AndroidProactiveCareSettingsService', () {
    test(
      'non-Android is not applicable and performs no platform calls',
      () async {
        final platform = _FakePlatform(isAndroid: false);
        final service = AndroidProactiveCareSettingsService(platform: platform);

        final status = await service.queryStatus();

        expect(
          status.appNotifications,
          AndroidProactiveCareSettingState.notApplicable,
        );
        expect(
          status.proactiveCareChannel,
          AndroidProactiveCareSettingState.notApplicable,
        );
        expect(
          status.exactAlarms,
          AndroidProactiveCareSettingState.notApplicable,
        );
        expect(
          status.batteryOptimizationExemption,
          AndroidProactiveCareSettingState.notApplicable,
        );
        expect(
          status.autoStart,
          AndroidProactiveCareSettingState.notApplicable,
        );
        expect(platform.callCount, 0);
        expect(
          await service.requestNotifications(),
          AndroidProactiveCareSettingState.notApplicable,
        );
        expect(
          await service.requestExactAlarm(),
          AndroidProactiveCareSettingState.notApplicable,
        );
        expect(
          await service.requestBatteryOptimizationExemption(),
          AndroidProactiveCareSettingState.notApplicable,
        );
        expect(await service.openAppNotificationSettings(), isFalse);
        expect(
          await service.openAutoStartSettings(),
          AndroidAutoStartSettingsDestination.unavailable,
        );
        expect(platform.callCount, 0);
      },
    );

    test('query reports ready settings and manual auto-start', () async {
      final platform = _FakePlatform();
      final service = AndroidProactiveCareSettingsService(platform: platform);

      final status = await service.queryStatus();

      expect(status.appNotifications, AndroidProactiveCareSettingState.ready);
      expect(
        status.proactiveCareChannel,
        AndroidProactiveCareSettingState.ready,
      );
      expect(status.exactAlarms, AndroidProactiveCareSettingState.ready);
      expect(
        status.batteryOptimizationExemption,
        AndroidProactiveCareSettingState.ready,
      );
      expect(status.autoStart, AndroidProactiveCareSettingState.manual);
      expect(platform.ensureNotificationCalls, 1);
      expect(platform.requestNotificationCalls, 0);
      expect(platform.requestExactAlarmCalls, 0);
      expect(platform.requestBatteryCalls, 0);
    });

    test(
      'query distinguishes app, channel, and special-setting denial',
      () async {
        final platform = _FakePlatform(
          notificationsEnabled: false,
          exactAlarmStatus: PermissionStatus.denied,
          batteryStatus: PermissionStatus.permanentlyDenied,
          channels: const <AndroidNotificationChannel>[
            AndroidNotificationChannel(
              proactiveCareNotificationChannelId,
              'Proactive Care',
              importance: Importance.none,
            ),
          ],
        );

        final status = await AndroidProactiveCareSettingsService(
          platform: platform,
        ).queryStatus();

        expect(
          status.appNotifications,
          AndroidProactiveCareSettingState.notReady,
        );
        expect(
          status.proactiveCareChannel,
          AndroidProactiveCareSettingState.notReady,
        );
        expect(status.exactAlarms, AndroidProactiveCareSettingState.notReady);
        expect(
          status.batteryOptimizationExemption,
          AndroidProactiveCareSettingState.notReady,
        );
        expect(status.autoStart, AndroidProactiveCareSettingState.manual);
      },
    );

    test(
      'missing channel is not ready, while pre-26 needs no channel',
      () async {
        final missing = _FakePlatform(channels: const []);
        final oldAndroid = _FakePlatform(sdkInt: 25, channels: const []);

        expect(
          (await AndroidProactiveCareSettingsService(
            platform: missing,
          ).queryStatus()).proactiveCareChannel,
          AndroidProactiveCareSettingState.notReady,
        );
        expect(
          (await AndroidProactiveCareSettingsService(
            platform: oldAndroid,
          ).queryStatus()).proactiveCareChannel,
          AndroidProactiveCareSettingState.ready,
        );
        expect(oldAndroid.notificationChannelCalls, 0);
      },
    );

    test('pre-23 treats unavailable battery optimization as ready', () async {
      final platform = _FakePlatform(
        sdkInt: 22,
        batteryStatus: PermissionStatus.restricted,
        requestBatteryResult: PermissionStatus.restricted,
      );
      final service = AndroidProactiveCareSettingsService(platform: platform);

      expect(
        (await service.queryStatus()).batteryOptimizationExemption,
        AndroidProactiveCareSettingState.ready,
      );
      expect(
        await service.requestBatteryOptimizationExemption(),
        AndroidProactiveCareSettingState.ready,
      );
      expect(platform.requestBatteryCalls, 0);
    });

    test('query failures are surfaced as unknown instead of granted', () async {
      final platform = _FakePlatform(
        notificationsError: StateError('notification channel dead'),
        exactAlarmError: StateError('exact alarm channel dead'),
        batteryError: StateError('battery channel dead'),
        channelError: StateError('channel query dead'),
      );

      final status = await AndroidProactiveCareSettingsService(
        platform: platform,
      ).queryStatus();

      expect(status.appNotifications, AndroidProactiveCareSettingState.unknown);
      expect(
        status.proactiveCareChannel,
        AndroidProactiveCareSettingState.unknown,
      );
      expect(status.exactAlarms, AndroidProactiveCareSettingState.unknown);
      expect(
        status.batteryOptimizationExemption,
        AndroidProactiveCareSettingState.unknown,
      );
      expect(status.autoStart, AndroidProactiveCareSettingState.manual);
    });

    test('permissions are requested only by their explicit actions', () async {
      final platform = _FakePlatform(
        notificationsEnabled: false,
        requestNotificationResult: true,
        requestExactAlarmResult: PermissionStatus.granted,
        requestBatteryResult: PermissionStatus.denied,
      );
      final service = AndroidProactiveCareSettingsService(platform: platform);

      await service.queryStatus();
      expect(platform.requestNotificationCalls, 0);
      expect(platform.requestExactAlarmCalls, 0);
      expect(platform.requestBatteryCalls, 0);

      expect(
        await service.requestNotifications(),
        AndroidProactiveCareSettingState.ready,
      );
      expect(
        await service.requestExactAlarm(),
        AndroidProactiveCareSettingState.ready,
      );
      expect(
        await service.requestBatteryOptimizationExemption(),
        AndroidProactiveCareSettingState.notReady,
      );
      expect(platform.requestNotificationCalls, 1);
      expect(platform.requestExactAlarmCalls, 1);
      expect(platform.requestBatteryCalls, 1);
    });

    test('request errors are unknown and remain observable', () async {
      final platform = _FakePlatform(
        requestNotificationError: StateError('notification request failed'),
        requestExactAlarmError: StateError('exact request failed'),
        requestBatteryError: StateError('battery request failed'),
      );
      final service = AndroidProactiveCareSettingsService(platform: platform);

      expect(
        await service.requestNotifications(),
        AndroidProactiveCareSettingState.unknown,
      );
      expect(
        await service.requestExactAlarm(),
        AndroidProactiveCareSettingState.unknown,
      );
      expect(
        await service.requestBatteryOptimizationExemption(),
        AndroidProactiveCareSettingState.unknown,
      );
    });

    test(
      'settings actions use the dedicated native channel contract',
      () async {
        final platform = _FakePlatform(
          nativeResults: <String, Object?>{
            'openAppNotificationSettings': true,
            'openNotificationChannelSettings': true,
            'openAutoStartSettings': 'manufacturerSettings',
          },
        );
        final service = AndroidProactiveCareSettingsService(platform: platform);

        expect(await service.openAppNotificationSettings(), isTrue);
        expect(await service.openProactiveCareChannelSettings(), isTrue);
        expect(
          await service.openAutoStartSettings(),
          AndroidAutoStartSettingsDestination.manufacturerSettings,
        );
        expect(
          platform.nativeArguments['openNotificationChannelSettings'],
          <String, Object?>{'channelId': proactiveCareNotificationChannelId},
        );
        expect(platform.ensureNotificationCalls, 1);
      },
    );

    test(
      'auto-start reports application-details fallback without granting',
      () async {
        final platform = _FakePlatform(
          nativeResults: <String, Object?>{
            'openAutoStartSettings': 'applicationDetails',
          },
        );
        final service = AndroidProactiveCareSettingsService(platform: platform);

        expect(
          await service.openAutoStartSettings(),
          AndroidAutoStartSettingsDestination.applicationDetails,
        );
        expect(
          (await service.queryStatus()).autoStart,
          AndroidProactiveCareSettingState.manual,
        );
      },
    );

    test('invalid or failed native responses report unavailable', () async {
      final invalid = _FakePlatform(
        nativeResults: <String, Object?>{'openAutoStartSettings': true},
      );
      final failed = _FakePlatform(
        nativeError: StateError('settings channel dead'),
      );

      expect(
        await AndroidProactiveCareSettingsService(
          platform: invalid,
        ).openAutoStartSettings(),
        AndroidAutoStartSettingsDestination.unavailable,
      );
      expect(
        await AndroidProactiveCareSettingsService(
          platform: failed,
        ).openAppNotificationSettings(),
        isFalse,
      );
    });
  });
}

class _FakePlatform implements AndroidProactiveCareSettingsPlatform {
  _FakePlatform({
    this.isAndroid = true,
    this._notificationsEnabled = true,
    this.requestNotificationResult = true,
    this._exactAlarmStatus = PermissionStatus.granted,
    this.requestExactAlarmResult = PermissionStatus.granted,
    this._batteryStatus = PermissionStatus.granted,
    this.requestBatteryResult = PermissionStatus.granted,
    this.sdkInt = 35,
    List<AndroidNotificationChannel>? channels,
    this.notificationsError,
    this.requestNotificationError,
    this.exactAlarmError,
    this.requestExactAlarmError,
    this.batteryError,
    this.requestBatteryError,
    this.channelError,
    this.nativeError,
    Map<String, Object?>? nativeResults,
  }) : channels =
           channels ??
           const <AndroidNotificationChannel>[
             AndroidNotificationChannel(
               proactiveCareNotificationChannelId,
               'Proactive Care',
               importance: Importance.high,
             ),
           ],
       nativeResults = nativeResults ?? const <String, Object?>{};

  @override
  final bool isAndroid;
  bool _notificationsEnabled;
  final bool? requestNotificationResult;
  final PermissionStatus _exactAlarmStatus;
  final PermissionStatus requestExactAlarmResult;
  final PermissionStatus _batteryStatus;
  final PermissionStatus requestBatteryResult;
  final int sdkInt;
  final List<AndroidNotificationChannel>? channels;
  final Object? notificationsError;
  final Object? requestNotificationError;
  final Object? exactAlarmError;
  final Object? requestExactAlarmError;
  final Object? batteryError;
  final Object? requestBatteryError;
  final Object? channelError;
  final Object? nativeError;
  final Map<String, Object?> nativeResults;

  int callCount = 0;
  int ensureNotificationCalls = 0;
  int notificationChannelCalls = 0;
  int requestNotificationCalls = 0;
  int requestExactAlarmCalls = 0;
  int requestBatteryCalls = 0;
  final Map<String, Map<String, Object?>?> nativeArguments = {};

  @override
  Future<bool?> areNotificationsEnabled() async {
    callCount++;
    if (notificationsError case final error?) throw error;
    return _notificationsEnabled;
  }

  @override
  Future<bool?> requestNotifications() async {
    callCount++;
    requestNotificationCalls++;
    if (requestNotificationError case final error?) throw error;
    if (requestNotificationResult case final result?) {
      _notificationsEnabled = result;
    }
    return requestNotificationResult;
  }

  @override
  Future<PermissionStatus> exactAlarmStatus() async {
    callCount++;
    if (exactAlarmError case final error?) throw error;
    return _exactAlarmStatus;
  }

  @override
  Future<PermissionStatus> requestExactAlarm() async {
    callCount++;
    requestExactAlarmCalls++;
    if (requestExactAlarmError case final error?) throw error;
    return requestExactAlarmResult;
  }

  @override
  Future<PermissionStatus> batteryOptimizationStatus() async {
    callCount++;
    if (batteryError case final error?) throw error;
    return _batteryStatus;
  }

  @override
  Future<PermissionStatus> requestBatteryOptimizationExemption() async {
    callCount++;
    requestBatteryCalls++;
    if (requestBatteryError case final error?) throw error;
    return requestBatteryResult;
  }

  @override
  Future<void> ensureNotificationInfrastructure() async {
    callCount++;
    ensureNotificationCalls++;
    if (channelError case final error?) throw error;
  }

  @override
  Future<int> androidSdkInt() async {
    callCount++;
    return sdkInt;
  }

  @override
  Future<List<AndroidNotificationChannel>?> notificationChannels() async {
    callCount++;
    notificationChannelCalls++;
    return channels;
  }

  @override
  Future<Object?> invokeSettingsMethod(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    callCount++;
    nativeArguments[method] = arguments;
    if (nativeError case final error?) throw error;
    return nativeResults[method];
  }
}
