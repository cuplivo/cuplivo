import 'dart:io';

import 'package:Cuplivo/core/services/sync/workspace_content_index.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The workspace content walk: what rides, what is pruned, and where it stops.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ws-index-');
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {
      // A locked temp file on Windows is not what these tests are about.
    }
  });

  Future<File> put(String relPath, String content) async {
    final file = File(p.joinAll([root.path, ...p.posix.split(relPath)]));
    await file.parent.create(recursive: true);
    await file.writeAsString(content, flush: true);
    return file;
  }

  test('indexes what rides, with posix paths and real stamps', () async {
    await put('src/a.dart', 'aaa');
    await put('src/deep/b.txt', 'bbbb');
    final file = File(p.join(root.path, 'src', 'a.dart'));
    final stat = file.statSync();

    final index = indexWorkspaceContentSync(root.path);

    expect(index.files.keys, unorderedEquals(['src/a.dart', 'src/deep/b.txt']));
    expect(index.files['src/a.dart']!.size, 3);
    expect(
      index.files['src/a.dart']!.mtimeMs,
      stat.modified.millisecondsSinceEpoch,
    );
    expect(index.totalBytes, 7);
    expect(index.truncated, isFalse);
  });

  test('prunes version-control, dependency and build trees', () async {
    await put('src/a.dart', 'a');
    for (final dir in [
      '.git/config',
      '.svn/entries',
      '.hg/store',
      'node_modules/pkg/index.js',
      'NODE_MODULES/pkg/index.js',
      '.venv/lib/python',
      'venv/bin/python',
      '__pycache__/a.pyc',
      '.dart_tool/package_config.json',
      'build/out.bin',
      'dist/bundle.js',
      'target/debug/app',
      '.next/build-manifest.json',
      '.gradle/caches/x',
      'Pods/Alamofire/a.swift',
      '.terraform/state',
      'src/build/nested.txt',
      '.sync-staging/partial',
      '.sync-old-123/file',
    ]) {
      await put(dir, 'x');
    }

    final index = indexWorkspaceContentSync(root.path);

    expect(index.files.keys, [
      'src/a.dart',
    ], reason: 'only the source survives the prune');
  });

  test('prunes the bookkeeping files every desktop drops', () async {
    await put('.DS_Store', 'x');
    await put('Thumbs.db', 'x');
    await put('desktop.ini', 'x');
    await put('sub/.DS_Store', 'x');
    await put('kept.md', 'x');

    final index = indexWorkspaceContentSync(root.path);

    expect(index.files.keys, ['kept.md']);
  });

  test('stops the moment the file cap is passed, and says so', () async {
    await put('a.txt', 'a');
    await put('b.txt', 'b');
    await put('c.txt', 'c');

    final index = indexWorkspaceContentSync(root.path, maxFiles: 2);

    expect(index.truncated, isTrue);
    expect(
      index.files.length,
      3,
      reason: 'the walk aborts on the file that exceeded the cap',
    );
    expect(
      index.totalBytes,
      3,
      reason: 'the figures it did collect are still reported, as lower bounds',
    );
  });

  test('stops the moment the byte cap is passed', () async {
    await put('a.txt', 'aaaa');
    await put('b.txt', 'bbbb');

    final index = indexWorkspaceContentSync(root.path, maxBytes: 5);

    expect(index.truncated, isTrue);
    expect(index.files.length, 2);
    expect(index.totalBytes, 8);
  });

  test('a symlink is never followed, and never rides', () async {
    final outside = await Directory.systemTemp.createTemp('ws-index-out-');
    addTearDown(() async {
      try {
        await outside.delete(recursive: true);
      } catch (_) {}
    });
    await File(p.join(outside.path, 'secret.txt')).writeAsString('secret');
    await put('real.txt', 'real');
    var linked = true;
    try {
      await Link(
        p.join(root.path, 'link-to-outside'),
      ).create(outside.path, recursive: true);
      await Link(
        p.join(root.path, 'link-to-file'),
      ).create(p.join(outside.path, 'secret.txt'));
    } on FileSystemException {
      // Creating a symlink needs a privilege Windows does not grant by default
      // (developer mode); the prune rules above carry this test on such a host.
      linked = false;
    }

    final index = indexWorkspaceContentSync(root.path);

    expect(index.files.keys, ['real.txt']);
    if (linked) {
      expect(
        index.files.keys.any((path) => path.startsWith('link-to-outside')),
        isFalse,
        reason: 'following that link would index a directory outside the root',
      );
    }
  });

  test(
    'an unreadable subtree marks the whole index incomplete, not short',
    () async {
      // A root that cannot be listed at all (here: it is a file) is the shape
      // this flag exists for. What matters downstream is that the index is a
      // *subset* of the workspace: a table built from it would tell the peer
      // that every file it could not see had been deleted.
      final file = await put('not-a-directory.txt', 'x');

      final index = indexWorkspaceContentSync(file.path);

      expect(index.incomplete, isTrue);
      expect(index.files, isEmpty);
      expect(
        index.truncated,
        isFalse,
        reason: 'nothing was capped: the walk could not read at all',
      );
    },
  );

  test('a readable walk is not marked incomplete', () async {
    await put('good/a.txt', 'a');
    await put('also/b.txt', 'b');

    final index = indexWorkspaceContentSync(root.path);

    expect(index.files.keys, unorderedEquals(['good/a.txt', 'also/b.txt']));
    expect(index.incomplete, isFalse);
  });

  group('isSafeWorkspaceRelativePath', () {
    test('accepts ordinary nested and non-ASCII names', () {
      for (final path in [
        'a.txt',
        'src/lib/main.dart',
        'ünïcode/файл.md',
        'a..b',
        'com10',
        'dir with spaces/file name.txt',
      ]) {
        expect(isSafeWorkspaceRelativePath(path), isTrue, reason: path);
      }
    });

    test('refuses anything that could name a place outside the root', () {
      for (final path in [
        '',
        '../escape.txt',
        'a/../../b',
        '..',
        '.',
        './a',
        'a/./b',
        'a//b',
        'a/',
        '/etc/passwd',
        r'C:\Windows\system32\x',
        'C:/Windows/x',
        'a\\b',
        'a\u0000b',
        'stream:name',
        'trailing.',
        'trailing ',
        'CON',
        'con.txt',
        'nul.md',
        'COM1',
        'lpt9.log',
      ]) {
        expect(isSafeWorkspaceRelativePath(path), isFalse, reason: path);
      }
    });

    test('joins onto the root only when it stays inside it', () {
      final joined = workspacePathWithin(root.path, 'src/a.txt');
      expect(joined, isNotNull);
      expect(
        p.equals(joined!, p.canonicalize(p.join(root.path, 'src', 'a.txt'))),
        isTrue,
        reason: 'the safe path is the one the walk would have produced',
      );
      expect(workspacePathWithin(root.path, '../a.txt'), isNull);
      expect(workspacePathWithin(root.path, '/etc/passwd'), isNull);
      expect(workspacePathWithin(root.path, 'a/../../b'), isNull);
    });
  });
}
