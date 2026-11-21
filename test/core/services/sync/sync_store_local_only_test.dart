import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/services/sync/sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// The device-local set of rows this machine holds without offering them.
///
/// It lives beside the workspace toggles and for the same reason: it says what
/// *this* device is willing to hand over, so it rides neither the wire nor a
/// backup. What the wire carries is the announcement — a list of keys — and the
/// store is where that list comes from.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cuplivo_sync_local_only_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  File file() => File('${root.path}${Platform.pathSeparator}local-only.json');

  test('a store without the file holds nothing', () async {
    expect(await SyncStore(root).readLocalOnlyKeys(), isEmpty);
  });

  test('a key survives a write and a fresh store instance', () async {
    const key = 'mcp_server_rows\u0000m1';
    expect(
      await SyncStore(root).mutateLocalOnlyKeys((keys) => keys.add(key)),
      isTrue,
    );
    expect(await SyncStore(root).readLocalOnlyKeys(), {key});
  });

  test('releasing the key removes it and reports the change', () async {
    const key = 'mcp_server_rows\u0000m1';
    final store = SyncStore(root);
    await store.mutateLocalOnlyKeys((keys) => keys.add(key));
    expect(await store.mutateLocalOnlyKeys((keys) => keys.remove(key)), isTrue);
    expect(await store.readLocalOnlyKeys(), isEmpty);
    // A mutation that changes nothing is not a write: the file keeps its
    // stamp, which is what keeps a no-op toggle from churning the disk.
    final before = await file().lastModified();
    expect(
      await store.mutateLocalOnlyKeys((keys) => keys.remove(key)),
      isFalse,
    );
    expect(await file().lastModified(), before);
  });

  test('two toggles landing together both survive', () async {
    // The read-modify-write is one indivisible step: the set is one file, so a
    // second writer that read before the first wrote would drop the first's
    // key — a server that quietly starts syncing again on the next read.
    final store = SyncStore(root);
    await Future.wait([
      store.mutateLocalOnlyKeys((keys) => keys.add('mcp_server_rows\u0000m1')),
      store.mutateLocalOnlyKeys((keys) => keys.add('mcp_server_rows\u0000m2')),
    ]);
    expect(await SyncStore(root).readLocalOnlyKeys(), {
      'mcp_server_rows\u0000m1',
      'mcp_server_rows\u0000m2',
    });
  });

  test('an unreadable file reads as "nothing held"', () async {
    // The reading the workspace toggles take: refusing to sync anything because
    // a preferences file was truncated would be the worse failure.
    await file().writeAsString('{not json');
    expect(await SyncStore(root).readLocalOnlyKeys(), isEmpty);
  });

  test('a key of a row that no longer exists is kept', () async {
    // Nothing here knows whether the row exists — that is the point. A server
    // deleted and restored from the recycle bin has to come back still held,
    // and a sweep would have dropped the key while the row was in the bin.
    const key = 'mcp_server_rows\u0000gone';
    final store = SyncStore(root);
    await store.mutateLocalOnlyKeys((keys) => keys.add(key));
    expect(await store.readLocalOnlyKeys(), {key});
  });

  test('the file is the documented shape', () async {
    final store = SyncStore(root);
    await store.mutateLocalOnlyKeys((keys) {
      keys.addAll(['b\u0000x', 'a\u0000y']);
      return true;
    });
    final json =
        jsonDecode(await file().readAsString()) as Map<String, dynamic>;
    // Sorted, so two devices' files diff cleanly and the hello's list is stable.
    expect(json['keys'], ['a\u0000y', 'b\u0000x']);
  });
}
