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

  test('build serves what it can and reports what it cannot', () async {
    final hasher = BlobFileHasher();
    final resolve = resolverFor(root);
    final present = await write('images/present.png', 'present-bytes');

    final built = await buildFileBlobEntries(
      {
        'kelivo-file:///images/present.png',
        'kelivo-file:///images/missing.png',
        'kelivo-file:///skills/s/SKILL.md',
      },
      hasher,
      resolve: resolve,
    );

    expect(built.entries, hasLength(1));
    expect(built.entries.single.key, 'kelivo-file:///images/present.png');
    expect(
      built.entries.single.contentHash,
      hashOfBytes(await present.readAsBytes()),
    );
    expect(built.entries.single.byteSize, await present.length());
    // A referenced file this device cannot serve is reported, not skipped:
    // one bucket, because the sender's next move is the same for every reason
    // — a file that is not there, and a root the blob plane may not write.
    expect(built.missing, {
      'kelivo-file:///images/missing.png',
      'kelivo-file:///skills/s/SKILL.md',
    });

    final entries = built.entries;

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
  });

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

  group('an inline reference is parsed, not pattern-matched', () {
    test("the app's own Markdown form yields the file", () {
      // This is the shape the app writes when a pasted image is saved to disk:
      // the URI sits inside a Markdown image, and `)` is a legal path character
      // — which is why a character class swallowed the bracket, the strict
      // parser then rejected the candidate, and the file was never advertised.
      expect(
        kelivoFileUrisInRows([
          {'payload': 'look: ![shot](kelivo-file:///images/a.png) ok'},
        ]),
        {'kelivo-file:///images/a.png'},
      );
    });

    test('a whole JSON value keeps a tail that would be prose in a sentence', () {
      // The framing is the evidence: a `"` right after the run says the run is
      // the value, so a trailing `,`, `!` or a balanced bracket pair there is the
      // name. Trimming it advertises a path that does not exist — the real file
      // never travels and only the wrong URI reaches the sender's log.
      expect(
        kelivoFileUrisInRows([
          {'payload': '{"u":"kelivo-file:///upload/report,"}'},
        ]),
        {'kelivo-file:///upload/report,'},
      );
      expect(
        kelivoFileUrisInRows([
          {'payload': '{"u":"kelivo-file:///upload/hello!"}'},
        ]),
        {'kelivo-file:///upload/hello!'},
      );
      expect(
        kelivoFileUrisInRows([
          {'payload': '{"u":"kelivo-file:///upload/notes(1)"}'},
        ]),
        {'kelivo-file:///upload/notes(1)'},
      );
      // A link's bracket around a whole value is still the link's, and counting
      // is what tells it apart from the name's own pair.
      expect(
        kelivoFileUrisInRows([
          {'payload': '{"text":"![shot](kelivo-file:///upload/notes(1))"}'},
        ]),
        {'kelivo-file:///upload/notes(1)'},
      );
    });

    test('sentence punctuation is not part of the path', () {
      expect(
        kelivoFileUrisInRows([
          {'payload': 'see kelivo-file:///images/a.png.'},
        ]),
        {'kelivo-file:///images/a.png'},
      );
    });

    test('a balanced parenthesis stays in the path', () {
      expect(
        kelivoFileUrisInRows([
          {'payload': 'kelivo-file:///images/a(1).png'},
        ]),
        {'kelivo-file:///images/a(1).png'},
      );
    });

    test('a file name carrying an unbalanced parenthesis is still the file', () {
      // The writer leaves `()` raw and a path may contain them, so a `)` inside
      // the name must not be read as the Markdown bracket that closes the link.
      // Both shapes end in `)`: the trim takes the bracket, the name keeps its
      // own parenthesis.
      expect(
        kelivoFileUrisInRows([
          {'payload': '![shot](kelivo-file:///upload/a)b.png)'},
        ]),
        {'kelivo-file:///upload/a)b.png'},
      );
      expect(
        kelivoFileUrisInRows([
          {'payload': '![shot](kelivo-file:///upload/a(b.png)'},
        ]),
        {'kelivo-file:///upload/a(b.png'},
      );
    });

    test('a possessive after a reference is prose, not part of the name', () {
      // `'` is not a path character here: the writer escapes a real one as
      // `%27`, so a raw `'` after a reference is prose.
      expect(
        kelivoFileUrisInRows([
          {'payload': "see kelivo-file:///upload/a.png's contents"},
        ]),
        {'kelivo-file:///upload/a.png'},
      );
      expect(
        kelivoFileUrisInRows([
          {'payload': "kelivo-file:///upload/it%27s.png's"},
        ]),
        {'kelivo-file:///upload/it%27s.png'},
      );
    });

    test("a file name carrying an apostrophe is advertised escaped", () {
      // The producer's half of the same rule: `encodeComponent` leaves `'` raw,
      // so `_encodeSegments` escapes it. A reference like this is what the app
      // writes for `Bob's photo.png`, and it has to stay a file reference.
      expect(
        kelivoFileUrisInRows([
          {'payload': '![photo](kelivo-file:///upload/Bob%27s%20photo.png)'},
        ]),
        {'kelivo-file:///upload/Bob%27s%20photo.png'},
      );
    });

    test('a second reference is not part of the first', () {
      expect(
        kelivoFileUrisInRows([
          {
            'payload':
                '![a](kelivo-file:///images/a.png)(kelivo-file:///images/b.png)',
          },
        ]),
        {'kelivo-file:///images/a.png', 'kelivo-file:///images/b.png'},
      );
    });

    test('a run that never parses costs the cap, not the value', () {
      // The shortening loop is bounded by the parse cap, so the scheme followed
      // by a pasted base64 blob cannot make discovery quadratic in the payload.
      final blob = 'kelivo-file://${'A' * 320000}';
      final watch = Stopwatch()..start();
      expect(
        kelivoFileUrisInRows([
          {'payload': blob},
        ]),
        isEmpty,
      );
      watch.stop();
      expect(
        watch.elapsedMilliseconds,
        lessThan(2000),
        reason: 'a bounded scan cannot take seconds on 320 KB',
      );
    });

    test('a reference longer than the cap is refused, not truncated', () {
      // A truncated prefix can parse, and a URI that parses is treated as a file
      // to advertise — so the cap has to refuse the run instead.
      final long = 'kelivo-file:///upload/${'a' * 1200}.png';
      expect(
        kelivoFileUrisInRows([
          {'payload': long},
        ]),
        isEmpty,
      );
    });

    test('the same file twice in one payload is one reference', () {
      expect(
        kelivoFileUrisInRows([
          {
            'payload':
                '![a](kelivo-file:///images/a.png) '
                '![b](kelivo-file:///images/a.png)',
          },
        ]),
        {'kelivo-file:///images/a.png'},
      );
    });

    test('a scheme with nothing behind it is not a reference', () {
      expect(
        kelivoFileUrisInRows([
          {'payload': 'kelivo-file://'},
        ]),
        isEmpty,
      );
    });

    test('the file a Markdown image names is advertised', () async {
      await write('images/a.png', 'png-bytes');
      final built = await buildFileBlobEntries(
        kelivoFileUrisInRows([
          {'payload': '![shot](kelivo-file:///images/a.png)'},
        ]),
        BlobFileHasher(),
        resolve: resolverFor(root),
      );

      expect(built.entries.map((entry) => entry.key), [
        'kelivo-file:///images/a.png',
      ]);
      expect(built.missing, isEmpty);
    });
  });
}
