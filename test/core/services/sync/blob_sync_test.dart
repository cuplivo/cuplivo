import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/services/sync/blob_sync.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';

/// The blob plane's pure parts: URI discovery in travelling rows, the managed
/// root allowlist, manifest building, need detection and placement.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('blob_sync_test_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// A resolver standing in for the sandbox one, rooted at [base].
  BlobPathResolver resolverFor(Directory base) => (uri) {
    const prefix = 'kelivo-file:///';
    if (!uri.startsWith(prefix)) return null;
    final rest = uri.substring(prefix.length);
    if (rest.isEmpty) {
      return null;
    }
    return '${base.path}/${rest.replaceAll('/', Platform.pathSeparator)}';
  };

  Future<File> write(String relative, String content) async {
    final file = File('${root.path}/$relative');
    await file.parent.create(recursive: true);
    await file.writeAsString(content, flush: true);
    return file;
  }

  String hashOfBytes(List<int> bytes) =>
      crypto.sha256.convert(bytes).toString();

  group('kelivoFileUrisInRows', () {
    test('finds URIs inside JSON payload strings and ignores other values', () {
      final rows = <Map<String, dynamic>>[
        {
          'part_id': 'p1',
          'kind': 'image',
          'payload': jsonEncode({
            'uri': 'kelivo-file:///images/a.png',
            'mime': 'image/png',
          }),
        },
        {'ordinal': 0, 'nothing': null},
        {
          'payload': jsonEncode({
            'attachments': [
              'kelivo-file:///upload/report%20final.pdf',
              'https://example.com/b.png',
              'data:image/png;base64,AAAA',
            ],
          }),
        },
      ];

      expect(kelivoFileUrisInRows(rows), {
        'kelivo-file:///images/a.png',
        'kelivo-file:///upload/report%20final.pdf',
      });
    });

    test('drops malformed candidates rather than letting them reach I/O', () {
      final rows = <Map<String, dynamic>>[
        {
          'payload': jsonEncode({
            'a': 'kelivo-file:///../secret',
            'b': 'kelivo-file://host/upload/a.png',
            'c': 'kelivo-file:///upload/',
          }),
        },
      ];
      expect(kelivoFileUrisInRows(rows), isEmpty);
    });
  });

  test('the allowlist covers managed asset roots only', () {
    expect(isAllowedFileBlobUri('kelivo-file:///upload/a.bin'), isTrue);
    expect(isAllowedFileBlobUri('kelivo-file:///images/a.png'), isTrue);
    expect(isAllowedFileBlobUri('kelivo-file:///avatars/a.png'), isTrue);
    expect(isAllowedFileBlobUri('kelivo-file:///fonts/a.ttf'), isTrue);
    // A skill body is a directory blob, not a file blob; workspaces and
    // sessions are device-local by decision.
    expect(isAllowedFileBlobUri('kelivo-file:///skills/s/SKILL.md'), isFalse);
    expect(isAllowedFileBlobUri('kelivo-file:///workspaces/w/f.txt'), isFalse);
    expect(isAllowedFileBlobUri('kelivo-file:///sessions/c/f.txt'), isFalse);
    expect(isAllowedFileBlobUri('https://example.com/a.png'), isFalse);
  });

  test(
    'build skips what this device cannot serve, need finds what is absent',
    () async {
      final hasher = BlobFileHasher();
      final resolve = resolverFor(root);
      final present = await write('images/present.png', 'present-bytes');

      final entries = await buildFileBlobEntries(
        {
          'kelivo-file:///images/present.png',
          'kelivo-file:///images/missing.png',
          'kelivo-file:///skills/s/SKILL.md',
        },
        hasher,
        resolve: resolve,
      );

      expect(entries, hasLength(1));
      expect(entries.single.key, 'kelivo-file:///images/present.png');
      expect(
        entries.single.contentHash,
        hashOfBytes(await present.readAsBytes()),
      );
      expect(entries.single.byteSize, await present.length());

      // The receiver has nothing: the entry is needed.
      final receiverRoot = await Directory.systemTemp.createTemp('blob_peer_');
      addTearDown(() async {
        if (await receiverRoot.exists()) {
          await receiverRoot.delete(recursive: true);
        }
      });
      final needed = await neededFileBlobEntries(
        entries,
        BlobFileHasher(),
        resolve: resolverFor(receiverRoot),
      );
      expect(needed, hasLength(1));

      // The receiver has the identical bytes: nothing to fetch.
      final copy = File('${receiverRoot.path}/images/present.png');
      await copy.parent.create(recursive: true);
      await copy.writeAsBytes(await present.readAsBytes(), flush: true);
      expect(
        await neededFileBlobEntries(
          entries,
          BlobFileHasher(),
          resolve: resolverFor(receiverRoot),
        ),
        isEmpty,
      );

      // A different file at the same path is a mismatch, so it is still needed
      // (the travelling rows are authoritative for that path).
      await copy.writeAsString('someone-elses-bytes', flush: true);
      expect(
        await neededFileBlobEntries(
          entries,
          BlobFileHasher(),
          resolve: resolverFor(receiverRoot),
        ),
        hasLength(1),
      );
    },
  );

  test(
    'placeFileBlob lands the bytes at the URI path, replacing what was there',
    () async {
      final resolve = resolverFor(root);
      final bytes = utf8.encode('new-bytes');
      final staged = File('${root.path}/incoming.bin');
      await staged.writeAsBytes(bytes, flush: true);
      final entry = SyncBlobEntry(
        kind: SyncBlobEntry.kindFile,
        key: 'kelivo-file:///upload/doc.txt',
        contentHash: hashOfBytes(bytes),
        byteSize: bytes.length,
      );

      // An older file with different content sits at the target.
      await write('upload/doc.txt', 'old-bytes');

      final landed = await placeFileBlob(entry, staged, resolve: resolve);

      expect(landed, bytes.length);
      expect(
        await File('${root.path}/upload/doc.txt').readAsString(),
        'new-bytes',
      );
      expect(await staged.exists(), isFalse, reason: 'moved, not copied');
    },
  );

  test('a file blob outside the managed roots is never placed', () async {
    final staged = File('${root.path}/incoming.bin');
    await staged.writeAsString('bytes', flush: true);
    final entry = SyncBlobEntry(
      kind: SyncBlobEntry.kindFile,
      key: 'kelivo-file:///sessions/c/evil.txt',
      contentHash: hashOfBytes(utf8.encode('bytes')),
    );

    expect(
      await placeFileBlob(entry, staged, resolve: resolverFor(root)),
      isNull,
    );
    expect(await staged.exists(), isTrue, reason: 'nothing was consumed');
  });
}
