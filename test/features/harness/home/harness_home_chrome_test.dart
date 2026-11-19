import 'package:Cuplivo/features/harness/pages/home/harness_home_chrome.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The harness chrome widgets the existing home scaffolds render in remote
/// mode: the R6 app bar and the R7 desktop rail host.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(1200, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      ),
    );
    await tester.pump();
  }

  group('HarnessAppBar', () {
    Future<void> pumpBar(WidgetTester tester, {String? subtitle}) {
      return pump(
        tester,
        Scaffold(
          appBar: HarnessAppBar(
            title: 'Session title',
            subtitle: subtitle,
            onToggleSidebar: () {},
            onNewSession: () {},
            onToggleRail: () {},
            railOpen: false,
          ),
          body: const SizedBox.expand(),
        ),
      );
    }

    testWidgets('shows the session title and the model (provider) subtitle', (
      tester,
    ) async {
      await pumpBar(tester, subtitle: 'deepseek-flash (DeepSeek)');
      expect(find.text('Session title'), findsOneWidget);
      expect(find.text('deepseek-flash (DeepSeek)'), findsOneWidget);
    });

    testWidgets('carries the stable e2e keys on its two actions', (
      tester,
    ) async {
      await pumpBar(tester);
      expect(find.byKey(const Key('dsh-new-session')), findsOneWidget);
      expect(find.byKey(const Key('dsh-right-rail-button')), findsOneWidget);
    });

    testWidgets(
      'no local-chat controls: no minimap, no find, no multi-select',
      (tester) async {
        await pumpBar(tester);
        final icons = tester
            .widgetList<Icon>(find.byType(Icon))
            .map((icon) => icon.icon)
            .toList();
        expect(icons, isNot(contains(Icons.map)));
        expect(icons, isNot(contains(Icons.search)));
        expect(icons, isNot(contains(Icons.checklist)));
      },
    );

    testWidgets('the new-session action precedes the rail action', (
      tester,
    ) async {
      await pumpBar(tester);
      final newSession = tester.getTopLeft(
        find.byKey(const Key('dsh-new-session')),
      );
      final rail = tester.getTopLeft(
        find.byKey(const Key('dsh-right-rail-button')),
      );
      expect(newSession.dx, lessThan(rail.dx));
    });
  });

  group('HarnessRightRailHost', () {
    testWidgets('closed: the rail is absent and the chat keeps the width', (
      tester,
    ) async {
      await pump(
        tester,
        HarnessRightRailHost(
          open: false,
          expanded: false,
          rail: const Text('rail-content'),
          child: const Text('chat-content'),
        ),
      );
      expect(find.text('chat-content'), findsOneWidget);
      expect(find.text('rail-content'), findsNothing);
    });

    testWidgets('docked: rail and chat are both on screen', (tester) async {
      await pump(
        tester,
        HarnessRightRailHost(
          open: true,
          expanded: false,
          rail: const Text('rail-content'),
          child: const Text('chat-content'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('rail-content'), findsOneWidget);
      expect(find.text('chat-content'), findsOneWidget);
      final railText = tester.getTopLeft(find.text('rail-content')).dx;
      final chatText = tester.getTopLeft(find.text('chat-content')).dx;
      expect(chatText, lessThan(railText));
    });

    testWidgets('expanded: the rail takes the width, the chat is pushed off', (
      tester,
    ) async {
      await pump(
        tester,
        HarnessRightRailHost(
          open: true,
          expanded: true,
          rail: const Text('rail-content'),
          child: const Text('chat-content'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('rail-content'), findsOneWidget);
      // Present but offstage: state is kept, nothing is painted under the rail.
      expect(find.text('chat-content'), findsNothing);
    });

    testWidgets('narrow surface: the rail takes it all (no stacking)', (
      tester,
    ) async {
      await pump(
        tester,
        HarnessRightRailHost(
          open: true,
          expanded: false,
          rail: const Text('rail-content'),
          child: const Text('chat-content'),
        ),
        size: const Size(700, 900),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('rail-content'), findsOneWidget);
      expect(tester.getSize(find.text('rail-content')).width, greaterThan(0));
      expect(find.text('chat-content'), findsNothing);
    });
  });
}
