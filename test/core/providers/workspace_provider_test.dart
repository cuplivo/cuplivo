import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/providers/workspace_provider.dart';
import 'package:Cuplivo/utils/app_directories.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// A workspace row carries its identity twice: the table's `id` column says what
/// the row is, and the payload's own `id` is what `Workspace.fromJson` reads —
/// and therefore what this provider lists, renames (`update`) and deletes. The
/// payload is peer input (LAN sync) and backup input, and the id column was the
/// only half ever validated, so a payload naming `..` used to be listed as a
/// normal workspace and a delete with files removed `<appData>` itself.
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
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late ExtensionEntityStore store;
  late Directory appData;
  late PathProviderPlatform previous;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    store = ExtensionEntityStore(database);
    appData = await Directory.systemTemp.createTemp('cuplivo_ws_provider_');
    previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(appData.path);
  });

  tearDown(() async {
    PathProviderPlatform.instance = previous;
    await database.close();
    try {
      await appData.delete(recursive: true);
    } catch (_) {}
  });

  Map<String, dynamic> payloadNaming(String id) => {
    'id': id,
    'name': 'Notes',
    'kind': 'managed',
    'hostPath': null,
    'shellNeedsApproval': false,
    'defaultCwd': '',
    'disabledTools': const <String>[],
    'createdAt': '2026-01-01T00:00:00.000Z',
    'updatedAt': '2026-01-01T00:00:00.000Z',
    'lastUsedAt': null,
  };

  test(
    'a row whose payload names another id is not a workspace here',
    () async {
      await store.upsert('workspace', 'w-1', payloadNaming('..'));
      await store.upsert('workspace', 'w-2', payloadNaming('w-2'));

      final provider = WorkspaceProvider(store: store);
      await provider.loaded;

      expect(provider.workspaces.map((workspace) => workspace.id), ['w-2']);
      expect(provider.byId('..'), isNull);
    },
  );

  test('one unreadable row costs its own workspace, not the list', () async {
    // `Workspace.fromJson` throws on a payload with no `createdAt`, and this
    // list is what the whole workspace UI reads: one malformed row from a peer
    // must not empty it.
    await store.upsert('workspace', 'w-broken', {'id': 'w-broken'});
    await store.upsert('workspace', 'w-2', payloadNaming('w-2'));

    final provider = WorkspaceProvider(store: store);
    await provider.loaded;

    expect(provider.workspaces.map((workspace) => workspace.id), ['w-2']);
  });

  test('a delete with files cannot leave the managed tree', () async {
    await File('${appData.path}/conversations.sqlite').writeAsString('db');
    await store.upsert('workspace', 'w-1', payloadNaming('..'));

    final provider = WorkspaceProvider(store: store);
    await provider.loaded;
    // Nothing is listed under it, so the UI cannot even name the bomb; the
    // delete path refuses an id that is not a path segment on its own account
    // as well.
    await provider.delete('..', deleteFiles: true);

    expect(await appData.exists(), isTrue);
    expect(await File('${appData.path}/conversations.sqlite').exists(), isTrue);
  });

  test('a managed workspace still deletes its own folder', () async {
    // The control: the guard refuses an id, not the operation.
    await store.upsert('workspace', 'w-2', payloadNaming('w-2'));
    final files = await AppDirectories.workspaceFilesDir('w-2');
    await File('${files.path}/a.txt').writeAsString('a');

    final provider = WorkspaceProvider(store: store);
    await provider.loaded;
    await provider.delete('w-2');

    expect(provider.workspaces, isEmpty);
    expect(await File('${files.path}/a.txt').exists(), isFalse);
  });
}
