import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/providers/sync_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/sync/business_state_reloader.dart';
import 'package:Cuplivo/core/services/sync/sync_engine.dart';
import 'package:Cuplivo/core/services/sync/sync_store.dart';
import 'package:Cuplivo/features/sync/widgets/sync_peer_card.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';

/// `ChatService.init` asks the platform for the app documents directory, and the
/// test host has no plugin to answer with. The same fake the sync integration
/// tests register.
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

/// The card reads the live beat off the provider, and a beat is all this test
/// needs: no listener, no session, no socket.
class _BusyProvider extends SyncProvider {
  _BusyProvider({
    required super.chatService,
    required super.repository,
    required super.businessRepository,
    required super.businessPreferences,
    required super.reloader,
    required super.syncDirectory,
  });

  @override
  SyncSessionProgress? progressFor(String deviceId) =>
      const SyncSessionProgress(
        SyncSessionPhase.connecting,
        address: '183.173.213.34:9527',
        attempt: 2,
        attempts: 3,
      );
}

void main() {
  testWidgets('the dial beat leaves the peer name its line on a narrow card', (
    tester,
  ) async {
    late final Directory root;
    late final ChatService chatService;
    late final ChatDatabaseRepository repository;
    late final SyncProvider provider;
    late final AppLocalizations l10n;

    // Everything that touches the real world happens here: `testWidgets` runs
    // its body in a fake-async zone, where an I/O future never completes.
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('sync-peer-card');
      PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
      final database = AppDatabase(NativeDatabase.memory());
      repository = ChatDatabaseRepository(database);
      final businessRepository = BusinessRepository(database);
      final businessPreferences = BusinessPreferences(businessRepository);
      chatService = ChatService(existingRepository: repository);
      await repository.ensureReady();
      await chatService.init();
      await businessPreferences.load();
      provider = _BusyProvider(
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
      provider.dispose();
      await chatService.close();
      await repository.close();
      await root.delete(recursive: true);
    });
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    provider.busyDeviceIds.add('peer-1');
    provider.onlineDeviceIds.add('peer-1');

    final peer = SyncPeerRecord(
      deviceId: 'peer-1',
      certPem: 'pem',
      secret: 'secret',
      name: 'Studio desktop',
      platform: 'android',
      endpoints: [SyncPeerEndpoint(host: '183.173.213.34', port: 9527)],
    );
    // The widest beat the card can be handed: an address *and* a candidate rank,
    // which `syncPhaseLabel` picks whenever the peer remembers more than one
    // address and the first one did not answer.
    final label = l10n.lanSyncPhaseConnectingAt('183.173.213.34:9527', 2, 3);

    // 328dp is a small phone's card (a 360dp screen minus the page's 16dp a
    // side), 412dp is a large one. The surface width is the only knob that
    // constrains a route's child, so it is set on the test view — and every
    // width builds a fresh tree, because an overflow is reported from paint and
    // a reused element tree is exactly what would suppress the report.
    for (final widthDp in const [328.0, 360.0, 412.0]) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(const SizedBox.shrink());
      tester.view.physicalSize = Size(widthDp * 3, 2400);
      tester.view.devicePixelRatio = 3.0;
      await tester.pumpWidget(
        ChangeNotifierProvider<SyncProvider>.value(
          value: provider,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: SyncPeerCard(peer: peer)),
          ),
        ),
      );
      await tester.pump();

      expect(
        tester.takeException(),
        isNull,
        reason: 'the card overflowed at $widthDp dp',
      );
      expect(
        find.text(label),
        findsOneWidget,
        reason: 'the beat is still named at $widthDp dp',
      );
      expect(
        tester.getSize(find.text('Studio desktop')).width,
        greaterThan(0),
        reason:
            'at $widthDp dp the beat took the whole line and squeezed the peer '
            'name to nothing; the name is the only identifier the row has',
      );
    }
  });
}
