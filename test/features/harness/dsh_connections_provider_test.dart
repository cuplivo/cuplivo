import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/harness/models/dsh_remote.dart';
import 'package:Cuplivo/features/harness/models/dsh_web_ui_link.dart';
import 'package:Cuplivo/features/harness/services/dsh_credential_store.dart';
import 'package:Cuplivo/features/harness/services/dsh_remote_store.dart';
import 'package:Cuplivo/features/harness/state/dsh_connections_provider.dart';
import 'package:Cuplivo/features/harness/state/dsh_gateway.dart';

import '../../support/business_test_harness.dart';

class _MemoryCredentials implements DshCredentialStore {
  final Map<String, String> cookies = <String, String>{};

  @override
  Future<void> deleteCookie(String remoteId) async {
    cookies.remove(remoteId);
  }

  @override
  Future<String?> readCookie(String remoteId) async => cookies[remoteId];

  @override
  Future<void> writeCookie(String remoteId, String cookie) async {
    cookies[remoteId] = cookie;
  }
}

class _FakeGateway implements DshGateway {
  _FakeGateway({this.connectResult, this.connectError});

  final DshConnectResult? connectResult;
  final DshGatewayException? connectError;
  final StreamController<DshRemoteUpdate> _updates =
      StreamController<DshRemoteUpdate>.broadcast();
  final StreamController<DshLinkStatus> _status =
      StreamController<DshLinkStatus>.broadcast();

  bool disconnected = false;
  int retries = 0;
  String? lastLaunchToken;
  String? lastStoredCookie;

  void emit(DshRemoteUpdate update) => _updates.add(update);

  @override
  Future<DshConnectResult> connect({
    required DshRemote remote,
    String? launchToken,
    String? storedCookie,
  }) async {
    lastLaunchToken = launchToken;
    lastStoredCookie = storedCookie;
    final error = connectError;
    if (error != null) throw error;
    return connectResult ??
        const DshConnectResult(catalog: DshCatalogSnapshot(), cookie: 'c1');
  }

  @override
  Future<void> disconnect() async {
    disconnected = true;
  }

  @override
  Future<void> retry() async {
    retries++;
  }

  @override
  Stream<DshLinkStatus> get linkStatusStream => _status.stream;

  @override
  Stream<DshRemoteUpdate> get updates => _updates.stream;

  @override
  Future<DshCatalogSnapshot> refreshCatalog() async =>
      const DshCatalogSnapshot();

  @override
  Future<void> updateGeneralSettings(DshGeneralSettings settings) async {}

  @override
  Future<DshSessionSummary> createSession({
    String? workspaceId,
    String? cwd,
  }) async => const DshSessionSummary(id: 's', title: 's');

  @override
  Future<void> renameSession(String sessionId, String title) async {}

  @override
  Future<void> setSessionPinned(
    String sessionId, {
    required bool pinned,
  }) async {}

  @override
  Future<void> setSessionArchived(
    String sessionId, {
    required bool archived,
  }) async {}

  @override
  Future<DshSessionHandle> openSession(String sessionId) async =>
      throw UnimplementedError();

  @override
  Future<List<DshFileEntry>> listFiles(String sessionId, String path) async =>
      const <DshFileEntry>[];

  @override
  Future<String> readTextFile(String sessionId, String path) async => '';

  @override
  Future<DshFileStat> statFile(String sessionId, String path) async =>
      const DshFileStat(path: '', isDirectory: false);

  @override
  Future<List<int>> readFileBytes(String sessionId, String path) async =>
      const <int>[];
}

/// The state layer is the only writer of the record store and the cookie
/// store, and it is what the creation UI and the later slices call. These
/// tests pin the transitions it owns: success persists both, a failure keeps
/// the record with a reason, and live updates reach `catalogFor`.
void main() {
  Future<DshConnectionsProvider> providerWith({
    required DshRemoteStore store,
    required DshCredentialStore credentials,
    DshGatewayFactory? factory,
  }) async {
    final provider = DshConnectionsProvider(
      store: store,
      credentials: credentials,
      gatewayFactory: factory,
    );
    await provider.loaded;
    return provider;
  }

  DshWebUiLink link() =>
      DshWebUiLink.tryParse('http://192.168.1.20:3080/?token=launch-token')!;

  test(
    'a successful connect persists the record, the cookie and the catalog',
    () async {
      final harness = await createBusinessTestHarness();
      final store = DshRemoteStore(harness.preferences);
      final credentials = _MemoryCredentials();
      final gateway = _FakeGateway();
      final provider = await providerWith(
        store: store,
        credentials: credentials,
        factory: (_) => gateway,
      );

      final remote = await provider.createRemote(name: 'Studio', link: link());
      expect(provider.remotes, hasLength(1));
      expect(provider.linkStatus(remote.id).isIdle, isTrue);

      final status = await provider.connect(
        remote.id,
        launchToken: 'launch-token',
      );
      expect(status.isReady, isTrue);
      expect(gateway.lastLaunchToken, 'launch-token');
      expect(credentials.cookies[remote.id], 'c1');
      expect(provider.catalogFor(remote.id), isNotNull);
      expect(provider.remoteById(remote.id)!.lastConnectedAt, isNotNull);

      // The cookie is the reconnect credential, not a second launch token.
      await provider.disconnect(remote.id);
      expect(gateway.disconnected, isTrue);
      expect(provider.linkStatus(remote.id).isIdle, isTrue);

      provider.dispose();
    },
  );

  test(
    'a failed connect keeps the record, maps the reason and stores no cookie',
    () async {
      final harness = await createBusinessTestHarness();
      final store = DshRemoteStore(harness.preferences);
      final credentials = _MemoryCredentials();
      final provider = await providerWith(
        store: store,
        credentials: credentials,
        factory: (_) => _FakeGateway(
          connectError: const DshGatewayException(
            DshFailure.auth,
            detail: '401',
          ),
        ),
      );

      final remote = await provider.createRemote(name: 'Studio', link: link());
      final status = await provider.connect(
        remote.id,
        launchToken: 'launch-token',
      );
      expect(status.isFailed, isTrue);
      expect(status.failure, DshFailure.auth);
      expect(credentials.cookies, isEmpty);

      final saved = provider.remoteById(remote.id)!;
      expect(saved.lastError, 'auth');
      expect(saved.lastConnectedAt, isNull);
      // The record survives, so the page can show the error and let the user
      // paste a fresh link without losing the name they typed.
      expect(provider.remotes.map((item) => item.id), [remote.id]);

      provider.dispose();
    },
  );

  test(
    'no adapter wired reports notConfigured instead of pretending',
    () async {
      final harness = await createBusinessTestHarness();
      final provider = await providerWith(
        store: DshRemoteStore(harness.preferences),
        credentials: _MemoryCredentials(),
      );
      final remote = await provider.createRemote(name: 'Studio', link: link());
      expect(provider.isGatewayWired, isFalse);

      final status = await provider.connect(
        remote.id,
        launchToken: 'launch-token',
      );
      expect(status.isFailed, isTrue);
      expect(status.failure, DshFailure.notConfigured);
      expect(provider.remoteById(remote.id)!.lastError, 'notConfigured');

      provider.dispose();
    },
  );

  test(
    'live catalog patches and session controls reach the provider',
    () async {
      final harness = await createBusinessTestHarness();
      final gateway = _FakeGateway();
      final provider = await providerWith(
        store: DshRemoteStore(harness.preferences),
        credentials: _MemoryCredentials(),
        factory: (_) => gateway,
      );
      final remote = await provider.createRemote(name: 'Studio', link: link());
      await provider.connect(remote.id, launchToken: 'launch-token');

      gateway.emit(
        const DshCatalogPatchUpdate(
          DshWorkspaceUpsert(
            DshWorkspace(
              id: 'w1',
              title: 'Cuplivo',
              sessions: [
                DshSessionSummary(
                  id: 's1',
                  title: 'Fix the build',
                  workspaceId: 'w1',
                ),
              ],
            ),
          ),
        ),
      );
      gateway.emit(
        const DshSessionControlUpdate(
          DshSessionControl(sessionId: 's1', running: true, queued: 1),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final catalog = provider.catalogFor(remote.id);
      expect(catalog!.workspaces.single.id, 'w1');
      expect(catalog.workspaces.single.sessions.single.id, 's1');
      expect(provider.sessionControlFor(remote.id, 's1')!.running, isTrue);
      expect(provider.sessionControlFor(remote.id, 's1')!.queued, 1);

      // A session patch moves the row; a removal patch drops it.
      gateway.emit(const DshCatalogPatchUpdate(DshSessionRemoved('s1')));
      await Future<void>.delayed(Duration.zero);
      expect(provider.catalogFor(remote.id)!.allSessions, isEmpty);

      provider.dispose();
    },
  );

  test(
    'deleting a remote also deletes its cookie and its order membership',
    () async {
      final harness = await createBusinessTestHarness();
      final credentials = _MemoryCredentials();
      final provider = await providerWith(
        store: DshRemoteStore(harness.preferences),
        credentials: credentials,
        factory: (_) => _FakeGateway(),
      );
      final remote = await provider.createRemote(name: 'Studio', link: link());
      await provider.connect(remote.id, launchToken: 'launch-token');
      expect(credentials.cookies, contains(remote.id));

      await provider.deleteRemote(remote.id);
      expect(provider.remotes, isEmpty);
      expect(credentials.cookies, isEmpty);
      expect(provider.catalogFor(remote.id), isNull);
      expect(provider.harnessOwnerIds, isEmpty);

      provider.dispose();
    },
  );
}
