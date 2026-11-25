import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:Cuplivo/features/harness/services/dsh_preview_cache.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cuplivo-dsh-preview-test-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('materializes UTF-8 text with the original extension', () async {
    final cache = DshPreviewCache(root: root);
    final file = await cache.materializeText(
      remoteId: 'remote 1',
      sessionId: 'session/1',
      path: 'docs/notes.md',
      text: 'héllo',
    );

    expect(await file.readAsString(), 'héllo');
    expect(await file.readAsBytes(), utf8.encode('héllo'));
    expect(p.extension(file.path), '.md');
    expect(
      p.isWithin(root.path, file.path),
      isTrue,
      reason: 'the cache must never write outside its root',
    );
    expect(
      file.path,
      contains(p.join('remote_1', 'session_1')),
      reason: 'one directory per remote and session',
    );
  });

  test('sanitizes traversal and separator characters in the path', () async {
    final cache = DshPreviewCache(root: root);
    final file = await cache.materializeText(
      remoteId: '../../remote',
      sessionId: '../session',
      path: '../../etc/passwd.txt',
      text: 'safe',
    );

    expect(p.isWithin(root.path, file.path), isTrue);
    expect(p.basename(file.path), endsWith('passwd.txt'));
    expect(file.path, isNot(contains('..')));
  });

  test('rejects an oversized body without writing anything', () async {
    final cache = DshPreviewCache(root: root, maxEntryBytes: 4);

    await expectLater(
      cache.materializeBytes(
        remoteId: 'r',
        sessionId: 's',
        path: 'big.bin',
        bytes: const <int>[1, 2, 3, 4, 5],
      ),
      throwsA(
        isA<DshPreviewCacheException>().having(
          (error) => error.failure,
          'failure',
          DshPreviewCacheFailure.tooLarge,
        ),
      ),
    );
    expect(await cache.currentTotalBytes(), 0);
  });

  test('derives the total budget and evicts the oldest entries', () async {
    // total = 2 entries of 4 bytes.
    final cache = DshPreviewCache(root: root, maxEntryBytes: 4, totalLimit: 8);
    final first = await cache.materializeText(
      remoteId: 'r',
      sessionId: 's',
      path: 'one.txt',
      text: 'aaaa',
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final second = await cache.materializeText(
      remoteId: 'r',
      sessionId: 's',
      path: 'two.txt',
      text: 'bbbb',
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final third = await cache.materializeText(
      remoteId: 'r',
      sessionId: 's',
      path: 'three.txt',
      text: 'cccc',
    );

    expect(await cache.currentTotalBytes(), lessThanOrEqualTo(8));
    expect(await first.exists(), isFalse, reason: 'oldest entry was evicted');
    expect(await second.exists(), isTrue);
    expect(await third.exists(), isTrue);
  });

  test('materializes binary bytes verbatim', () async {
    final cache = DshPreviewCache(root: root);
    final file = await cache.materializeBytes(
      remoteId: 'r',
      sessionId: 's',
      path: 'assets/pixel.png',
      bytes: const <int>[0, 1, 2, 255],
    );

    expect(await file.readAsBytes(), const <int>[0, 1, 2, 255]);
    expect(p.extension(file.path), '.png');
  });

  test('clear removes the whole cache', () async {
    final cache = DshPreviewCache(root: root);
    await cache.materializeText(
      remoteId: 'r',
      sessionId: 's',
      path: 'one.txt',
      text: 'one',
    );
    await cache.clear();

    expect(await root.exists(), isFalse);
    expect(await cache.currentTotalBytes(), 0);
  });
}
