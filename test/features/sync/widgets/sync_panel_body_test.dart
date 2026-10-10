import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/providers/sync_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/sync/business_state_reloader.dart';
import 'package:Cuplivo/features/sync/widgets/sync_panel_body.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
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

  @override
  void panelOpened() => openedPanels++;

  @override
  void panelClosed() => closedPanels++;
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
}
