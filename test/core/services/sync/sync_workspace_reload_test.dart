import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_data.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/models/workspace.dart';
import 'package:Cuplivo/core/providers/workspace_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/sync/business_state_reloader.dart';
import 'package:Cuplivo/core/services/sync/sync_data_plane.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// `ChatService` reaches for the app documents directory on init; the sync data
/// plane needs one, and this suite is not about file locations.
class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => '$path/cache';

  @override
  Future<String?> getTemporaryPath() async => '$path/tmp';
}

/// The reload tail for workspace *records* (ADR-0003 decision 8).
///
/// A workspace row is the first entity kind whose app-side reader is a provider
/// holding a parsed list, so "the row is in SQLite" and "the user can see the
/// workspace" are two different facts. This file pins the wire between them: the
/// apply path announces the change, and the registered callback re-parses the
/// list. The deviceId fixture is irrelevant here — nothing competes for the row.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late PathProviderPlatform previousPathProvider;
  late AppDatabase database;
  late BusinessRepository businessRepository;
  late BusinessPreferences businessPreferences;
  late ChatService chatService;
  late ChatDatabaseRepository repository;
  late ExtensionEntityStore store;
  late WorkspaceProvider workspaces;
  late BusinessStateReloader reloader;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sync_workspace_reload_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
    database = AppDatabase(NativeDatabase.memory());
    businessRepository = BusinessRepository(database);
    businessPreferences = BusinessPreferences(businessRepository);
    await businessPreferences.load();
    repository = ChatDatabaseRepository(database);
    await repository.ensureReady();
    chatService = ChatService(existingRepository: repository);
    await chatService.init();
    store = ExtensionEntityStore(database);
    workspaces = WorkspaceProvider(store: store);
    await workspaces.loaded;
    reloader = BusinessStateReloader(businessPreferences);
    reloader.register(workspaces.reloadAfterExternalChange);
  });

  tearDown(() async {
    await chatService.close();
    await database.close();
    PathProviderPlatform.instance = previousPathProvider;
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// One managed workspace as the peer would send it: raw column map, its own
  /// clock, a payload in the shape `Workspace.toJson` writes.
  List<Map<String, dynamic>> workspaceRows(String id) => [
    {
      'kind': 'workspace',
      'id': id,
      'sort_order': 0,
      'owner_id': null,
      'payload': jsonEncode({
        'id': id,
        'name': 'Shared notes',
        'kind': 'managed',
        'hostPath': null,
        'shellNeedsApproval': false,
        'defaultCwd': '',
        'disabledTools': const <String>[],
        'createdAt': '2026-01-01T00:00:00.000Z',
        'updatedAt': '2026-01-01T00:00:00.000Z',
        'lastUsedAt': null,
      }),
      'updated_at': 5000,
    },
  ];

  SyncDataPlane plane({BusinessStateReloader? withReloader}) => SyncDataPlane(
    repository: repository,
    chatService: chatService,
    businessRepository: businessRepository,
    businessPreferences: businessPreferences,
    reloader: withReloader,
  );

  Future<SyncBusinessApplyOutcome> applyWorkspace(
    SyncDataPlane plane,
    String id,
  ) => plane.applyBusiness(
    SyncBusinessPayload(
      entities: {BusinessEntityKind.workspace.wireName: workspaceRows(id)},
      preferences: const [],
    ),
    myDeviceId: 'me',
    peerDeviceId: 'peer',
  );

  test(
    'an applied workspace stays invisible until the list is re-read',
    () async {
      // No reloader on the plane: the row lands and the cached list keeps saying
      // nothing, which is the state a missing registration leaves the app in.
      final outcome = await applyWorkspace(plane(), 'ws-1');
      expect(outcome.changed, isTrue);
      expect(
        await store.get('workspace', 'ws-1'),
        isNotNull,
        reason: 'the row itself is here — only the view is behind',
      );
      expect(workspaces.workspaces, isEmpty);

      // The registered callback is what closes the gap.
      await reloader.reloadAll();
      expect(workspaces.workspaces.map((w) => w.id), ['ws-1']);
      expect(workspaces.workspaces.single.kind, WorkspaceKind.managed);
      expect(workspaces.workspaces.single.name, 'Shared notes');
    },
  );

  test(
    'a plane with the reloader wired shows the workspace immediately',
    () async {
      final outcome = await applyWorkspace(
        plane(withReloader: reloader),
        'ws-2',
      );
      expect(outcome.changed, isTrue);
      expect(workspaces.workspaces.map((w) => w.id), [
        'ws-2',
      ], reason: 'the apply path owns the reload, not the caller');
    },
  );

  test('the workspace list is registered with the sync reloader', () {
    // The registration lives in `main.dart`, where a widget test cannot reach
    // it — and a provider that caches a parsed list is exactly the kind that
    // fails silently when it is forgotten: the data arrives, the app does not
    // show it. This is the source-level half of the two tests above.
    final source = File('lib/main.dart').readAsStringSync();
    const signature = 'void _wireSyncReloaders(BuildContext ctx) {';
    final start = source.indexOf(signature);
    expect(start, isNonNegative, reason: '_wireSyncReloaders is gone');
    final body = source.substring(
      start,
      source.indexOf('\nvoid ', start + signature.length),
    );
    expect(
      body,
      contains('ctx.read<WorkspaceProvider>().reloadAfterExternalChange()'),
      reason: 'a synced workspace row would never reach the workspace list',
    );
  });
}
