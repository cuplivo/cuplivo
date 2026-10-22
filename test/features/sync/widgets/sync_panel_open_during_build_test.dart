// Opening the panel while the listener is down is the repair path (#1036): the
// panel asks the provider to start a listener that is not running. The panel
// asks from `didChangeDependencies` — the build phase — so a start that notified
// synchronously would mark the `ChangeNotifierProvider` *above* the panel as
// needing to build, which the framework refuses ("setState() or markNeedsBuild()
// called during build").
//
// `sync_panel_body_test.dart` cannot catch that: it overrides `panelOpened` to
// count calls, so the real method — and the real start it requests — never runs.
// This file mounts the real panel over a real, unstarted provider instead. The
// provider's `syncDirectory` never completes, so the start stops on its
// synchronous prefix: nothing binds a port, no identity is generated, and the
// assertion stays about the notification rather than about the engine.

import 'dart:async';
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

void main() {
  testWidgets('a panel opened while the listener is down starts it after the '
      'build phase', (tester) async {
    late Directory root;
    late ChatService chatService;
    late ChatDatabaseRepository repository;
    late SyncProvider provider;

    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('sync_panel_open');
      PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
      final database = AppDatabase(NativeDatabase.memory());
      repository = ChatDatabaseRepository(database);
      final businessRepository = BusinessRepository(database);
      final businessPreferences = BusinessPreferences(businessRepository);
      chatService = ChatService(existingRepository: repository);
      await repository.ensureReady();
      await chatService.init();
      await businessPreferences.load();
      provider = SyncProvider(
        chatService: chatService,
        repository: repository,
        businessRepository: businessRepository,
        businessPreferences: businessPreferences,
        reloader: BusinessStateReloader(businessPreferences),
        // Never completes: this test is about the synchronous part of the start
        // the panel requests, not about binding a port.
        syncDirectory: () => Completer<Directory>().future,
      );
    });

    addTearDown(() async {
      provider.dispose();
      await chatService.close();
      await repository.close();
      await root.delete(recursive: true);
    });

    expect(provider.started, isFalse, reason: 'the listener is down');
    expect(provider.starting, isFalse);

    await tester.pumpWidget(
      ChangeNotifierProvider<SyncProvider>.value(
        value: provider,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: SyncPanelBody()),
        ),
      ),
    );

    expect(
      tester.takeException(),
      isNull,
      reason: 'the panel must not notify the provider from during the build',
    );
    expect(
      provider.starting,
      isTrue,
      reason: 'the open deferred the start, it did not drop it',
    );
  });
}
