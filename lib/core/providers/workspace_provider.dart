import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../utils/app_directories.dart';
import '../database/business_data.dart';
import '../database/extension_entity_store.dart';
import '../models/workspace.dart';
import '../services/workspace/workspace_binding_actions.dart';
import 'assistant_provider.dart';

class WorkspaceProvider extends ChangeNotifier {
  WorkspaceProvider({required this.store, this.assistants}) {
    loaded = _load();
  }

  final ExtensionEntityStore store;
  final AssistantProvider? assistants;
  final List<Workspace> _workspaces = <Workspace>[];

  late final Future<void> loaded;

  List<Workspace> get workspaces => List.unmodifiable(_workspaces);

  Workspace? byId(String id) {
    for (final workspace in _workspaces) {
      if (workspace.id == id) return workspace;
    }
    return null;
  }

  Future<void> _load() async {
    try {
      final entities = await store.listByKind(
        ExtensionEntityStore.kindWorkspace,
      );
      final workspaces = <Workspace>[];
      for (final entity in entities) {
        // The payload's own `id` is what this list, a rename and a delete act
        // on, so a row whose two halves disagree is not a workspace this device
        // holds: listing it would put an id in the UI that names no row here —
        // and, on a delete, a path outside this app's tree
        // ([workspacePayloadNamesId]).
        if (!workspacePayloadNamesId(entity.payload, entity.id)) continue;
        // One unreadable row costs its own workspace, never the list. The
        // payload is peer input, and the row stays in SQLite: clearing every
        // workspace over one malformed one is a worse answer than leaving it
        // out, which the peer's next push of that row repairs.
        final workspace = _workspaceOrNull(entity.payload);
        if (workspace != null) workspaces.add(workspace);
      }
      _workspaces
        ..clear()
        ..addAll(workspaces);
    } catch (e) {
      debugPrint('Failed to load workspaces: $e');
      _workspaces.clear();
    }
    notifyListeners();
  }

  static Workspace? _workspaceOrNull(Map<String, dynamic> payload) {
    try {
      return Workspace.fromJson(payload);
    } catch (error) {
      debugPrint('workspaces: skipping an unreadable row: $error');
      return null;
    }
  }

  /// Re-reads the workspace list after LAN sync wrote rows outside this provider
  /// (ADR-0003 decision 8: apply → one state reload).
  ///
  /// The list is cached and parsed, so an applied workspace row is otherwise
  /// invisible — this device would hold the peer's workspace in SQLite and never
  /// show it — until the next launch. Wired in `_wireSyncReloaders`.
  Future<void> reloadAfterExternalChange() => _load();

  Future<Workspace> create({
    required String name,
    WorkspaceKind kind = WorkspaceKind.managed,
    String? hostPath,
  }) async {
    await loaded;
    final now = DateTime.now().toUtc();
    final workspace = Workspace(
      id: const Uuid().v4(),
      name: name,
      kind: kind,
      hostPath: kind == WorkspaceKind.linked ? hostPath : null,
      createdAt: now,
      updatedAt: now,
    );
    if (kind == WorkspaceKind.managed) {
      await AppDirectories.workspaceFilesDir(workspace.id);
    }
    await store.upsert(
      ExtensionEntityStore.kindWorkspace,
      workspace.id,
      workspace.toJson(),
      sortOrder: _workspaces.length,
    );
    _workspaces.add(workspace);
    notifyListeners();
    return workspace;
  }

  Future<void> update(Workspace workspace) async {
    await loaded;
    final next = workspace.copyWith(updatedAt: DateTime.now().toUtc());
    final index = _workspaces.indexWhere((item) => item.id == next.id);
    await store.upsert(
      ExtensionEntityStore.kindWorkspace,
      next.id,
      next.toJson(),
      sortOrder: index >= 0 ? index : null,
    );
    if (index >= 0) {
      _workspaces[index] = next;
    } else {
      _workspaces.add(next);
    }
    notifyListeners();
  }

  Future<void> delete(String id, {bool deleteFiles = true}) async {
    await loaded;
    final existing = byId(id);
    await store.delete(ExtensionEntityStore.kindWorkspace, id);
    _workspaces.removeWhere((workspace) => workspace.id == id);
    if (deleteFiles &&
        existing != null &&
        existing.kind == WorkspaceKind.managed) {
      // The last place before the id becomes a path. `byId` above can only
      // return an id this device listed, and the list is filtered — but this
      // sink is what a future caller reaches, so it refuses on its own: `..`
      // resolves to `<appData>/workspaces/..`, and `recursive: true` there
      // removes the app data root this app keeps everything in.
      if (!isSafeWorkspaceId(id)) {
        debugPrint('workspaces: refusing to delete files for unsafe id "$id"');
      } else {
        final root = await AppDirectories.getWorkspacesDirectory();
        final dir = Directory('${root.path}/$id');
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }
    }
    final assistants = this.assistants;
    if (assistants != null) {
      await clearAssistantDefaultsForDeletedWorkspace(
        assistants,
        workspaceId: id,
      );
    }
    notifyListeners();
  }

  Future<void> touchLastUsed(String id) async {
    await loaded;
    final existing = byId(id);
    if (existing == null) return;
    await update(existing.copyWith(lastUsedAt: DateTime.now().toUtc()));
  }

  Future<String> hostRootFor(Workspace workspace) async {
    if (workspace.kind == WorkspaceKind.linked) {
      final path = workspace.hostPath;
      if (path == null || path.isEmpty) {
        throw StateError('linked workspace missing hostPath');
      }
      return path;
    }
    final dir = await AppDirectories.workspaceFilesDir(workspace.id);
    return dir.path;
  }
}
