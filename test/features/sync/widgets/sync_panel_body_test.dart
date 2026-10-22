import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/providers/sync_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/sync/business_state_reloader.dart';
import 'package:Cuplivo/features/sync/sync_messages.dart';
import 'package:Cuplivo/features/sync/widgets/sync_panel_body.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/utils/format_bytes.dart';
import 'package:Cuplivo/shared/widgets/ios_switch.dart';
import 'package:Cuplivo/shared/widgets/tip_icon.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';

/// `ChatService.init` asks the platform for the app documents directory, and
/// the test host has no plugin to answer with. The same fake the sync
/// integration tests register.
class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => '$path/cache';
}

/// The panel body needs no engine to mount; what these tests observe is which
/// viewer calls reached the provider, so they are recorded rather than counted.
class _PanelCountingProvider extends SyncProvider {
  _PanelCountingProvider({
    required super.chatService,
    required super.repository,
    required super.businessRepository,
    required super.businessPreferences,
    required super.reloader,
    required super.syncDirectory,
  });

  int openedPanels = 0;
  int closedPanels = 0;

  /// The workspace switch's wiring: which workspace was toggled, and to what.
  /// The persistence behind it is `WorkspaceContentSync.setEnabled`, covered in
  /// `workspace_content_sync_test.dart` — a tap-driven file write never
  /// completes inside the fake-async zone these widget tests run in.
  final List<(String, bool)> workspaceToggles = [];

  @override
  void panelOpened() => openedPanels++;

  @override
  void panelClosed() => closedPanels++;

  @override
  Future<void> setWorkspaceContentEnabled(String id, bool enabled) async {
    workspaceToggles.add((id, enabled));
  }
}

/// One test's world: the panel's provider and the services that outlive it.
typedef _Harness = ({
  _PanelCountingProvider provider,
  Widget Function(Widget home) app,
});

/// Builds the harness. Everything that touches the real world happens inside
/// [WidgetTester.runAsync]: `testWidgets` runs its body in a fake-async zone,
/// where an I/O future never completes.
Future<_Harness> _harness(WidgetTester tester) async {
  late final Directory root;
  late final ChatService chatService;
  late final ChatDatabaseRepository repository;
  late final _PanelCountingProvider provider;

  await tester.runAsync(() async {
    root = await Directory.systemTemp.createTemp('sync-panel-body');
    PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
    final database = AppDatabase(NativeDatabase.memory());
    repository = ChatDatabaseRepository(database);
    final businessRepository = BusinessRepository(database);
    final businessPreferences = BusinessPreferences(businessRepository);
    chatService = ChatService(existingRepository: repository);
    await repository.ensureReady();
    await chatService.init();
    await businessPreferences.load();
    provider = _PanelCountingProvider(
      chatService: chatService,
      repository: repository,
      businessRepository: businessRepository,
      businessPreferences: businessPreferences,
      reloader: BusinessStateReloader(businessPreferences),
      syncDirectory: () async => root,
    );
  });
  addTearDown(() async {
    provider.dispose();
    await chatService.close();
    await repository.close();
    await root.delete(recursive: true);
  });

  Widget app(Widget home) => ChangeNotifierProvider<SyncProvider>.value(
    value: provider,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  );
  return (provider: provider, app: app);
}

void main() {
  testWidgets('leaving the page releases the viewer, not an ancestor lookup', (
    tester,
  ) async {
    final (:provider, :app) = await _harness(tester);

    await tester.pumpWidget(app(const Scaffold(body: SyncPanelBody())));
    await tester.pumpAndSettle();
    expect(provider.openedPanels, 1, reason: 'a mounted panel is a viewer');

    // Navigating away unmounts the body in the same frame's finalizeTree —
    // exactly where a dispose-time ancestor lookup (even a `read`) throws
    // "Looking up a deactivated widget's ancestor is unsafe". The release
    // must use a reference kept while the element was alive.
    await tester.pumpWidget(app(const Scaffold(body: Text('elsewhere'))));
    await tester.pumpAndSettle();

    expect(provider.closedPanels, 1, reason: 'the viewer is released');
  });

  testWidgets('a panel left mounted but offstage releases its viewer', (
    tester,
  ) async {
    final (:provider, :app) = await _harness(tester);

    // The desktop home page's own shape: the settings page — and, inside it,
    // the LAN sync pane the user selected — is a permanent `IndexedStack`
    // child, because the tabs are kept alive ("so ongoing chat streams are not
    // canceled when switching tabs", desktop_home_page.dart). Switching tabs
    // there stops painting the panel without unmounting it, so a viewer mark
    // tied to mount state would mute every arrival for the rest of the launch.
    Widget shell(int tab) => app(
      Scaffold(
        body: IndexedStack(
          index: tab,
          children: const [
            Center(child: Text('chat tab')),
            SyncPanelBody(),
          ],
        ),
      ),
    );

    await tester.pumpWidget(shell(1));
    await tester.pumpAndSettle();
    expect(provider.openedPanels, 1, reason: 'the LAN sync pane is on screen');
    expect(provider.closedPanels, 0);

    // Back to the chat tab: the panel is offstage but still in the element
    // tree, so `dispose` never runs.
    await tester.pumpWidget(shell(0));
    await tester.pumpAndSettle();
    expect(
      find.byType(SyncPanelBody, skipOffstage: false),
      findsOneWidget,
      reason: 'IndexedStack keeps the non-selected children mounted',
    );
    expect(find.byType(SyncPanelBody), findsNothing);
    expect(
      provider.closedPanels,
      1,
      reason: 'the cards are not on screen, so arrivals must be announced',
    );

    // And it counts again once the pane is back in front of the user.
    await tester.pumpWidget(shell(1));
    await tester.pumpAndSettle();
    expect(provider.openedPanels, 2);
    expect(provider.closedPanels, 1);
  });

  testWidgets('the this-device row shows no address at all', (tester) async {
    final (:provider, :app) = await _harness(tester);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    // A running listener on a known network — the state the row is *for*, and
    // the state the old card answered with a list of every interface.
    provider.started = true;
    provider.port = 9527;
    provider.localAddresses = const [(name: 'wlan0', address: '10.9.0.5')];

    await tester.pumpWidget(app(const Scaffold(body: SyncPanelBody())));
    await tester.pumpAndSettle();

    expect(find.text(Platform.localHostname), findsOneWidget);
    expect(
      find.text(
        '${syncPlatformLabel(l10n, Platform.operatingSystem)} · '
        '${l10n.lanSyncListening} 9527',
      ),
      findsOneWidget,
      reason:
          'the OS and the port are what this row says instead of an address',
    );
    expect(
      find.textContaining('10.9.0.5'),
      findsNothing,
      reason: 'the addresses belong to the pairing dialog and to the tiles',
    );
  });

  testWidgets('every section that needs rules keeps them behind an ⓘ', (
    tester,
  ) async {
    final (:provider, :app) = await _harness(tester);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    // The workspace section only exists once there is a workspace to show, and
    // its ⓘ is part of it.
    provider.workspaceSummaries = const [
      SyncWorkspaceSummary(
        id: 'workspace-1',
        name: 'cuplivo',
        fileCount: 1,
        totalBytes: 1,
        truncated: false,
        enabled: true,
      ),
    ];

    await tester.pumpWidget(app(const Scaffold(body: SyncPanelBody())));
    await tester.pumpAndSettle();

    for (final tip in [
      l10n.lanSyncPairTrustTip,
      l10n.lanSyncEndpointTip,
      l10n.lanSyncWorkspaceTip,
    ]) {
      expect(
        find.byWidgetPredicate(
          (widget) => widget is TipIcon && widget.message == tip,
        ),
        findsOneWidget,
        reason: 'the rule is one tap away instead of a footnote nobody reads',
      );
    }
    // The paragraphs that used to be on the face of the panel are gone with
    // them: the pairing section is one sentence and two buttons.
    expect(find.text(l10n.lanSyncPairIntro), findsOneWidget);
    expect(find.text(l10n.lanSyncShowCode), findsOneWidget);
    expect(find.text(l10n.lanSyncEnterCode), findsOneWidget);
  });

  testWidgets('the workspace section says what is syncing and what is not', (
    tester,
  ) async {
    final (:provider, :app) = await _harness(tester);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    const offId = 'workspace-off';
    provider.workspaceSummaries = const [
      SyncWorkspaceSummary(
        id: 'workspace-1',
        name: 'cuplivo',
        fileCount: 1842,
        totalBytes: 90596966,
        truncated: false,
        enabled: true,
      ),
      SyncWorkspaceSummary(
        id: 'workspace-2',
        name: 'lab-notes',
        fileCount: 2001,
        totalBytes: 3254779904,
        truncated: true,
        enabled: true,
      ),
      SyncWorkspaceSummary(
        id: offId,
        name: 'screenshots',
        fileCount: 1102,
        totalBytes: 222298112,
        truncated: false,
        enabled: false,
      ),
      SyncWorkspaceSummary(
        id: 'workspace-4',
        name: 'locked-notes',
        fileCount: 12,
        totalBytes: 4096,
        truncated: false,
        unreadable: true,
        enabled: true,
      ),
    ];

    await tester.pumpWidget(
      // Both hosts put the panel in a scroll view (the mobile page and the
      // desktop pane own the scrolling), so a panel taller than the test
      // surface is a test artifact, not a layout fault.
      app(Scaffold(body: SingleChildScrollView(child: SyncPanelBody()))),
    );
    await tester.pumpAndSettle();

    expect(find.text(l10n.lanSyncWorkspaces), findsOneWidget);
    expect(
      find.text(l10n.lanSyncWorkspaceSyncing(1)),
      findsOneWidget,
      reason: 'only the workspace that is both on and inside the caps counts',
    );
    for (final name in ['cuplivo', 'lab-notes', 'screenshots']) {
      expect(find.text(name), findsOneWidget);
    }
    expect(
      find.text(
        '${l10n.lanSyncWorkspaceFiles(1842)} · ${formatBytes(90596966)}',
      ),
      findsOneWidget,
    );
    // An over-cap workspace is never walked to the end, so both of its figures
    // are lower bounds and both are written as such.
    expect(
      find.text(
        '${l10n.lanSyncWorkspaceFilesAtLeast(2001)} · '
        '${l10n.lanSyncWorkspaceSizeAtLeast(formatBytes(3254779904))}',
      ),
      findsOneWidget,
    );
    expect(find.text(l10n.lanSyncWorkspaceStatusSyncing), findsOneWidget);
    expect(find.text(l10n.lanSyncWorkspaceStatusTooLarge), findsOneWidget);
    expect(find.text(l10n.lanSyncWorkspaceStatusOff), findsOneWidget);
    expect(
      find.text(l10n.lanSyncWorkspaceStatusUnreadable),
      findsOneWidget,
      reason:
          'a folder this device could not read is not syncing, and the row '
          'must not look like it is',
    );

    // The switch is wired to the workspace it belongs to, not to the row's
    // position: the off row is not the only one, and turning it on must name
    // *it*.
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is IosSwitch && widget.semanticLabel == 'screenshots',
      ),
    );
    await tester.pump();
    expect(provider.workspaceToggles, [(offId, true)]);
  });

  testWidgets('a device with no managed workspace shows no section at all', (
    tester,
  ) async {
    final (:provider, :app) = await _harness(tester);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));

    await tester.pumpWidget(app(const Scaffold(body: SyncPanelBody())));
    await tester.pumpAndSettle();
    expect(
      find.text(l10n.lanSyncWorkspaces),
      findsNothing,
      reason: 'nothing has been counted yet, so the section says nothing',
    );

    provider.workspaceSummaries = const [];
    await tester.pumpAndSettle();
    expect(
      find.text(l10n.lanSyncWorkspaces),
      findsNothing,
      reason: 'and "no workspaces" is still nothing to say',
    );
  });
}
