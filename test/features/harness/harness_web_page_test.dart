import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/services/harness/harness_tailcat_dialer.dart';
import 'package:Cuplivo/core/services/harness/harness_tailcat_tunnels.dart';
import 'package:Cuplivo/features/harness/pages/harness_web_page.dart';
import 'package:Cuplivo/features/harness/widgets/harness_web_view.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

import '../../support/business_test_harness.dart';

const String _launchUrl = 'https://dsh.example.com/webui?token=launch';
const String _tailcatAddress =
    'tcAPpXUQeEXAMPLEaddressEXAMPLEaddressEXAMPLEaddressEXAMPLE00';

/// A dialer that fails the way a missing peer does, so the page's tunnel
/// failure path is observable without a network.
final class _FailingDialer implements HarnessTailcatDialer {
  @override
  Future<Socket> connect(int port) async =>
      throw const SocketException('peer offline');

  @override
  Future<void> close() async {}
}

HarnessTailcatTunnels _failingTunnels() => HarnessTailcatTunnels(
  dialer: (_) => throw const HarnessTailcatTunnelException(
    HarnessTailcatTunnelFailure.tunnelUnavailable,
  ),
);

Future<AssistantProvider> _providerFor(List<Assistant> assistants) async {
  final harness = await createBusinessTestHarness(
    initial: <String, Object?>{
      'assistants_v1': Assistant.encodeList(assistants),
      'current_assistant_id_v1': assistants.first.id,
    },
  );
  final provider = AssistantProvider(preferences: harness.preferences);
  addTearDown(provider.dispose);
  await provider.loaded;
  return provider;
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required AssistantProvider assistants,
  required String assistantId,
  HarnessTailcatTunnels? tunnels,
}) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
        Provider<HarnessTailcatTunnels>.value(
          value: tunnels ?? HarnessTailcatTunnels(),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HarnessWebPage(assistantId: assistantId),
      ),
    ),
  );
  // The tailcat page opens its tunnel in initState; two pumps paint the first
  // future state and whatever it resolved to.
  await tester.pump();
  await tester.pump();
}

/// Runs [body] on a platform without a native WebView, so the page's own
/// wiring is visible without a platform view. The binding asserts debug
/// variables are restored at the end of the body, so this is a `finally`.
Future<void> _runOnLinux(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final linked = Assistant.harness(
    id: 'linked',
    name: 'Linked harness',
    harnessUrl: _launchUrl,
  );
  final tailcat = Assistant.harness(
    id: 'tailcat',
    name: 'Tailcat harness',
    harnessConnectionMode: HarnessConnectionMode.tailcat,
    harnessTailcatAddress: _tailcatAddress,
  );
  final unconfigured = Assistant.harness(
    id: 'unconfigured',
    name: 'Unconfigured harness',
  );

  testWidgets('a link-mode harness embeds its launch link directly', (
    tester,
  ) async {
    await _runOnLinux(tester, () async {
      final assistants = await _providerFor(<Assistant>[linked]);
      await _pumpPage(tester, assistants: assistants, assistantId: linked.id);

      expect(find.byKey(const Key('harness-web-page')), findsOneWidget);
      expect(find.byKey(const Key('harness-return-button')), findsOneWidget);
      final view = tester.widget<HarnessWebView>(find.byType(HarnessWebView));
      expect(view.url, _launchUrl);
    });
  });

  testWidgets(
    'a tailcat-mode harness embeds its tunnel origin, not the address',
    (tester) async {
      await _runOnLinux(tester, () async {
        final assistants = await _providerFor(<Assistant>[tailcat]);
        // A factory that opens the loopback tunnel but never dials: the page only
        // renders the origin the tunnel serves.
        final tunnels = HarnessTailcatTunnels(dialer: (_) => _FailingDialer());
        addTearDown(tunnels.closeAll);
        await _pumpPage(
          tester,
          assistants: assistants,
          assistantId: tailcat.id,
          tunnels: tunnels,
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('harness-web-page')), findsOneWidget);
        final view = tester.widget<HarnessWebView>(find.byType(HarnessWebView));
        expect(view.url, startsWith('http://127.0.0.1:'));
        expect(view.url, isNot(contains(_tailcatAddress)));
        expect(find.byKey(const Key('harness-tailcat-error')), findsNothing);
      });
    },
  );

  testWidgets('a failed tunnel shows the reason and can be retried', (
    tester,
  ) async {
    await _runOnLinux(tester, () async {
      final assistants = await _providerFor(<Assistant>[tailcat]);
      final tunnels = _failingTunnels();
      addTearDown(tunnels.closeAll);
      await _pumpPage(
        tester,
        assistants: assistants,
        assistantId: tailcat.id,
        tunnels: tunnels,
      );
      await tester.pumpAndSettle();

      final l10n = AppLocalizations.of(
        tester.element(find.byType(HarnessWebPage)),
      )!;
      expect(find.byKey(const Key('harness-tailcat-error')), findsOneWidget);
      expect(
        find.text(l10n.assistantHarnessTailcatUnavailable),
        findsOneWidget,
      );
      expect(find.byKey(const Key('harness-web-view')), findsNothing);

      await tester.tap(find.byKey(const Key('harness-tailcat-retry')));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('harness-tailcat-error')), findsOneWidget);
      expect(find.byKey(const Key('harness-tailcat-retry')), findsOneWidget);
    });
  });

  testWidgets(
    'a tailcat tunnel that cannot be opened on this platform is explained',
    (tester) async {
      await _runOnLinux(tester, () async {
        final assistants = await _providerFor(<Assistant>[tailcat]);
        final tunnels = HarnessTailcatTunnels(
          dialer: (_) => throw const HarnessTailcatTunnelException(
            HarnessTailcatTunnelFailure.unsupportedPlatform,
          ),
        );
        addTearDown(tunnels.closeAll);
        await _pumpPage(
          tester,
          assistants: assistants,
          assistantId: tailcat.id,
          tunnels: tunnels,
        );
        await tester.pumpAndSettle();

        final l10n = AppLocalizations.of(
          tester.element(find.byType(HarnessWebPage)),
        )!;
        expect(
          find.text(l10n.assistantHarnessTailcatUnsupported),
          findsOneWidget,
        );
      });
    },
  );

  testWidgets('an unconfigured harness leaves the page instead of showing it', (
    tester,
  ) async {
    await _runOnLinux(tester, () async {
      final assistants = await _providerFor(<Assistant>[unconfigured]);
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
            Provider<HarnessTailcatTunnels>(
              create: (_) => HarnessTailcatTunnels(),
            ),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: Text('home')),
            routes: <String, WidgetBuilder>{
              '/harness': (_) => HarnessWebPage(assistantId: unconfigured.id),
            },
          ),
        ),
      );
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pushNamed('/harness');
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.byType(HarnessWebPage), findsNothing);
      expect(find.text('home'), findsOneWidget);
    });
  });

  testWidgets('the return button goes back from the embedded WebUI', (
    tester,
  ) async {
    await _runOnLinux(tester, () async {
      final assistants = await _providerFor(<Assistant>[linked]);
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
            Provider<HarnessTailcatTunnels>(
              create: (_) => HarnessTailcatTunnels(),
            ),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: Text('home')),
          ),
        ),
      );
      tester
          .state<NavigatorState>(find.byType(Navigator))
          .push(
            MaterialPageRoute<void>(
              builder: (_) => HarnessWebPage(assistantId: linked.id),
            ),
          );
      await tester.pumpAndSettle();
      expect(find.byType(HarnessWebPage), findsOneWidget);

      await tester.tap(find.byKey(const Key('harness-return-button')));
      await tester.pumpAndSettle();

      expect(find.byType(HarnessWebPage), findsNothing);
      expect(find.text('home'), findsOneWidget);
    });
  });
}
