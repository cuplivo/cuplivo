// The LAN sync listener belongs to the running process, not to a window
// (#1036).
//
// `stop()` used to be registered in the exit-flush registry, and `onExitRequested`
// runs that registry for a close that only hides to the tray — so hiding the
// window closed port 9527, with the process still alive. And because `stop()`
// left `_stopRequested` set, no later `start()` could ever bind again: the panel
// kept saying "listener not running" until the app was restarted.
//
// These are the two invariants that regression broke: an exit *flush* leaves the
// listener up, and a listener that is down can be started again by the moments
// the app is usable again (a resume, the panel opening).

import 'dart:async';
import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/providers/sync_provider.dart';
import 'package:Cuplivo/core/services/app_exit_flush.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/sync/business_state_reloader.dart';
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => '$path/cache';

  @override
  Future<String?> getTemporaryPath() async => '$path/tmp';
}

/// One provider over a throwaway database and sync directory.
class _Harness {
  _Harness(this.dir);

  final Directory dir;
  late final AppDatabase database;
  late final ChatDatabaseRepository repository;
  late final ChatService chatService;
  late final BusinessRepository businessRepository;
  late final BusinessPreferences businessPreferences;
  SyncProvider? provider;

  /// Builds the provider over a throwaway database and an empty sync directory.
  ///
  /// [syncDirectory] and [start] exist for the concurrency test, which has to
  /// hold the directory future open and call `start()` itself.
  Future<SyncProvider> startProvider({
    Future<Directory> Function()? syncDirectory,
    bool start = true,
  }) async {
    database = AppDatabase(NativeDatabase.memory());
    repository = ChatDatabaseRepository(database);
    await repository.ensureReady();
    businessRepository = BusinessRepository(database);
    businessPreferences = BusinessPreferences(businessRepository);
    await businessPreferences.load();
    chatService = ChatService(existingRepository: repository);
    await chatService.init();
    final started = SyncProvider(
      chatService: chatService,
      repository: repository,
      businessRepository: businessRepository,
      businessPreferences: businessPreferences,
      reloader: BusinessStateReloader(businessPreferences),
      syncDirectory: syncDirectory ?? () async => dir,
      // No NIC: the address list is not what these tests are about.
      addressSource: () async => const [],
      endpointProbe: (host, port) async {},
    );
    provider = started;
    if (start) await started.start();
    return started;
  }

  Future<void> dispose() async {
    final started = provider;
    if (started != null) {
      await started.stop();
      started.dispose();
    }
    await chatService.close();
    await repository.close();
  }
}

Future<void> _waitUntil(Future<bool> Function() condition) async {
  // Shorter than the default per-test timeout on purpose: a condition that
  // never becomes true has to fail with this message, not with a bare timeout.
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('condition never became true');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Whether anything is listening on [port] at all. A sync request would need the
/// pinned certificate; "the socket accepts a connection" is exactly the
/// statement these tests make — the port stopped listening in #1036.
Future<bool> _portAcceptsConnections(int port) async {
  Socket? socket;
  try {
    socket = await Socket.connect(
      '127.0.0.1',
      port,
      timeout: const Duration(seconds: 2),
    );
    return true;
  } catch (_) {
    return false;
  } finally {
    socket?.destroy();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory root;
  late PathProviderPlatform previousPathProvider;
  late _Harness harness;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cuplivo_listener_life_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
    harness = _Harness(root);
  });

  tearDown(() async {
    await harness.dispose();
    PathProviderPlatform.instance = previousPathProvider;
    AppExitFlush.debugReset();
    AppShutdown.debugReset();
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  test('an exit flush leaves the listener running', () async {
    final provider = await harness.startProvider();
    final port = provider.port;
    expect(provider.started, isTrue);
    expect(port, isNotNull);
    expect(
      await _portAcceptsConnections(port!),
      isTrue,
      reason: 'the listener is up before the flush',
    );

    // Exactly what `AppLifecycleListener.onExitRequested` runs for a close that
    // only hides the window.
    await AppExitFlush.flushAll();

    expect(
      provider.started,
      isTrue,
      reason: 'a flush drains writes; it must not tear the listener down',
    );
    expect(provider.port, port);
    expect(await _portAcceptsConnections(port), isTrue);
  });

  test('the listener can be started again after a stop', () async {
    final provider = await harness.startProvider();
    expect(provider.started, isTrue);

    await provider.stop();
    expect(provider.started, isFalse);
    expect(provider.port, isNull);

    await provider.start();

    expect(
      provider.started,
      isTrue,
      reason: 'a real stop must not make the provider unstartable forever',
    );
    expect(provider.port, isNotNull);
    expect(await _portAcceptsConnections(provider.port!), isTrue);
  });

  test('a resume restarts a listener that is down', () async {
    final provider = await harness.startProvider();
    await provider.stop();
    expect(provider.started, isFalse);

    // The tray restore path: the window is shown again and the engine reports
    // `resumed`.
    provider.didChangeAppLifecycleState(AppLifecycleState.resumed);

    await _waitUntil(() async => provider.started);
    expect(provider.port, isNotNull);
    expect(await _portAcceptsConnections(provider.port!), isTrue);
  });

  test('a resume leaves a running listener alone', () async {
    final provider = await harness.startProvider();
    final port = provider.port;

    provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(provider.port, port, reason: 'no rebind on every focus gain');
  });

  // `start()` is called from more than one moment (the launch callback, a
  // resume, the panel opening), so two of them can land together. This covers
  // the `_startFuture` join: the second call arrives after the first start's
  // future exists, so it waits on that future instead of beginning its own.
  test(
    'a second start while one is in flight does not begin another',
    () async {
      var directoryReads = 0;
      final gate = Completer<Directory>();
      final provider = await harness.startProvider(
        syncDirectory: () {
          directoryReads++;
          return gate.future;
        },
        start: false,
      );

      final first = provider.start();
      // `_start`'s synchronous prefix is what sets these, so the first start is
      // in flight without any pumping.
      expect(directoryReads, 1);
      expect(provider.starting, isTrue);

      final second = provider.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        directoryReads,
        1,
        reason: 'the second start must join the first, not begin its own',
      );
      expect(provider.starting, isTrue);

      gate.complete(harness.dir);
      await Future.wait([first, second]);

      expect(provider.started, isTrue);
      expect(provider.port, isNotNull);
      expect(directoryReads, 1);
    },
  );

  // The other guard, and the one the test above cannot reach: `_start` notifies
  // its listeners *before* its first `await`, which is before `_startFuture`
  // exists. A listener that asks for a start from inside that notification is
  // stopped by `starting` alone; delete that term and this records two starts.
  test(
    'a start requested from a listener mid-start does not start twice',
    () async {
      var directoryReads = 0;
      final gate = Completer<Directory>();
      final provider = await harness.startProvider(
        syncDirectory: () {
          directoryReads++;
          return gate.future;
        },
        start: false,
      );

      var reentered = false;
      provider.addListener(() {
        if (reentered || !provider.starting) return;
        reentered = true;
        unawaited(provider.start());
      });

      final first = provider.start();

      expect(
        reentered,
        isTrue,
        reason: 'the listener has to run inside the start to test the guard',
      );
      expect(directoryReads, 1);

      gate.complete(harness.dir);
      await first;

      expect(provider.started, isTrue);
      expect(
        directoryReads,
        1,
        reason: 'the re-entrant request must not begin a second start',
      );
    },
  );

  test('opening the panel restarts a listener that is down', () async {
    final provider = await harness.startProvider();
    await provider.stop();

    provider.panelOpened();

    await _waitUntil(() async => provider.started);
    provider.panelClosed();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
