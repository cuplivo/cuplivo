import 'dart:async';
import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/providers/sync_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/sync/business_state_reloader.dart';
import 'package:Cuplivo/core/services/sync/sync_engine.dart';
import 'package:Cuplivo/features/sync/widgets/sync_arrival_announcer.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/snackbar.dart';
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

/// The announcer only needs the arrival stream, so this provider never starts
/// an engine — but it is a real [SyncProvider], so the announcer is exercised
/// against the class it will read in the app.
class _AnnouncingProvider extends SyncProvider {
  _AnnouncingProvider({
    required super.chatService,
    required super.repository,
    required super.businessRepository,
    required super.businessPreferences,
    required super.reloader,
    required super.syncDirectory,
  });

  final StreamController<SyncArrival> arrivals =
      StreamController<SyncArrival>.broadcast();

  @override
  Stream<SyncArrival> get autoSyncArrivals => arrivals.stream;
}

void main() {
  testWidgets('an arrival toasts once, and Details opens the report', (
    tester,
  ) async {
    late final Directory root;
    late final ChatService chatService;
    late final ChatDatabaseRepository repository;
    late final _AnnouncingProvider provider;
    late final AppLocalizations l10n;

    // Everything that touches the real world happens here: `testWidgets` runs
    // its body in a fake-async zone, where an I/O future never completes.
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('sync-arrival-announcer');
      PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
      final database = AppDatabase(NativeDatabase.memory());
      repository = ChatDatabaseRepository(database);
      final businessRepository = BusinessRepository(database);
      final businessPreferences = BusinessPreferences(businessRepository);
      chatService = ChatService(existingRepository: repository);
      await repository.ensureReady();
      await chatService.init();
      await businessPreferences.load();
      provider = _AnnouncingProvider(
        chatService: chatService,
        repository: repository,
        businessRepository: businessRepository,
        businessPreferences: businessPreferences,
        reloader: BusinessStateReloader(businessPreferences),
        syncDirectory: () async => root,
      );
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });
    addTearDown(() async {
      AppSnackBarManager().dismissAll();
      await provider.arrivals.close();
      provider.dispose();
      await chatService.close();
      await repository.close();
      await root.delete(recursive: true);
    });

    // The dialog rides the root navigator (see the announcer) and the toast is
    // drawn by the app's own overlay, so the test app carries both — without
    // `AppSnackBarOverlay` the manager would hold an entry nobody renders.
    await tester.pumpWidget(
      ChangeNotifierProvider<SyncProvider>.value(
        value: provider,
        child: MaterialApp(
          navigatorKey: rootNavigatorKey,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) =>
              AppSnackBarOverlay(child: child ?? const SizedBox.shrink()),
          home: const Scaffold(
            body: SyncArrivalAnnouncer(child: Center(child: Text('shell'))),
          ),
        ),
      ),
    );

    const report = SyncSessionReport(
      success: true,
      summary: 'test',
      conversationsReceived: 2,
      messagesUpserted: 3,
    );
    provider.arrivals.add(const SyncArrival('Studio desktop', report));
    await tester.pump();
    // The toast slides in from above the screen; until that animation ends its
    // text is in the tree but not hit-testable, so the tap below needs it at
    // rest.
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.text(l10n.lanSyncArrivalToast('Studio desktop')),
      findsOneWidget,
      reason: 'the toast names the peer the data came from',
    );
    expect(find.text(l10n.lanSyncArrivalDetails), findsOneWidget);

    await tester.tap(find.text(l10n.lanSyncArrivalDetails));
    await tester.pumpAndSettle();

    // The dialog is the card's own breakdown: chips for the counters, the
    // peer's name as the title.
    expect(find.text('Studio desktop'), findsOneWidget);
    expect(find.text(l10n.lanSyncReportReceived(2)), findsOneWidget);
    expect(find.text(l10n.lanSyncReportMessagesUpserted(3)), findsOneWidget);

    // Let the toast's own auto-dismiss timer fire so no timer outlives the
    // test; the entry is long gone by then, so it is a no-op.
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });
}
