import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/background_protection_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('app.background_protection');
  final calls = <MethodCall>[];
  final svc = BackgroundProtectionService.instance;

  setUp(() {
    calls.clear();
    svc.resetForTest();
    svc.debugForceAndroidForTest = false;
    svc.debugManufacturerOverrideForTest = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'isIgnoringBatteryOptimizations':
              return true;
            case 'requestIgnoreBatteryOptimization':
              return true;
            case 'openVendorSettings':
              return 'opened';
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    svc.debugForceAndroidForTest = false;
    svc.debugManufacturerOverrideForTest = null;
    svc.resetForTest();
  });

  group('KeepAliveVendor.fromManufacturer', () {
    test('maps known manufacturers case-insensitively', () {
      expect(
        KeepAliveVendor.fromManufacturer('Xiaomi'),
        KeepAliveVendor.xiaomi,
      );
      expect(KeepAliveVendor.fromManufacturer('Redmi'), KeepAliveVendor.xiaomi);
      expect(KeepAliveVendor.fromManufacturer('POCO'), KeepAliveVendor.xiaomi);
      expect(
        KeepAliveVendor.fromManufacturer('HUAWEI'),
        KeepAliveVendor.huawei,
      );
      expect(KeepAliveVendor.fromManufacturer('Honor'), KeepAliveVendor.honor);
      expect(KeepAliveVendor.fromManufacturer('OPPO'), KeepAliveVendor.oppo);
      expect(KeepAliveVendor.fromManufacturer('realmE'), KeepAliveVendor.oppo);
      expect(
        KeepAliveVendor.fromManufacturer('OnePlus'),
        KeepAliveVendor.oneplus,
      );
      expect(KeepAliveVendor.fromManufacturer('vivo'), KeepAliveVendor.vivo);
      expect(KeepAliveVendor.fromManufacturer('iQOO'), KeepAliveVendor.vivo);
      expect(
        KeepAliveVendor.fromManufacturer('samsung'),
        KeepAliveVendor.samsung,
      );
      expect(KeepAliveVendor.fromManufacturer('Meizu'), KeepAliveVendor.meizu);
    });

    test('falls back to other for unrecognized input', () {
      expect(KeepAliveVendor.fromManufacturer('Google'), KeepAliveVendor.other);
      expect(KeepAliveVendor.fromManufacturer(''), KeepAliveVendor.other);
    });
  });

  group('non-Android platform', () {
    test('battery status returns null without touching the channel', () async {
      expect(await svc.isIgnoringBatteryOptimizations(), isNull);
      expect(calls, isEmpty);
    });

    test(
      'exemption request returns false without touching the channel',
      () async {
        expect(await svc.requestIgnoreBatteryOptimization(), isFalse);
        expect(calls, isEmpty);
      },
    );

    test('vendor jump returns failed without touching the channel', () async {
      final result = await svc.openVendorSettings(
        vendor: KeepAliveVendor.xiaomi,
        kind: KeepAliveSettingsKind.autostart,
      );
      expect(result, VendorSettingsOpenResult.failed);
      expect(calls, isEmpty);
    });

    test('notification status is false without touching the channel', () async {
      expect(await svc.areNotificationsGranted(), isFalse);
      expect(calls, isEmpty);
    });
  });

  group('Android via mocked channel', () {
    test('queries status and requests exemption over the channel', () async {
      svc.debugForceAndroidForTest = true;
      expect(await svc.isIgnoringBatteryOptimizations(), isTrue);
      expect(await svc.requestIgnoreBatteryOptimization(), isTrue);
      expect(calls.map((c) => c.method).toList(), [
        'isIgnoringBatteryOptimizations',
        'requestIgnoreBatteryOptimization',
      ]);
    });

    test('caches the battery status until refreshed', () async {
      svc.debugForceAndroidForTest = true;
      await svc.isIgnoringBatteryOptimizations();
      await svc.isIgnoringBatteryOptimizations();
      expect(
        calls.where((c) => c.method == 'isIgnoringBatteryOptimizations').length,
        1,
      );
      await svc.refreshBatteryOptimizationStatus();
      expect(
        calls.where((c) => c.method == 'isIgnoringBatteryOptimizations').length,
        2,
      );
    });

    test('openVendorSettings maps results and passes vendor/kind', () async {
      svc.debugForceAndroidForTest = true;
      expect(
        await svc.openVendorSettings(
          vendor: KeepAliveVendor.xiaomi,
          kind: KeepAliveSettingsKind.battery,
        ),
        VendorSettingsOpenResult.opened,
      );
      expect(calls.single.method, 'openVendorSettings');
      expect(calls.single.arguments, {'vendor': 'xiaomi', 'kind': 'battery'});
    });

    test('openVendorSettings maps fallback', () async {
      svc.debugForceAndroidForTest = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'openVendorSettings') return 'fallback';
            return null;
          });
      expect(
        await svc.openVendorSettings(
          vendor: KeepAliveVendor.vivo,
          kind: KeepAliveSettingsKind.battery,
        ),
        VendorSettingsOpenResult.fallback,
      );
    });

    test('openVendorSettings maps unknown raw results to failed', () async {
      svc.debugForceAndroidForTest = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'openVendorSettings') return 'weird';
            return null;
          });
      expect(
        await svc.openVendorSettings(
          vendor: KeepAliveVendor.huawei,
          kind: KeepAliveSettingsKind.autostart,
        ),
        VendorSettingsOpenResult.failed,
      );
    });
  });
}
