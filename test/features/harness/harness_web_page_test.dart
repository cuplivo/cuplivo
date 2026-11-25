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

/// A loaded assistant view without the Drift-backed store: this page only reads
/// rows, so a real provider would make the widget test wait on database work
/// inside the fake-async zone for nothing.
class _InMemoryAssistantProvider extends AssistantProvider {
  _InMemoryAssistantProvider({required super.preferences});

  final List<Assistant> _rows = <Assistant>[];

  @override
  List<Assistant> get assistants => List<Assistant>.unmodifiable(_rows);

  @override
  Assistant? getById(String id) {
    for (final row in _rows) {
      if (row.id == id) return row;
    }
    return null;
  }

  void seed(Assistant assistant) => _rows.add(assistant);
}

const String _launchUrl = 'https://dsh.example.com/webui?token=launch';
const String _tailcatAddress =
    'tcAPpXUQeEXAMPLEaddressEXAMPLEaddressEXAMPLEaddressEXAMPLE00';

/// A dialer that fails the way a missing peer does, so the page's tunnel relay
/// path is observable without a network.
final class _FailingDialer implements HarnessTailcatDialer {
  @override
  Future<Socket> connect(int port) async =>
      throw const SocketException('peer offline');

  @override
  Future<void> close() async {}
}

HarnessTailcatTunnels _unavailableTunnels() => HarnessTailcatTunnels(
  dialer: (_) => throw const HarnessTailcatTunnelException(
    HarnessTailcatTunnelFailure.tunnelUnavailable,
  ),
);

Future<_InMemoryAssistantProvider> _providerFor(
  WidgetTester tester,
  List<Assistant> assistants,
) async {
  late _InMemoryAssistantProvider provider;
  await tester.runAsync(() async {
    provider = _InMemoryAssistantProvider(
      preferences: createBusinessTestPreferences(),
    );
    await provider.loaded;
    for (final assistant in assistants) {
      provider.seed(assistant);
    }
  });
  return provider;
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required _InMemoryAssistantProvider assistants,
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
      final assistants = await _providerFor(tester, <Assistant>[linked]);
      await _pumpPage(tester, assistants: assistants, assistantId: linked.id);
      await tester.pumpAndSettle();

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
        final assistants = await _providerFor(tester, <Assistant>[tailcat]);
        // A factory that opens the loopback tunnel but never dials: the page only
        // renders the origin the tunnel serves. Opening it ahead of the widget
        // keeps the real socket bind out of the fake-async zone.
        final tunnels = HarnessTailcatTunnels(dialer: (_) => _FailingDialer());
        late Uri origin;
        await tester.runAsync(() async {
          origin = await tunnels.ensureOpen(_tailcatAddress);
        });

        await _pumpPage(
          tester,
          assistants: assistants,
          assistantId: tailcat.id,
          tunnels: tunnels,
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('harness-web-page')), findsOneWidget);
        final view = tester.widget<HarnessWebView>(find.byType(HarnessWebView));
        expect(view.url, origin.toString());
        expect(view.url, startsWith('http://127.0.0.1:'));
        expect(view.url, isNot(contains(_tailcatAddress)));
        expect(find.byKey(const Key('harness-tailcat-error')), findsNothing);

        await tester.runAsync(tunnels.closeAll);
      });
    },
  );

  testWidgets('a failed tunnel shows the reason and can be retried', (
    tester,
  ) async {
    await _runOnLinux(tester, () async {
      final assistants = await _providerFor(tester, <Assistant>[tailcat]);
      final tunnels = _unavailableTunnels();
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
        final assistants = await _providerFor(tester, <Assistant>[tailcat]);
        final tunnels = HarnessTailcatTunnels(
          dialer: (_) => throw const HarnessTailcatTunnelException(
            HarnessTailcatTunnelFailure.unsupportedPlatform,
          ),
        );
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
      final assistants = await _providerFor(tester, <Assistant>[unconfigured]);
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
      tester
          .state<NavigatorState>(find.byType(Navigator))
          .pushNamed('/harness');
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
      final assistants = await _providerFor(tester, <Assistant>[linked]);
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
