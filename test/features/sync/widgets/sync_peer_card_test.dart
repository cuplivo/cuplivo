import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/providers/sync_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/sync/business_state_reloader.dart';
import 'package:Cuplivo/core/services/sync/sync_engine.dart';
import 'package:Cuplivo/core/services/sync/sync_limits.dart';
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
      );
}

/// A peer whose last word came from a session that *failed*: the dot is grey,
/// the subtitle says it cannot be reached right now, and the tooltip used to
/// read "Online — the last sync connected" because the label was chosen from
/// the *source* (a session) instead of the state.
class _SessionSilentProvider extends SyncProvider {
  _SessionSilentProvider({
    required super.chatService,
    required super.repository,
    required super.businessRepository,
    required super.businessPreferences,
    required super.reloader,
    required super.syncDirectory,
  });

  @override
  bool isPeerOnline(String deviceId) => false;

  @override
  PresenceSource peerPresenceSource(String deviceId) => PresenceSource.session;
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
    // The widest beat the card can be handed: a full address beside a long
    // device name. It used to be widest with a candidate rank appended, which
    // the label no longer carries — the probe ranks the addresses, the dial
    // only names the one it is trying.
    final label = l10n.lanSyncPhaseConnectingTo('183.173.213.34:9527');

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

  testWidgets('a grey dot never says the last sync connected', (tester) async {
    late final Directory root;
    late final ChatService chatService;
    late final ChatDatabaseRepository repository;
    late final SyncProvider provider;
    late final AppLocalizations l10n;

    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('sync-peer-card-silent');
      PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
      final database = AppDatabase(NativeDatabase.memory());
      repository = ChatDatabaseRepository(database);
      final businessRepository = BusinessRepository(database);
      final businessPreferences = BusinessPreferences(businessRepository);
      chatService = ChatService(existingRepository: repository);
      await repository.ensureReady();
      await chatService.init();
      await businessPreferences.load();
      provider = _SessionSilentProvider(
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
    final semantics = tester.ensureSemantics();

    final peer = SyncPeerRecord(
      deviceId: 'peer-1',
      certPem: 'pem',
      secret: 'secret',
      name: 'Studio desktop',
      platform: 'android',
      endpoints: [SyncPeerEndpoint(host: '10.0.0.4', port: 9527)],
    );

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
      find.byTooltip(l10n.lanSyncOfflineFromSession),
      findsOneWidget,
      reason:
          'a session that found silence is "could not connect", not '
          '"connected"',
    );
    expect(find.byTooltip(l10n.lanSyncOnlineFromSession), findsNothing);
    expect(
      find.bySemanticsLabel(l10n.lanSyncOfflineFromSession),
      findsWidgets,
      reason: 'the semantics carry the same statement the tooltip makes',
    );

    // Disposed inside the body: the framework checks for a live handle before
    // teardowns run.
    semantics.dispose();
  });

  testWidgets('a peer with one address is still offered another', (
    tester,
  ) async {
    late final Directory root;
    late final ChatService chatService;
    late final ChatDatabaseRepository repository;
    late final SyncProvider provider;
    late final AppLocalizations l10n;

    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('sync-peer-card-add');
      PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
      final database = AppDatabase(NativeDatabase.memory());
      repository = ChatDatabaseRepository(database);
      final businessRepository = BusinessRepository(database);
      final businessPreferences = BusinessPreferences(businessRepository);
      chatService = ChatService(existingRepository: repository);
      await repository.ensureReady();
      await chatService.init();
      await businessPreferences.load();
      provider = _SessionSilentProvider(
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

    // One remembered address — what a first pairing leaves. The card used to show
    // its add-address affordance only while the set was *empty*, so this state
    // had no way to reach the second network the pair is about to be met on.
    final peer = SyncPeerRecord(
      deviceId: 'peer-1',
      certPem: 'pem',
      secret: 'secret',
      name: 'Studio desktop',
      platform: 'android',
      endpoints: [SyncPeerEndpoint(host: '10.0.0.4', port: 9527)],
    );

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
      find.byKey(const ValueKey('syncEndpointTile:10.0.0.4:9527')),
      findsOneWidget,
      reason: 'the remembered address is drawn as a tile',
    );
    expect(
      find.byKey(const ValueKey('syncPeerCardAddAddress')),
      findsOneWidget,
      reason: 'one address is not a full memory',
    );
    expect(find.text(l10n.lanSyncAddAddress), findsOneWidget);
  });

  testWidgets('a peer at the cap is not offered a thirteenth address', (
    tester,
  ) async {
    // The same affordance, one state further: with every slot taken there is
    // nothing the button could do — a new address would have to evict one this
    // pair has actually synced over — so the card does not offer it.
    late final Directory root;
    late final ChatService chatService;
    late final ChatDatabaseRepository repository;
    late final SyncProvider provider;

    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('sync-peer-card-full');
      PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
      final database = AppDatabase(NativeDatabase.memory());
      repository = ChatDatabaseRepository(database);
      final businessRepository = BusinessRepository(database);
      final businessPreferences = BusinessPreferences(businessRepository);
      chatService = ChatService(existingRepository: repository);
      await repository.ensureReady();
      await chatService.init();
      await businessPreferences.load();
      provider = _SessionSilentProvider(
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

    final peer = SyncPeerRecord(
      deviceId: 'peer-1',
      certPem: 'pem',
      secret: 'secret',
      name: 'Studio desktop',
      platform: 'android',
      endpoints: [
        for (var i = 0; i < kMaxPeerEndpoints; i++)
          SyncPeerEndpoint(host: '10.0.0.$i', port: 9527),
      ],
    );

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

    expect(peer.endpoints, hasLength(kMaxPeerEndpoints));
    expect(
      find.byKey(const ValueKey('syncPeerCardAddAddress')),
      findsNothing,
      reason: 'a full set has no room for a refusal to explain',
    );
  });
}
