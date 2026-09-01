import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/android_display_mode.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const displayModeChannel = MethodChannel('app.display_mode');
  // flutter_displaymode 0.7.0 internal channel (verified against plugin
  // source): setHighRefreshRate() = getSupportedModes -> getActiveMode ->
  // setPreferredMode.
  const pluginChannel = MethodChannel('flutter_display_mode');

  final nativeCalls = <MethodCall>[];
  final pluginCalls = <MethodCall>[];
  late bool nativeHandled;
  Object? nativeError;

  AndroidDisplayModeService service() => AndroidDisplayModeService.instance
    ..debugResetForTest()
    ..debugForceAndroidForTest = true;

  setUp(() {
    nativeCalls.clear();
    pluginCalls.clear();
    nativeHandled = true;
    nativeError = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(displayModeChannel, (call) async {
      if (nativeError != null) throw nativeError!;
      nativeCalls.add(call);
      return nativeHandled;
    });
    messenger.setMockMethodCallHandler(pluginChannel, (call) async {
      pluginCalls.add(call);
      switch (call.method) {
        case 'getSupportedModes':
          return <Map<dynamic, dynamic>>[
            {'id': 1, 'width': 1080, 'height': 2340, 'refreshRate': 60.0},
            {'id': 2, 'width': 1080, 'height': 2340, 'refreshRate': 90.0},
            {'id': 3, 'width': 1440, 'height': 3120, 'refreshRate': 120.0},
          ];
        case 'getActiveMode':
          return {'id': 1, 'width': 1080, 'height': 2340, 'refreshRate': 60.0};
        case 'setPreferredMode':
          return null;
      }
      return null;
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(displayModeChannel, null);
    messenger.setMockMethodCallHandler(pluginChannel, null);
    AndroidDisplayModeService.instance.debugResetForTest();
  });

  test('native handling suppresses the plugin fallback', () async {
    await service().requestHighRefreshRate();

    expect(nativeCalls.map((c) => c.method), ['requestHighRefreshRate']);
    expect(pluginCalls, isEmpty);
  });

  test('native false (SDK < 35) falls back to flutter_displaymode', () async {
    nativeHandled = false;

    await service().requestHighRefreshRate();

    // setHighRefreshRate(): pick max refresh at active resolution -> mode 2.
    expect(pluginCalls.map((c) => c.method), [
      'getSupportedModes',
      'getActiveMode',
      'setPreferredMode',
    ]);
    expect(pluginCalls.last.arguments, {'mode': 2});
  });

  test('native channel failure never throws and skips fallback', () async {
    nativeError = PlatformException(code: 'boom');

    await service().requestHighRefreshRate();

    expect(nativeCalls, isEmpty);
    expect(pluginCalls, isEmpty);
  });

  test('does nothing on non-Android platforms', () async {
    AndroidDisplayModeService.instance.debugResetForTest();

    await AndroidDisplayModeService.instance.requestHighRefreshRate();
    AndroidDisplayModeService.instance.install();

    if (!Platform.isAndroid) {
      expect(nativeCalls, isEmpty);
      expect(pluginCalls, isEmpty);
    }
  });
  test('install is idempotent and fires exactly one initial request',
      () async {
    service()
      ..install()
      ..install();

    await Future<void>.delayed(Duration.zero);

    expect(nativeCalls, hasLength(1));
  });
}
