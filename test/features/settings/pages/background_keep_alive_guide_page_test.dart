import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/background_protection_service.dart';
import 'package:Cuplivo/features/settings/pages/background_keep_alive_guide_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/snackbar.dart';

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
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    svc.debugForceAndroidForTest = false;
    svc.debugManufacturerOverrideForTest = null;
    svc.resetForTest();
  });

  Future<SettingsProvider> makeSettings(WidgetTester tester) async {
    final sp = await tester.runAsync(() async {
      final provider = SettingsProvider(
        preferences: BusinessPreferences.memoryForTests({}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return provider;
    });
    return sp!;
  }

  Future<void> pumpGuide(WidgetTester tester, SettingsProvider sp) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: sp,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const AppSnackBarOverlay(child: BackgroundKeepAliveGuidePage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders all sections and an unknown-vendor hint', (
    tester,
  ) async {
    final sp = await makeSettings(tester);
    await pumpGuide(tester, sp);

    final l10n = AppLocalizations.of(
      tester.element(find.byType(BackgroundKeepAliveGuidePage)),
    )!;
    expect(find.text(l10n.keepAliveGuidePageTitle), findsOneWidget);
    expect(find.text(l10n.keepAliveGuideBatteryTitle), findsOneWidget);
    expect(find.text(l10n.keepAliveGuideNotificationTitle), findsOneWidget);
    expect(find.text(l10n.keepAliveGuideVendorTitle), findsOneWidget);
    expect(find.text(l10n.keepAliveGuideLockTitle), findsOneWidget);
    expect(find.text(l10n.keepAliveGuideVendorNotDetected), findsOneWidget);
    expect(find.text(l10n.keepAliveGuideOtherVendorHint), findsOneWidget);
    expect(find.text(l10n.keepAliveGuideAutostartAction), findsNothing);
    expect(find.text(l10n.keepAliveGuidePowerAction), findsOneWidget);
  });

  testWidgets(
    'renders vendor-specific section for Xiaomi with both jump tiles',
    (tester) async {
      svc.debugManufacturerOverrideForTest = 'Xiaomi';
      final sp = await makeSettings(tester);
      await pumpGuide(tester, sp);

      final l10n = AppLocalizations.of(
        tester.element(find.byType(BackgroundKeepAliveGuidePage)),
      )!;
      expect(find.text(l10n.keepAliveGuideVendorXiaomi), findsOneWidget);
      expect(find.text(l10n.keepAliveGuideXiaomiHint), findsOneWidget);
      expect(find.text(l10n.keepAliveGuideAutostartAction), findsOneWidget);
      expect(find.text(l10n.keepAliveGuidePowerAction), findsOneWidget);
    },
  );

  testWidgets('autostart tile opens vendor settings with autostart kind', (
    tester,
  ) async {
    svc.debugManufacturerOverrideForTest = 'Xiaomi';
    svc.debugForceAndroidForTest = true;
    final sp = await makeSettings(tester);
    await pumpGuide(tester, sp);

    final l10n = AppLocalizations.of(
      tester.element(find.byType(BackgroundKeepAliveGuidePage)),
    )!;
    await tester.tap(find.text(l10n.keepAliveGuideAutostartAction));
    await tester.pumpAndSettle();

    final jump = calls.where((c) => c.method == 'openVendorSettings').toList();
    expect(jump, hasLength(1));
    expect(jump.single.arguments, {'vendor': 'xiaomi', 'kind': 'autostart'});
  });

  testWidgets('power tile opens vendor settings with battery kind', (
    tester,
  ) async {
    svc.debugManufacturerOverrideForTest = 'HUAWEI';
    svc.debugForceAndroidForTest = true;
    final sp = await makeSettings(tester);
    await pumpGuide(tester, sp);

    final l10n = AppLocalizations.of(
      tester.element(find.byType(BackgroundKeepAliveGuidePage)),
    )!;
    await tester.tap(find.text(l10n.keepAliveGuidePowerAction));
    await tester.pumpAndSettle();

    final jump = calls.where((c) => c.method == 'openVendorSettings').toList();
    expect(jump, hasLength(1));
    expect(jump.single.arguments, {'vendor': 'huawei', 'kind': 'battery'});
  });

  testWidgets('failed vendor jump surfaces an error message', (tester) async {
    svc.debugManufacturerOverrideForTest = 'Xiaomi';
    svc.debugForceAndroidForTest = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'openVendorSettings') return 'failed';
          if (call.method == 'isIgnoringBatteryOptimizations') return true;
          if (call.method == 'requestIgnoreBatteryOptimization') return true;
          return null;
        });
    final sp = await makeSettings(tester);
    await pumpGuide(tester, sp);

    final l10n = AppLocalizations.of(
      tester.element(find.byType(BackgroundKeepAliveGuidePage)),
    )!;
    await tester.tap(find.text(l10n.keepAliveGuidePowerAction));
    await tester.pumpAndSettle();

    expect(find.text(l10n.keepAliveGuideOpenFailed), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('fallback vendor jump surfaces the fallback hint only', (
    tester,
  ) async {
    svc.debugManufacturerOverrideForTest = 'Xiaomi';
    svc.debugForceAndroidForTest = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'openVendorSettings') return 'fallback';
          if (call.method == 'isIgnoringBatteryOptimizations') return true;
          if (call.method == 'requestIgnoreBatteryOptimization') return true;
          return null;
        });
    final sp = await makeSettings(tester);
    await pumpGuide(tester, sp);

    final l10n = AppLocalizations.of(
      tester.element(find.byType(BackgroundKeepAliveGuidePage)),
    )!;
    await tester.tap(find.text(l10n.keepAliveGuidePowerAction));
    await tester.pumpAndSettle();

    expect(find.text(l10n.keepAliveGuideFallbackOpened), findsOneWidget);
    expect(find.text(l10n.keepAliveGuideOpenFailed), findsNothing);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('notification denial surfaces an instructive message', (
    tester,
  ) async {
    svc.debugForceAndroidForTest = true;
    const permissionsChannel = MethodChannel(
      'flutter.baseflow.com/permissions/methods',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionsChannel, (call) async {
          if (call.method == 'requestPermissions') return <int, int>{17: 0};
          if (call.method == 'checkPermissionStatus') return 0;
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(permissionsChannel, null);
    });
    final sp = await makeSettings(tester);
    await pumpGuide(tester, sp);

    final l10n = AppLocalizations.of(
      tester.element(find.byType(BackgroundKeepAliveGuidePage)),
    )!;
    await tester.tap(find.text(l10n.keepAliveGuideNotificationTitle));
    await tester.pumpAndSettle();

    expect(find.text(l10n.keepAliveGuideNotificationsDenied), findsOneWidget);
    expect(find.text(l10n.keepAliveGuideOpenFailed), findsNothing);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'battery query failure shows a failed status instead of checking',
    (tester) async {
      svc.debugForceAndroidForTest = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'isIgnoringBatteryOptimizations') return null;
            return null;
          });
      final sp = await makeSettings(tester);
      await pumpGuide(tester, sp);

      final l10n = AppLocalizations.of(
        tester.element(find.byType(BackgroundKeepAliveGuidePage)),
      )!;
      expect(find.text(l10n.keepAliveGuideStatusQueryFailed), findsOneWidget);
    },
  );

  testWidgets('resuming from background refreshes battery status', (
    tester,
  ) async {
    svc.debugForceAndroidForTest = true;
    final sp = await makeSettings(tester);
    await pumpGuide(tester, sp);

    final initialQueries = calls
        .where((c) => c.method == 'isIgnoringBatteryOptimizations')
        .length;
    expect(initialQueries, greaterThanOrEqualTo(1));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    final afterResume = calls
        .where((c) => c.method == 'isIgnoringBatteryOptimizations')
        .length;
    expect(afterResume, initialQueries + 1);
  });
}
