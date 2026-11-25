import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/harness/pages/home/harness_session_catalog.dart';
import 'package:Cuplivo/features/harness/services/dsh_surface_harvest.dart';
import 'package:Cuplivo/features/harness/widgets/dsh_side_bar.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../support/business_test_harness.dart';

/// R5's entry list is spec-driven: the DSH built-ins before a harvest, the
/// official sidebar rows afterwards plus exactly one built-in 更多. Plugin rows
/// must never be invented, and there is no placeholder text.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpSideBar(
    WidgetTester tester, {
    List<DshSurfaceEntry> harvestedEntries = const <DshSurfaceEntry>[],
    ValueChanged<DshSidebarEntrySpec>? onOpenEntry,
  }) async {
    tester.view.physicalSize = const Size(420, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Row taps go through `IosCardPress`, whose haptic path reads
    // SettingsProvider; the real app always has it above the drawer.
    final settings = SettingsProvider(createBusinessTestPreferences());
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: DshSideBar(
              remoteName: 'Studio',
              catalog: HarnessUnavailableSessionCatalog(),
              selectedSessionId: null,
              onSelectSession: (_) {},
              onNewSession: ({String? workspaceId}) async {},
              onOpenEntry: onOpenEntry ?? (_) {},
              harvestedEntries: harvestedEntries,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('pre-harvest R5', () {
    testWidgets('renders the built-ins and keeps the e2e anchors', (
      tester,
    ) async {
      await pumpSideBar(tester);

      expect(find.byKey(const Key('dsh-entry-plugins')), findsOneWidget);
      expect(find.byKey(const Key('dsh-entry-automations')), findsOneWidget);
      expect(find.byKey(const Key('dsh-entry-more')), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('dsh-sidebar-entry-plugins')),
        findsOneWidget,
      );
      expect(find.text('Plugins'), findsOneWidget);
      expect(find.text('Automations'), findsOneWidget);
      expect(find.text('More'), findsOneWidget);
    });

    testWidgets('shows built-ins only, with no invented plugin rows', (
      tester,
    ) async {
      await pumpSideBar(tester);

      expect(find.text('Search service'), findsNothing);
      expect(find.byKey(const Key('dsh-sidebar-plugins-hint')), findsNothing);
    });

    testWidgets('a tap reports the spec of the row, not its label', (
      tester,
    ) async {
      final opened = <DshSidebarEntrySpec>[];
      await pumpSideBar(tester, onOpenEntry: opened.add);

      await tester.tap(
        find.byKey(const ValueKey<String>('dsh-sidebar-entry-more')),
      );
      await tester.pump();

      expect(opened, hasLength(1));
      expect(opened.single.id, DshSidebarEntryIds.more);
      expect(opened.single.isHarvested, isFalse);
    });
  });

  group('harvested R5', () {
    // 更多 is DSH's own PanelMoreMenu, not a panellist row: the harvest never
    // carries it, and Cuplivo appends its built-in 更多 row itself.
    const harvested = <DshSurfaceEntry>[
      DshSurfaceEntry(label: '插件'),
      DshSurfaceEntry(label: '搜索服务'),
      DshSurfaceEntry(label: '自动化任务'),
    ];

    testWidgets('renders the official rows in order, then one built-in 更多', (
      tester,
    ) async {
      await pumpSideBar(tester, harvestedEntries: harvested);

      final labels = ['插件', '搜索服务', '自动化任务', 'More'];
      final ys = <double>[
        for (final label in labels) tester.getTopLeft(find.text(label)).dy,
      ];
      expect(ys, orderedEquals([...ys]..sort()));
      expect(
        ys.toSet(),
        hasLength(labels.length),
        reason: 'every harvested row keeps its own line',
      );
    });

    testWidgets('keys are the stable slug of the label; 更多 keeps its '
        'built-in id', (tester) async {
      await pumpSideBar(tester, harvestedEntries: harvested);

      expect(
        find.byKey(const ValueKey<String>('dsh-sidebar-entry-搜索服务')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('dsh-sidebar-entry-自动化任务')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('dsh-sidebar-entry-more')),
        findsOneWidget,
      );
      // The pre-harvest fallback anchors describe the built-in plugin rows
      // only; with a snapshot the official rows replace them. 更多 stays.
      expect(find.byKey(const Key('dsh-entry-plugins')), findsNothing);
      expect(find.byKey(const Key('dsh-entry-more')), findsOneWidget);
      expect(find.text('Plugins'), findsNothing);
    });

    testWidgets('a tap reports the harvested label and lands on it', (
      tester,
    ) async {
      final opened = <DshSidebarEntrySpec>[];
      await pumpSideBar(
        tester,
        harvestedEntries: harvested,
        onOpenEntry: opened.add,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('dsh-sidebar-entry-搜索服务')),
      );
      await tester.pump();

      expect(opened, hasLength(1));
      expect(opened.single.label, '搜索服务');
      expect(opened.single.isHarvested, isTrue);
      expect(opened.single.id, '搜索服务');
    });

    testWidgets('the 更多 row stays a built-in spec', (tester) async {
      final opened = <DshSidebarEntrySpec>[];
      await pumpSideBar(
        tester,
        harvestedEntries: harvested,
        onOpenEntry: opened.add,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('dsh-sidebar-entry-more')),
      );
      await tester.pump();

      expect(opened.single.id, DshSidebarEntryIds.more);
      expect(opened.single.isHarvested, isFalse);
    });

    testWidgets('empty and repeated labels are dropped', (tester) async {
      await pumpSideBar(
        tester,
        harvestedEntries: const <DshSurfaceEntry>[
          DshSurfaceEntry(label: '  '),
          DshSurfaceEntry(label: 'Search service'),
          DshSurfaceEntry(label: 'Search service'),
        ],
      );

      expect(find.text('Search service'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('dsh-sidebar-entry-search-service')),
        findsOneWidget,
      );
    });
  });
}
