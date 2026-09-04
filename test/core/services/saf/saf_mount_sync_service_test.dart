import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/models/workspace.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/providers/workspace_provider.dart';
import 'package:Cuplivo/core/services/mcp/kelivo_filesystem/kelivo_filesystem_server.dart';
import 'package:Cuplivo/core/services/saf/saf_mount_sync_service.dart';
import 'package:Cuplivo/core/services/workspace/workspace_tools_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

/// In-memory SAF tree keyed by content URIs (`content://tree/...`).
class _FakeSafNode {
  _FakeSafNode({
    required this.name,
    required this.isDirectory,
    required this.uri,
  });

  final String name;
  final bool isDirectory;
  final String uri;
  Uint8List bytes = Uint8List(0);
  int mtimeMs = 1_000_000_000;

  final List<_FakeSafNode> children = <_FakeSafNode>[];
}

class _FakeSafChannel extends SafChannel {
  static const String rootUri = 'content://tree';

  final _FakeSafNode root = _FakeSafNode(
    name: 'tree',
    isDirectory: true,
    uri: rootUri,
  );
  bool granted = true;
  int checkAccessCalls = 0;
  int pickTreeCalls = 0;
  int _nextId = 0;

  /// Provider-side "now" for streamed write stamps. Year 2033 so mtimes
  /// are always NEWER than any real wall-clock mirror mtime (~1.7e12 ms) —
  /// LWW comparisons in the tests stay deterministic.
  int nowMs = 2_000_000_000_000;

  /// URIs whose listing fails with an access error (transient provider
  /// hiccup simulation).
  final Set<String> failingListUris = <String>{};

  /// When true, delete() persistently returns false (provider refuses the
  /// deletion without raising).
  bool failDeletes = false;

  void seedFile(String relPath, String content, {int? mtimeMs}) {
    final parts = relPath.split('/');
    final parent = _ensureDirChain(parts.sublist(0, parts.length - 1));
    final uri = 'content://tree/${_nextId++}';
    final node = _FakeSafNode(name: parts.last, isDirectory: false, uri: uri)
      ..bytes = Uint8List.fromList(utf8.encode(content))
      ..mtimeMs = mtimeMs ?? nowMs;
    parent.children.add(node);
  }

  void seedDir(String relPath) {
    _ensureDirChain(relPath.split('/'));
  }

  _FakeSafNode _ensureDirChain(List<String> parts) {
    var parent = root;
    for (final part in parts) {
      parent = parent.children.firstWhere(
        (c) => c.name == part && c.isDirectory,
        orElse: () {
          final node = _FakeSafNode(
            name: part,
            isDirectory: true,
            uri: 'content://tree/${_nextId++}',
          );
          parent.children.add(node);
          return node;
        },
      );
    }
    return parent;
  }

  void touchFile(String relPath, {int? mtimeMs, String? content}) {
    final node = findByRel(relPath);
    if (content != null) {
      node.bytes = Uint8List.fromList(utf8.encode(content));
    }
    node.mtimeMs = mtimeMs ?? nowMs;
  }

  void deleteRel(String relPath) {
    final parts = relPath.split('/');
    final parent = parts.length == 1
        ? root
        : _ensureDirChain(parts.sublist(0, parts.length - 1));
    parent.children.removeWhere((c) => c.name == parts.last);
  }

  _FakeSafNode findByRel(String relPath) {
    _FakeSafNode current = root;
    for (final part in relPath.split('/')) {
      final next = current.children.where((c) => c.name == part).firstOrNull;
      if (next == null) {
        throw StateError('not found: $relPath');
      }
      current = next;
    }
    return current;
  }

  @override
  Future<Map<String, dynamic>?> pickTree() async {
    pickTreeCalls++;
    return null;
  }

  @override
  Future<List<Map<String, dynamic>>> list(String uri) async {
    if (!granted) throw PlatformException(code: 'access_denied');
    if (failingListUris.contains(uri)) {
      throw PlatformException(code: 'access_denied');
    }
    final parent = uri == rootUri ? root : _nodeByUri(uri);
    return parent.children
        .map(
          (n) => {
            'name': n.name,
            'isDirectory': n.isDirectory,
            'lastModified': n.mtimeMs,
            'size': n.bytes.length,
            'uri': n.uri,
          },
        )
        .toList();
  }

  _FakeSafNode _nodeByUri(String uri) {
    _FakeSafNode? found;
    void walk(_FakeSafNode node) {
      if (found != null) return;
      if (node.uri == uri) {
        found = node;
        return;
      }
      for (final c in node.children) {
        walk(c);
      }
    }

    walk(root);
    if (found == null) throw StateError('unknown uri: $uri');
    return found!;
  }

  @override
  Future<void> copyToPath(String uri, String targetPath) async {
    if (!granted) throw PlatformException(code: 'access_denied');
    final node = _nodeByUri(uri);
    await File(targetPath).writeAsBytes(node.bytes, flush: true);
  }

  @override
  Future<void> copyFromPath(String uri, String sourcePath) async {
    if (!granted) throw PlatformException(code: 'access_denied');
    final node = _nodeByUri(uri);
    node.bytes = await File(sourcePath).readAsBytes();
    node.mtimeMs = nowMs;
  }

  @override
  Future<String> createFile(String parentUri, String name) async {
    if (!granted) throw PlatformException(code: 'access_denied');
    final parent = _nodeByUri(parentUri);
    final node = _FakeSafNode(
      name: name,
      isDirectory: false,
      uri: 'content://tree/${_nextId++}',
    );
    parent.children.add(node);
    return node.uri;
  }

  @override
  Future<String> mkdir(String parentUri, String name) async {
    if (!granted) throw PlatformException(code: 'access_denied');
    final parent = _nodeByUri(parentUri);
    final node = _FakeSafNode(
      name: name,
      isDirectory: true,
      uri: 'content://tree/${_nextId++}',
    );
    parent.children.add(node);
    return node.uri;
  }

  @override
  Future<bool> delete(String uri) async {
    if (!granted) throw PlatformException(code: 'access_denied');
    if (failDeletes) return false;
    final target = _nodeByUri(uri);
    _FakeSafNode? parent;
    void walk(_FakeSafNode node) {
      if (parent != null) return;
      if (node.children.contains(target)) {
        parent = node;
        return;
      }
      for (final c in node.children) {
        walk(c);
      }
    }

    walk(root);
    parent?.children.remove(target);
    return true;
  }

  @override
  Future<bool> checkAccess(String uri) async {
    checkAccessCalls++;
    return granted;
  }
}

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.root);
  final Directory root;

  @override
  Future<String> getApplicationDocumentsPath() async => root.path;

  @override
  Future<String> getApplicationSupportPath() async => root.path;

  @override
  Future<String> getApplicationCachePath() async => p.join(root.path, 'cache');
}

/// Keeps the synchronization regression cases concise while routing every
/// operation through the default workspace's scoped production API.
class _TestSafMountService {
  _TestSafMountService(this.raw);

  final SafMountSyncService raw;

  Future<void> init() => raw.init();

  List<WorkspaceSafMount> get entries => raw.entriesFor(Workspace.defaultId);

  List<FilesystemMount> get mounts => raw.mountsFor(Workspace.defaultId);

  List<Map<String, Object?>> get guestBinds =>
      raw.guestBindsFor(Workspace.defaultId);

  WorkspaceSafMount? entryByAlias(String alias) =>
      raw.entryByAlias(Workspace.defaultId, alias);

  Future<String?> addMount({
    required String alias,
    required String uri,
    required String displayName,
  }) => raw.addMount(
    workspaceId: Workspace.defaultId,
    alias: alias,
    uri: uri,
    displayName: displayName,
  );

  Future<void> removeMount(String alias) async {
    final entry = entryByAlias(alias);
    if (entry != null) {
      await raw.removeMount(Workspace.defaultId, entry.id);
    }
  }

  Future<void> syncNow(String alias) async {
    final entry = entryByAlias(alias);
    if (entry != null) await raw.syncNow(entry.id);
  }

  SafMountState stateOf(String alias) {
    final entry = entryByAlias(alias);
    return entry == null ? const SafMountState() : raw.stateOf(entry.id);
  }

  void notifyMutated(String alias) =>
      raw.notifyMutated(Workspace.defaultId, alias);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _FakeSafChannel channel;
  late WorkspaceProvider workspaces;
  late _TestSafMountService service;

  Future<void> pump() async {
    // Let debounce timers / async continuations settle.
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  String mirrorPath(String alias) {
    final entry = service.entryByAlias(alias);
    if (entry == null) return p.join(tempDir.path, 'saf_mounts', alias);
    return service.raw.mirrorPathFor(entry.id);
  }

  File mirrorFile(String alias, String rel) =>
      File(p.join(mirrorPath(alias), rel));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    businessPrefs = BusinessPreferences.memoryForTests();
    businessPrefs = BusinessPreferences.memoryForTests({});
    tempDir = await Directory.systemTemp.createTemp('saf_mount_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir);
    SafMountSyncService.androidProbe = () => true;
    channel = _FakeSafChannel();
    workspaces = WorkspaceProvider(preferences: businessPrefs);
    await workspaces.init();
    service = _TestSafMountService(
      SafMountSyncService(
        preferences: businessPrefs,
        workspaces: workspaces,
        channel: channel,
      ),
    );
    await service.init();
    await pump();
  });

  tearDown(() async {
    await service.removeMount('notes');
    service.raw.dispose();
    workspaces.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('initial pull', () {
    test('mirrors the SAF tree and aligns mtimes', () async {
      channel.seedDir('docs');
      channel.seedFile('docs/a.txt', 'hello', mtimeMs: 1_000_000_000);
      channel.seedFile('top.bin', 'x' * 100, mtimeMs: 1_000_500_000);

      final err = await service.addMount(
        alias: 'notes',
        uri: 'content://tree',
        displayName: 'My Notes',
      );
      expect(err, isNull);
      await pump();

      expect(await mirrorFile('notes', 'docs/a.txt').readAsString(), 'hello');
      expect(await mirrorFile('notes', 'top.bin').length(), 100);
      expect(service.stateOf('notes').status, SafMountStatus.idle);
      // mtime aligned so the next round sees "same" and does not re-copy.
      final aligned = (await mirrorFile('notes', 'docs/a.txt').stat()).modified;
      expect(aligned.millisecondsSinceEpoch, closeTo(1_000_000_000, 1));
    });

    test('rejects an invalid alias', () async {
      final err = await service.addMount(
        alias: 'Notes!',
        uri: 'content://tree',
        displayName: 'x',
      );
      expect(err, SafMountSyncService.errorAliasInvalid);
    });

    test('terminal stop failure cancels adding a SAF binding', () async {
      final guarded = SafMountSyncService(
        preferences: businessPrefs,
        workspaces: workspaces,
        channel: channel,
        stopWorkspaceTerminal: (_) async => throw StateError('stop failed'),
      );
      addTearDown(guarded.dispose);
      await guarded.init();

      final error = await guarded.addMount(
        workspaceId: Workspace.defaultId,
        alias: 'blocked',
        uri: 'content://blocked',
        displayName: 'Blocked',
      );

      expect(error, SafMountSyncService.errorTerminalStopFailed);
      expect(guarded.entriesFor(Workspace.defaultId), isEmpty);
    });

    test('terminal stop failure cancels removing a SAF binding', () async {
      expect(
        await service.addMount(
          alias: 'notes',
          uri: 'content://tree',
          displayName: 'Notes',
        ),
        isNull,
      );
      final entry = service.entryByAlias('notes')!;
      final guarded = SafMountSyncService(
        preferences: businessPrefs,
        workspaces: workspaces,
        channel: channel,
        stopWorkspaceTerminal: (_) async => throw StateError('stop failed'),
      );
      addTearDown(guarded.dispose);
      await guarded.init();

      await expectLater(
        guarded.removeMount(Workspace.defaultId, entry.id),
        throwsStateError,
      );

      expect(workspaces.getById(Workspace.defaultId)!.safMounts, hasLength(1));
    });

    test('rejects a reserved alias colliding with a workspace', () async {
      final err = await service.addMount(
        alias: 'default',
        uri: 'content://tree',
        displayName: 'x',
      );
      expect(err, SafMountSyncService.errorAliasReserved);
    });

    test('allows another workspace-shaped alias inside default', () async {
      final err = await service.addMount(
        alias: 'workspace_4',
        uri: 'content://tree',
        displayName: 'x',
      );
      expect(err, isNull);
      expect(service.entryByAlias('workspace_4'), isNotNull);
    });

    test('rejects a duplicate alias', () async {
      await service.addMount(
        alias: 'notes',
        uri: 'content://tree',
        displayName: 'x',
      );
      final err = await service.addMount(
        alias: 'notes',
        uri: 'content://tree',
        displayName: 'x',
      );
      expect(err, SafMountSyncService.errorAliasDuplicate);
    });
  });

  group('two-way changes', () {
    test('SAF-side new file is pulled', () async {
      await service.addMount(
        alias: 'notes',
        uri: 'content://tree',
        displayName: 'x',
      );
      await pump();

      channel.seedFile('new.txt', 'from outside', mtimeMs: 1_500_000_000);
      await service.syncNow('notes');
      await pump();

      expect(
        await mirrorFile('notes', 'new.txt').readAsString(),
        'from outside',
      );
    });

    test('mirror-side new file is pushed to SAF', () async {
      await service.addMount(
        alias: 'notes',
        uri: 'content://tree',
        displayName: 'x',
      );
      await pump();

      await mirrorFile('notes', 'ai.md').writeAsString('by AI');
      await service.syncNow('notes');
      await pump();

      final node = channel.findByRel('ai.md');
      expect(utf8.decode(node.bytes), 'by AI');
    });

    test('SAF-side newer content overwrites the mirror', () async {
      channel.seedFile('a.txt', 'v1', mtimeMs: 1_000_000_000);
      await service.addMount(
        alias: 'notes',
        uri: 'content://tree',
        displayName: 'x',
      );
      await pump();
      expect(await mirrorFile('notes', 'a.txt').readAsString(), 'v1');

      channel.touchFile('a.txt', mtimeMs: 2_000_000_000, content: 'v2');
      await service.syncNow('notes');
      await pump();

      expect(await mirrorFile('notes', 'a.txt').readAsString(), 'v2');
    });

    test('mirror-side newer content is pushed to SAF', () async {
      channel.seedFile('a.txt', 'v1', mtimeMs: 1_000_000_000);
      await service.addMount(
        alias: 'notes',
        uri: 'content://tree',
        displayName: 'x',
      );
      await pump();

      final f = mirrorFile('notes', 'a.txt');
      final now = DateTime.now();
      await f.writeAsString('v2');
      await f.setLastModified(now.add(const Duration(seconds: 10)));
      await service.syncNow('notes');
      await pump();

      expect(utf8.decode(channel.findByRel('a.txt').bytes), 'v2');
      // The mirror mtime was aligned to the SAF post-write mtime so the next
      // round is a no-op (no ping-pong pull-back).
      await service.syncNow('notes');
      await pump();
      expect(utf8.decode(channel.findByRel('a.txt').bytes), 'v2');
      expect(await mirrorFile('notes', 'a.txt').readAsString(), 'v2');
    });

    test('conflict: newer mtime wins; mtime tie favors the mirror', () async {
      channel.seedFile('a.txt', 'v1', mtimeMs: 1_000_000_000);
      await service.addMount(
        alias: 'notes',
        uri: 'content://tree',
        displayName: 'x',
      );
      await pump();

      // Both sides change; SAF is newer → SAF wins.
      channel.touchFile('a.txt', mtimeMs: 3_000_000_000, content: 'saf-new');
      final f = mirrorFile('notes', 'a.txt');
      await f.writeAsString('mirror-new');
      await f.setLastModified(
        DateTime.fromMillisecondsSinceEpoch(2_000_000_000),
      );
      await service.syncNow('notes');
      await pump();
      expect(await mirrorFile('notes', 'a.txt').readAsString(), 'saf-new');

      // Both sides change with equal mtimes → mirror wins.
      channel.touchFile('a.txt', mtimeMs: 4_000_000_000, content: 'saf-tie');
      await f.writeAsString('mirror-tie');
      await f.setLastModified(
        DateTime.fromMillisecondsSinceEpoch(4_000_000_000),
      );
      await service.syncNow('notes');
      await pump();
      expect(utf8.decode(channel.findByRel('a.txt').bytes), 'mirror-tie');
    });
  });

  group('deletion propagation', () {
    test('SAF-side deletion removes the mirror file', () async {
      // A second file stays behind: deleting the LAST file would make the
      // whole tree empty and trip the whole-tree-gone guard (unmount
      // protection), which deliberately aborts instead.
      channel.seedFile('gone.txt', 'data', mtimeMs: 1_000_000_000);
      channel.seedFile('kept.txt', 'data', mtimeMs: 1_000_000_000);
      await service.addMount(
        alias: 'notes',
        uri: 'content://tree',
        displayName: 'x',
      );
      await pump();
      expect(await mirrorFile('notes', 'gone.txt').exists(), isTrue);

      channel.deleteRel('gone.txt');
      await service.syncNow('notes');
      await pump();
      expect(await mirrorFile('notes', 'gone.txt').exists(), isFalse);
      expect(await mirrorFile('notes', 'kept.txt').exists(), isTrue);
    });

    test('mirror-side deletion removes the SAF file', () async {
      channel.seedFile('gone.txt', 'data', mtimeMs: 1_000_000_000);
      await service.addMount(
        alias: 'notes',
        uri: 'content://tree',
        displayName: 'x',
      );
      await pump();

      await mirrorFile('notes', 'gone.txt').delete();
      await service.syncNow('notes');
      await pump();
      expect(() => channel.findByRel('gone.txt'), throwsStateError);
      // One round must be enough: pass 1 must NOT resurrect the deleted file
      // into the mirror (ADR-0037 pending-deletion skip).
      expect(await mirrorFile('notes', 'gone.txt').exists(), isFalse);
    });

    test(
      'mirror-side nested directory deletion converges while empty',
      () async {
        channel.seedFile('folder/nested/file.txt', 'data');
        await service.addMount(
          alias: 'notes',
          uri: 'content://tree',
          displayName: 'x',
        );
        await pump();

        await Directory(
          mirrorFile('notes', 'folder').path,
        ).delete(recursive: true);
        await service.syncNow('notes');
        await pump();
        expect(channel.root.children, isEmpty);
        expect(service.stateOf('notes').status, SafMountStatus.idle);

        // The completed round must have forgotten every descendant; otherwise
        // the empty-tree guard would strand the mount as unavailable here.
        await service.syncNow('notes');
        await pump();
        expect(service.stateOf('notes').status, SafMountStatus.idle);
      },
    );

    test(
      'delete-then-recreate after a deletion round is pushed, not destroyed',
      () async {
        channel.seedFile('a.md', 'v1', mtimeMs: 1_000_000_000);
        await service.addMount(
          alias: 'notes',
          uri: 'content://tree',
          displayName: 'x',
        );
        await pump();
        expect(await mirrorFile('notes', 'a.md').readAsString(), 'v1');

        // Round 1: the AI deletes a.md — the SAF copy goes away and the
        // snapshot forgets the path.
        await mirrorFile('notes', 'a.md').delete();
        await service.syncNow('notes');
        await pump();
        expect(() => channel.findByRel('a.md'), throwsStateError);

        // Round 2: the AI re-creates a.md before the next poll. The path is
        // NO LONGER in the snapshot, so the new content must be pushed, not
        // misread as a pending deletion and destroyed.
        await mirrorFile('notes', 'a.md').writeAsString('v2');
        await service.syncNow('notes');
        await pump();
        expect(utf8.decode(channel.findByRel('a.md').bytes), 'v2');
        expect(await mirrorFile('notes', 'a.md').readAsString(), 'v2');
      },
    );

    test(
      'a file absent from the snapshot is never treated as a deletion',
      () async {
        // First round: snapshot only knows a.txt. Add b.txt to the mirror
        // BEFORE any snapshot round exists for it via a manual pre-seed, then
        // delete it — it was never in the snapshot, so it must NOT propagate.
        await service.addMount(
          alias: 'notes',
          uri: 'content://tree',
          displayName: 'x',
        );
        await pump();
        await mirrorFile('notes', 'b.txt').writeAsString('never synced');
        await service.syncNow('notes');
        await pump();
        // b.txt is now in the snapshot (pushed). Delete it → propagates.
        await mirrorFile('notes', 'b.txt').delete();
        await service.syncNow('notes');
        await pump();
        expect(() => channel.findByRel('b.txt'), throwsStateError);
      },
    );

    test(
      'empty SAF tree while the mirror is also empty aborts the round',
      () async {
        channel.seedFile('only.txt', 'data', mtimeMs: 1_000_000_000);
        await service.addMount(
          alias: 'notes',
          uri: 'content://tree',
          displayName: 'x',
        );
        await pump();
        expect(await mirrorFile('notes', 'only.txt').exists(), isTrue);

        // Volume "unmounted": SAF tree becomes empty and the mirror is wiped
        // externally too. The guard must abort, not delete anything new.
        channel.deleteRel('only.txt');
        await mirrorFile('notes', 'only.txt').delete();
        channel.granted = false;
        await service.syncNow('notes');
        await pump();
        expect(service.stateOf('notes').status, SafMountStatus.unavailable);
      },
    );

    test('empty SAF tree never propagates deletions, even with a non-empty '
        'mirror (AI edits survive the unmount case)', () async {
      channel.seedFile('only.txt', 'data', mtimeMs: 1_000_000_000);
      await service.addMount(
        alias: 'notes',
        uri: 'content://tree',
        displayName: 'x',
      );
      await pump();

      // AI edit lands in the mirror AFTER the last completed round; the
      // SAF side then goes empty (unmounted volume). The snapshot-known
      // file must NOT be treated as deleted — the edit survives.
      await mirrorFile('notes', 'only.txt').writeAsString('ai edit');
      channel.deleteRel('only.txt');
      await service.syncNow('notes');
      await pump();

      expect(await mirrorFile('notes', 'only.txt').exists(), isTrue);
      expect(await mirrorFile('notes', 'only.txt').readAsString(), 'ai edit');
      expect(service.stateOf('notes').status, SafMountStatus.unavailable);
    });
  });

  group('access failures', () {
    test(
      'unsafe provider names abort before writing outside the mirror',
      () async {
        channel.root.children.add(
          _FakeSafNode(
            name: '../escaped.txt',
            isDirectory: false,
            uri: 'content://tree/unsafe-name',
          ),
        );

        await service.addMount(
          alias: 'notes',
          uri: 'content://tree',
          displayName: 'x',
        );
        await pump();

        expect(service.stateOf('notes').status, SafMountStatus.error);
        expect(
          await File(
            p.join(tempDir.path, 'saf_mounts', 'escaped.txt'),
          ).exists(),
          isFalse,
        );
      },
    );

    test(
      'revoked grant marks the mount unavailable and keeps the mirror',
      () async {
        channel.seedFile('keep.txt', 'data', mtimeMs: 1_000_000_000);
        await service.addMount(
          alias: 'notes',
          uri: 'content://tree',
          displayName: 'x',
        );
        await pump();

        await mirrorFile('notes', 'keep.txt').writeAsString('ai edit');
        channel.granted = false;
        await service.syncNow('notes');
        await pump();

        expect(service.stateOf('notes').status, SafMountStatus.unavailable);
        expect(await mirrorFile('notes', 'keep.txt').readAsString(), 'ai edit');
      },
    );

    test('recovers to idle once the grant is back', () async {
      channel.seedFile('a.txt', 'v1', mtimeMs: 1_000_000_000);
      await service.addMount(
        alias: 'notes',
        uri: 'content://tree',
        displayName: 'x',
      );
      await pump();

      channel.granted = false;
      await service.syncNow('notes');
      await pump();
      expect(service.stateOf('notes').status, SafMountStatus.unavailable);

      channel.granted = true;
      await service.syncNow('notes');
      await pump();
      expect(service.stateOf('notes').status, SafMountStatus.idle);
    });
  });

  group('removal and failure races', () {
    test('a round started after removeMount is a no-op', () async {
      channel.seedFile('keep.txt', 'data', mtimeMs: 1_000_000_000);
      await service.addMount(
        alias: 'notes',
        uri: 'content://tree',
        displayName: 'x',
      );
      await pump();

      await service.removeMount('notes');
      await pump();
      await service.syncNow('notes');
      await pump();

      // The SAF side is untouched and the mirror is NOT recreated.
      expect(channel.findByRel('keep.txt').bytes, isNotEmpty);
      expect(await Directory(mirrorPath('notes')).exists(), isFalse);
    });

    test('a corrupted mirror aborts the round without touching SAF', () async {
      channel.seedFile('keep.txt', 'data', mtimeMs: 1_000_000_000);
      await service.addMount(
        alias: 'notes',
        uri: 'content://tree',
        displayName: 'x',
      );
      await pump();

      // Corrupt the mirror: replace the directory with a plain file. The
      // round must abort (error state) — pass 3 must never misread the
      // broken mirror as deletions in the user's real directory.
      await Directory(mirrorPath('notes')).delete(recursive: true);
      await File(mirrorPath('notes')).writeAsString('junk');

      await service.syncNow('notes');
      await pump();
      expect(service.stateOf('notes').status, SafMountStatus.error);
      expect(channel.findByRel('keep.txt').bytes, isNotEmpty);
    });

    test('a transient SAF subdirectory listing failure aborts without '
        'touching the mirror', () async {
      channel.seedDir('sub');
      channel.seedFile('sub/a.txt', 'data', mtimeMs: 1_000_000_000);
      channel.seedFile('top.txt', 'data', mtimeMs: 1_000_000_000);
      await service.addMount(
        alias: 'notes',
        uri: 'content://tree',
        displayName: 'x',
      );
      await pump();
      expect(await mirrorFile('notes', 'sub/a.txt').exists(), isTrue);

      // Provider hiccup: listing "sub" fails. The mirror must NOT interpret
      // the missing subtree as deletions.
      channel.failingListUris.add(channel.findByRel('sub').uri);
      await service.syncNow('notes');
      await pump();

      expect(service.stateOf('notes').status, SafMountStatus.unavailable);
      expect(await mirrorFile('notes', 'sub/a.txt').exists(), isTrue);
      expect(await mirrorFile('notes', 'top.txt').exists(), isTrue);
    });

    test('stale .saf_tmp leftovers are pruned, never pushed to SAF', () async {
      channel.seedFile('a.txt', 'data', mtimeMs: 1_000_000_000);
      await service.addMount(
        alias: 'notes',
        uri: 'content://tree',
        displayName: 'x',
      );
      await pump();

      // Simulate a leftover copy temp inside the mirror (pre-ADR-0037-build
      // interruption). The round must prune it — pushing it into the user's
      // real directory would be data pollution.
      await mirrorFile('notes', 'b.txt.saf_tmp').writeAsString('junk');
      await service.syncNow('notes');
      await pump();

      expect(await mirrorFile('notes', 'b.txt.saf_tmp').exists(), isFalse);
      expect(() => channel.findByRel('b.txt.saf_tmp'), throwsStateError);
      expect(service.stateOf('notes').status, SafMountStatus.idle);
    });

    test('a persistently refused SAF delete surfaces an error state', () async {
      channel.seedFile('gone.txt', 'data', mtimeMs: 1_000_000_000);
      await service.addMount(
        alias: 'notes',
        uri: 'content://tree',
        displayName: 'x',
      );
      await pump();

      // Mirror-side deletion propagates to SAF, but the provider refuses the
      // delete without raising. The round must NOT claim "Synced".
      await mirrorFile('notes', 'gone.txt').delete();
      channel.failDeletes = true;
      await service.syncNow('notes');
      await pump();

      expect(service.stateOf('notes').status, SafMountStatus.error);
      expect(channel.findByRel('gone.txt').bytes, isNotEmpty);

      // Provider recovers: the next round completes and clears the state.
      channel.failDeletes = false;
      await service.syncNow('notes');
      await pump();
      expect(service.stateOf('notes').status, SafMountStatus.idle);
      expect(() => channel.findByRel('gone.txt'), throwsStateError);
    });

    test('snapshot persistence failure keeps the round in error', () async {
      channel.seedFile('a.txt', 'v1', mtimeMs: 1_000_000_000);
      await service.addMount(
        alias: 'notes',
        uri: 'content://tree',
        displayName: 'x',
      );
      await pump();
      final entry = service.entryByAlias('notes')!;
      await Directory('${service.raw.statePathFor(entry.id)}.tmp').create();

      await mirrorFile('notes', 'a.txt').writeAsString('v2');
      await service.syncNow('notes');
      await pump();

      expect(service.stateOf('notes').status, SafMountStatus.error);
    });
  });

  group('file↔directory type conflicts', () {
    test(
      'mirror file over SAF directory: the SAF directory is replaced',
      () async {
        channel.seedDir('x');
        channel.seedFile('x/inner.txt', 'inner', mtimeMs: 1_000_000_000);
        await service.addMount(
          alias: 'notes',
          uri: 'content://tree',
          displayName: 'x',
        );
        await pump();
        expect(await mirrorFile('notes', 'x/inner.txt').exists(), isTrue);

        // The AI replaces the whole directory with a file (newer side).
        await Directory(mirrorFile('notes', 'x').path).delete(recursive: true);
        await mirrorFile('notes', 'x').writeAsString('now a file');
        await service.syncNow('notes');
        await pump();

        final saf = channel.findByRel('x');
        expect(saf.isDirectory, isFalse);
        expect(utf8.decode(saf.bytes), 'now a file');
        expect(await mirrorFile('notes', 'x').readAsString(), 'now a file');
        expect(service.stateOf('notes').status, SafMountStatus.idle);
      },
    );

    test(
      'SAF file over mirror directory: the mirror directory is replaced',
      () async {
        channel.seedFile('y', 'file content', mtimeMs: 1_000_000_000);
        await service.addMount(
          alias: 'notes',
          uri: 'content://tree',
          displayName: 'x',
        );
        await pump();

        // The AI replaces the file with a directory tree (newer side).
        await mirrorFile('notes', 'y').delete();
        await Directory(mirrorFile('notes', 'y').path).create();
        await mirrorFile('notes', 'y/c.txt').writeAsString('new child');
        await service.syncNow('notes');
        await pump();

        final saf = channel.findByRel('y');
        expect(saf.isDirectory, isTrue);
        expect(utf8.decode(channel.findByRel('y/c.txt').bytes), 'new child');
        expect(
          await mirrorFile('notes', 'y/c.txt').readAsString(),
          'new child',
        );
      },
    );

    test('SAF-side file wins over a stale mirror directory', () async {
      channel.seedFile('z', 'v1', mtimeMs: 1_000_000_000);
      await service.addMount(
        alias: 'notes',
        uri: 'content://tree',
        displayName: 'x',
      );
      await pump();

      // The AI replaces the file with a directory, but an external edit
      // lands on the SAF file afterwards with a NEWER mtime.
      await mirrorFile('notes', 'z').delete();
      await Directory(mirrorFile('notes', 'z').path).create();
      channel.touchFile('z', mtimeMs: channel.nowMs, content: 'v2');
      await service.syncNow('notes');
      await pump();

      final mirrorZ = File(mirrorFile('notes', 'z').path);
      expect(await mirrorZ.exists(), isTrue);
      expect(await Directory(mirrorFile('notes', 'z').path).exists(), isFalse);
      expect(await mirrorZ.readAsString(), 'v2');
      expect(utf8.decode(channel.findByRel('z').bytes), 'v2');
    });
  });

  group('mutation triggers', () {
    test(
      'notifyMutated schedules a debounced push for SAF mounts only',
      () async {
        await service.addMount(
          alias: 'notes',
          uri: 'content://tree',
          displayName: 'x',
        );
        await pump();

        await mirrorFile('notes', 'triggered.txt').writeAsString('hello');
        // Non-SAF aliases are ignored.
        service.notifyMutated('default');
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(() => channel.findByRel('triggered.txt'), throwsStateError);

        service.notifyMutated('notes');
        await Future<void>.delayed(
          SafMountSyncService.mutationDebounce +
              const Duration(milliseconds: 300),
        );
        await pump();
        expect(utf8.decode(channel.findByRel('triggered.txt').bytes), 'hello');
      },
    );
  });

  group('guest binds and persistence', () {
    test('guestBinds expose host mirrors under /workspace/.mounts', () async {
      await service.addMount(
        alias: 'notes',
        uri: 'content://tree',
        displayName: 'x',
      );
      await service.addMount(
        alias: 'robox',
        uri: 'content://tree/other',
        displayName: 'x',
      );
      await pump();

      final binds = service.guestBinds;
      expect(binds, hasLength(2));
      expect(binds[0]['guest'], '/workspace/.mounts/notes');
      expect(binds[0]['host'], mirrorPath('notes'));
      expect(binds[0]['readOnly'], isFalse);
      expect(binds[1]['guest'], '/workspace/.mounts/robox');
      expect(binds[1]['readOnly'], isFalse);
    });

    test(
      'mount config survives a service restart via workspace meta',
      () async {
        await service.addMount(
          alias: 'notes',
          uri: 'content://tree',
          displayName: 'My Notes',
        );
        await pump();

        final restarted = SafMountSyncService(
          preferences: businessPrefs,
          workspaces: workspaces,
          channel: channel,
        );
        await restarted.init();
        await pump();
        final entries = restarted.entriesFor(Workspace.defaultId);
        expect(entries, hasLength(1));
        expect(entries.first.alias, 'notes');
        expect(entries.first.uri, 'content://tree');
        final mounts = restarted.mountsFor(Workspace.defaultId);
        expect(mounts.first.isSafMount, isTrue);
        expect(mounts.first.path, mirrorPath('notes'));
        restarted.dispose();
      },
    );

    test('removeMount wipes the mirror and the snapshot', () async {
      await service.addMount(
        alias: 'notes',
        uri: 'content://tree',
        displayName: 'x',
      );
      await pump();
      await mirrorFile('notes', 'a.txt').writeAsString('x');
      final entry = service.entryByAlias('notes')!;
      final oldMirrorPath = service.raw.mirrorPathFor(entry.id);
      final oldStatePath = service.raw.statePathFor(entry.id);

      await service.removeMount('notes');
      await pump();
      expect(await Directory(oldMirrorPath).exists(), isFalse);
      expect(await File(oldStatePath).exists(), isFalse);
    });
  });

  group('workspace scoping', () {
    test('non-Android restore preserves metadata without syncing', () async {
      service.raw.dispose();
      const entry = WorkspaceSafMount(
        id: 'restored_mount',
        alias: 'notes',
        uri: 'content://tree/restored',
        displayName: 'Restored',
      );
      await workspaces.addSafMount(Workspace.defaultId, entry);
      SafMountSyncService.androidProbe = () => false;
      service = _TestSafMountService(
        SafMountSyncService(
          preferences: businessPrefs,
          workspaces: workspaces,
          channel: channel,
        ),
      );

      await service.init();
      expect(await service.raw.pickTree(), isNull);
      expect(
        await service.raw.addMount(
          workspaceId: Workspace.defaultId,
          alias: 'other',
          uri: 'content://tree/other',
          displayName: 'Other',
        ),
        SafMountSyncService.errorUnsupported,
      );
      await service.raw.syncAll();
      await service.raw.syncNow(entry.id);
      await service.raw.reloadAfterRestore();

      expect(channel.checkAccessCalls, 0);
      expect(channel.pickTreeCalls, 0);
      expect(
        await Directory(service.raw.mirrorPathFor(entry.id)).exists(),
        isFalse,
      );
      expect(workspaces.getById(Workspace.defaultId)!.safMounts, [entry]);
    });

    test(
      'isolates mounts and aliases while rejecting a duplicate URI',
      () async {
        final second = await workspaces.createWorkspace(displayName: 'Second');
        final firstError = await service.raw.addMount(
          workspaceId: Workspace.defaultId,
          alias: 'notes',
          uri: _FakeSafChannel.rootUri,
          displayName: 'First notes',
        );
        final secondError = await service.raw.addMount(
          workspaceId: second.id,
          alias: 'notes',
          uri: 'content://tree/second',
          displayName: 'Second notes',
        );
        expect(firstError, isNull);
        expect(secondError, isNull);

        final firstEntries = service.raw.entriesFor(Workspace.defaultId);
        final secondEntries = service.raw.entriesFor(second.id);
        expect(firstEntries.map((e) => e.alias), ['notes']);
        expect(secondEntries.map((e) => e.alias), ['notes']);
        expect(firstEntries.single.id, isNot(secondEntries.single.id));
        expect(
          service.raw.mountsFor(Workspace.defaultId).single.path,
          isNot(service.raw.mountsFor(second.id).single.path),
        );
        expect(
          service.raw.guestBindsFor(Workspace.defaultId).single['readOnly'],
          isFalse,
        );

        final duplicateUri = await service.raw.addMount(
          workspaceId: second.id,
          alias: 'shared',
          uri: _FakeSafChannel.rootUri,
          displayName: 'Duplicate',
        );
        expect(duplicateUri, SafMountSyncService.errorUriDuplicate);

        final rootCollision = await service.raw.addMount(
          workspaceId: second.id,
          alias: second.alias,
          uri: 'content://tree/collision',
          displayName: 'Collision',
        );
        expect(rootCollision, SafMountSyncService.errorAliasReserved);
      },
    );

    test(
      'workspace tool enablement gates SAF paths without extra ACLs',
      () async {
        await service.addMount(
          alias: 'notes',
          uri: _FakeSafChannel.rootUri,
          displayName: 'Notes',
        );
        final assistant = Assistant(
          id: 'assistant',
          name: 'Assistant',
          workspaceEnabled: true,
          workspaceId: Workspace.defaultId,
        );
        await workspaces.setToolEnabled(
          Workspace.defaultId,
          WorkspaceToolNames.write,
          false,
        );

        final disabled = await WorkspaceToolsService.tryHandleToolCall(
          name: WorkspaceToolNames.write,
          args: const {
            'path': '/workspace/.mounts/notes/disabled.txt',
            'content': 'blocked',
          },
          assistant: assistant,
          workspaces: workspaces,
          safMounts: service.raw,
        );
        expect(disabled, isNull);
        expect(
          await File(p.join(mirrorPath('notes'), 'disabled.txt')).exists(),
          isFalse,
        );

        await workspaces.setToolEnabled(
          Workspace.defaultId,
          WorkspaceToolNames.write,
          true,
        );
        final enabled = await WorkspaceToolsService.tryHandleToolCall(
          name: WorkspaceToolNames.write,
          args: const {
            'path': '/workspace/.mounts/notes/enabled.txt',
            'content': 'allowed',
          },
          assistant: assistant,
          workspaces: workspaces,
          safMounts: service.raw,
        );
        expect(enabled, isNotNull);
        expect(
          await File(p.join(mirrorPath('notes'), 'enabled.txt')).readAsString(),
          'allowed',
        );
      },
    );

    test(
      'deleting a workspace cleans its private mirror and snapshot',
      () async {
        final second = await workspaces.createWorkspace(displayName: 'Second');
        await service.raw.addMount(
          workspaceId: second.id,
          alias: 'docs',
          uri: 'content://tree/second',
          displayName: 'Docs',
        );
        final entry = service.raw.entriesFor(second.id).single;
        final mirror = service.raw.mirrorPathFor(entry.id);
        final snapshot = service.raw.statePathFor(entry.id);
        await File(p.join(mirror, 'local.txt')).writeAsString('keep external');
        await File(snapshot).writeAsString('{}');

        expect(await workspaces.deleteWorkspace(second.id), isNull);
        await pump();

        expect(service.raw.entriesFor(second.id), isEmpty);
        expect(await Directory(mirror).exists(), isFalse);
        expect(await File(snapshot).exists(), isFalse);
      },
    );

    test('cannot remove another workspace mount by stable ID', () async {
      final second = await workspaces.createWorkspace(displayName: 'Second');
      await service.raw.addMount(
        workspaceId: second.id,
        alias: 'docs',
        uri: 'content://tree/second',
        displayName: 'Docs',
      );
      final entry = service.raw.entriesFor(second.id).single;
      final mirror = service.raw.mirrorPathFor(entry.id);

      await service.raw.removeMount(Workspace.defaultId, entry.id);

      expect(service.raw.entriesFor(second.id).single.id, entry.id);
      expect(await Directory(mirror).exists(), isTrue);
    });

    test('legacy global config and mirrors are discarded', () async {
      final prefs = businessPrefs;
      await prefs.setString(
        SafMountSyncService.legacyPrefsKey,
        '[{"alias":"old"}]',
      );
      final legacyMirror = Directory(p.join(tempDir.path, 'saf_mounts', 'old'));
      await legacyMirror.create(recursive: true);

      await service.raw.reloadAfterRestore();

      expect(prefs.containsKey(SafMountSyncService.legacyPrefsKey), isFalse);
      expect(await legacyMirror.exists(), isFalse);
    });

    test(
      'restore keeps the first valid URI and skips malformed mounts',
      () async {
        final prefs = businessPrefs;
        await prefs.setString(
          WorkspaceProvider.metaPrefsKey,
          jsonEncode([
            {
              'id': Workspace.defaultId,
              'displayName': 'Default',
              'alias': Workspace.defaultAlias,
              'safMounts': [
                {
                  'id': 'mount_one',
                  'alias': 'notes',
                  'uri': 'content://tree/shared',
                  'displayName': 'Notes',
                },
                {
                  'id': '../unsafe',
                  'alias': 'unsafe',
                  'uri': 'content://tree/unsafe',
                  'displayName': 'Unsafe',
                },
                {
                  'id': 'mount_alias_duplicate',
                  'alias': 'notes',
                  'uri': 'content://tree/other',
                  'displayName': 'Duplicate alias',
                },
              ],
            },
            {
              'id': 'workspace_second',
              'displayName': 'Second',
              'alias': 'workspace_2',
              'safMounts': [
                {
                  'id': 'mount_two',
                  'alias': 'docs',
                  'uri': 'content://tree/shared',
                  'displayName': 'Duplicate URI',
                },
              ],
            },
          ]),
        );

        await workspaces.reloadFromPrefs();
        await pump();

        expect(
          workspaces.getById(Workspace.defaultId)!.safMounts,
          hasLength(1),
        );
        expect(
          workspaces.getById(Workspace.defaultId)!.safMounts.single.id,
          'mount_one',
        );
        expect(workspaces.getById('workspace_second')!.safMounts, isEmpty);
      },
    );
  });
}
