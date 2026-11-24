import 'package:Cuplivo/features/harness/widgets/harness_web_view.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/link.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

const _launchUrl = 'https://dsh-e2e.example.com/webui?token=e2e-token';

class _FakeUrlLauncher extends UrlLauncherPlatform {
  String? launchedUrl;
  PreferredLaunchMode? launchedMode;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launchedUrl = url;
    launchedMode = options.mode;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('harnessWebViewSupported', () {
    test('native WebView platforms can embed the WebUI', () {
      for (final platform in const [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      ]) {
        expect(
          harnessWebViewSupported(platform, isWeb: false),
          isTrue,
          reason: '$platform has a native WebView',
        );
      }
    });

    test('platforms without a native WebView cannot embed the WebUI', () {
      for (final platform in const [
        TargetPlatform.linux,
        TargetPlatform.fuchsia,
      ]) {
        expect(
          harnessWebViewSupported(platform, isWeb: false),
          isFalse,
          reason: '$platform has no native WebView',
        );
      }
    });

    test('a web build never embeds the WebUI', () {
      for (final platform in TargetPlatform.values) {
        expect(
          harnessWebViewSupported(platform, isWeb: true),
          isFalse,
          reason: 'a web build cannot embed itself, even as $platform',
        );
      }
    });
  });

  group('harnessWindowsProfilePath', () {
    test('puts the DSH WebView2 profile under app data', () {
      final appData = p.join('cuplivo', 'app-data');
      final profile = harnessWindowsProfilePath(appData);
      expect(profile, p.join(appData, 'harness', 'webview2'));
      expect(p.basename(profile), 'webview2');
      expect(p.basename(p.dirname(profile)), 'harness');
    });

    test('never shares the browser feature profile', () {
      final appData = p.join('cuplivo', 'app-data');
      final profile = harnessWindowsProfilePath(appData);
      expect(p.split(profile), isNot(contains('browser')));
      expect(profile, isNot(p.join(appData, 'browser', 'webview2')));
    });
  });

  group('HarnessWebView on an unsupported platform', () {
    late UrlLauncherPlatform previousLauncher;
    late _FakeUrlLauncher launcher;
    late AppLocalizations english;

    setUp(() async {
      previousLauncher = UrlLauncherPlatform.instance;
      launcher = _FakeUrlLauncher();
      UrlLauncherPlatform.instance = launcher;
      english = await AppLocalizations.delegate.load(const Locale('en'));
    });

    tearDown(() {
      UrlLauncherPlatform.instance = previousLauncher;
      debugDefaultTargetPlatformOverride = null;
    });

    Future<void> pumpOnLinux(WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: const Scaffold(body: HarnessWebView(url: _launchUrl)),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows the unsupported state instead of a native WebView', (
      tester,
    ) async {
      await pumpOnLinux(tester);

      expect(find.byKey(const Key('harness-web-view')), findsOneWidget);
      expect(
        find.byKey(const Key('harness-web-view-unsupported')),
        findsOneWidget,
      );
      expect(
        find.text(english.assistantHarnessUnsupportedPlatform),
        findsOneWidget,
      );
      expect(find.text(english.assistantHarnessOpenInBrowser), findsOneWidget);

      // The error state and the native view must not exist on this platform.
      expect(find.byKey(const Key('harness-web-view-error')), findsNothing);
      expect(find.byKey(const Key('harness-web-view-retry')), findsNothing);
      expect(find.byType(InAppWebView), findsNothing);
    });

    testWidgets('opening the link uses an external application', (
      tester,
    ) async {
      await pumpOnLinux(tester);

      await tester.tap(find.byKey(const Key('harness-web-view-open-browser')));
      await tester.pump();

      expect(launcher.launchedUrl, _launchUrl);
      expect(launcher.launchedMode, PreferredLaunchMode.externalApplication);
    });
  });
}
