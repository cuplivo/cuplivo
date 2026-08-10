import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/mcp/kelivo_filesystem/kelivo_filesystem_server.dart';

Future<Map<String, dynamic>> callTool(
  KelivoFilesystemMcpServerEngine engine,
  String name,
  Map<String, dynamic> args,
) async {
  final resp = await engine.handleMessage({
    'jsonrpc': '2.0',
    'id': 1,
    'method': 'tools/call',
    'params': {'name': name, 'arguments': args},
  });
  return (resp as Map)['result'] as Map<String, dynamic>;
}

String textOf(Map<String, dynamic> result) {
  final content = result['content'] as List;
  return (content.first as Map)['text'] as String;
}

void main() {
  group('Filesystem wire format', () {
    final mounts = [
      const FilesystemMount(
        alias: 'workspaces',
        path: '/tmp/ws',
        readOnly: false,
      ),
      const FilesystemMount(alias: 'docs', path: '/tmp/docs', readOnly: true),
    ];

    test('resolves valid mount-relative paths', () {
      final r = resolveWirePath('@workspaces/a/b.txt', mounts);
      expect(r.mount.alias, 'workspaces');
      expect(r.segments, ['a', 'b.txt']);
      expect(r.isRoot, isFalse);
    });

    test('resolves mount root', () {
      final r = resolveWirePath('@docs', mounts);
      expect(r.isRoot, isTrue);
      expect(r.hostPath, '/tmp/docs');
    });

    test('rejects absolute paths', () {
      expect(
        () => resolveWirePath('/tmp/x', mounts),
        throwsA(isA<WirePathException>()),
      );
      expect(
        () => resolveWirePath('C:/x', mounts),
        throwsA(isA<WirePathException>()),
      );
    });

    test('rejects traversal and malformed segments', () {
      for (final bad in [
        '@workspaces/../x',
        '@workspaces/./x',
        '@workspaces//x',
        '@workspaces/a/',
        '@workspaces/a\\b',
        '@unknown/x',
        '@workspaces/a:b',
        // Win32 normalization hazards: trailing dots/spaces and all-dot
        // names resolve outside the mount on Windows.
        '@workspaces/.. ',
        '@workspaces/...',
        '@workspaces/.. .',
        '@workspaces/. ',
        '@workspaces/ ',
        '@workspaces/foo. ',
        '@workspaces/foo.',
        '@workspaces/foo ',
      ]) {
        expect(
          () => resolveWirePath(bad, mounts),
          throwsA(isA<WirePathException>()),
          reason: 'should reject: $bad',
        );
      }
    });

    test('isSafeWireSegment accepts ordinary names', () {
      for (final ok in ['a', 'a.txt', 'a..b', '.hidden', 'x y', 'z_1']) {
        expect(isSafeWireSegment(ok), isTrue, reason: ok);
      }
      for (final bad in [
        '',
        '.',
        '..',
        '...',
        '....',
        ' ',
        '  ',
        'a.',
        'a ',
        '.. ',
        '. ',
      ]) {
        expect(isSafeWireSegment(bad), isFalse, reason: 'should reject: $bad');
      }
    });
  });

  group('KelivoFilesystemMcpServerEngine', () {
    late Directory root;
    late Directory wsDir;
    late Directory docsDir;
    late List<FilesystemMount> mounts;
    final deleted = <String>[];
    late KelivoFilesystemMcpServerEngine engine;

    setUp(() {
      root = Directory.systemTemp.createTempSync('kelivo_fs_test_');
      wsDir = Directory('${root.path}/ws')..createSync();
      docsDir = Directory('${root.path}/docs')..createSync();
      mounts = [
        FilesystemMount(alias: 'workspaces', path: wsDir.path, readOnly: false),
        FilesystemMount(alias: 'docs', path: docsDir.path, readOnly: true),
      ];
      deleted.clear();
      engine = KelivoFilesystemMcpServerEngine(
        mountsProvider: () => mounts,
        onWorkspaceFileDeleted: (wirePath) async => deleted.add(wirePath),
      );
    });

    tearDown(() {
      engine.close();
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    String ws(String rel) => '@workspaces/$rel';

    test('read("/") lists mounts', () async {
      final r = await callTool(engine, 'kelivo_read', {'path': '/'});
      expect(r['isError'], false);
      final text = textOf(r);
      expect(text, contains('@workspaces (rw)'));
      expect(text, contains('@docs (ro)'));
      // Host paths never enter the model context (ADR-0022).
      expect(text, isNot(contains(wsDir.path)));
      expect(text, isNot(contains(docsDir.path)));
    });

    test('write_file creates a file, read returns numbered lines', () async {
      final w = await callTool(engine, 'kelivo_write_file', {
        'path': ws('notes/a.md'),
        'content': 'line one\nline two\nline three\n',
      });
      expect(w['isError'], false);
      expect(File('${wsDir.path}/notes/a.md').existsSync(), isTrue);

      final r = await callTool(engine, 'kelivo_read', {
        'path': ws('notes/a.md'),
      });
      expect(r['isError'], false);
      final text = textOf(r);
      expect(text, contains('1: line one'));
      expect(text, contains('3: line three'));
    });

    test('read rejects binary files', () async {
      File('${wsDir.path}/bin.dat').writeAsBytesSync([1, 2, 0, 3, 4]);
      final r = await callTool(engine, 'kelivo_read', {'path': ws('bin.dat')});
      expect(r['isError'], true);
      expect(textOf(r), contains('Binary'));
    });

    test('read paginates with start_line', () async {
      final content = List.generate(5000, (i) => 'line ${i + 1}').join('\n');
      File('${wsDir.path}/big.txt').writeAsStringSync(content);
      final r = await callTool(engine, 'kelivo_read', {'path': ws('big.txt')});
      final text = textOf(r);
      expect(r['isError'], false);
      expect(text, contains('1: line 1'));
      expect(text, contains('start_line='));

      final r2 = await callTool(engine, 'kelivo_read', {
        'path': ws('big.txt'),
        'start_line': 1500,
      });
      final text2 = textOf(r2);
      expect(text2, contains('1500: line 1500'));
    });

    test('write_file on read-only mount fails', () async {
      final r = await callTool(engine, 'kelivo_write_file', {
        'path': '@docs/x.txt',
        'content': 'hi',
      });
      expect(r['isError'], true);
      expect(textOf(r), contains('read-only'));
    });

    test('patch_file replaces first occurrence', () async {
      File('${wsDir.path}/p.txt').writeAsStringSync('aaa bbb aaa');
      final r = await callTool(engine, 'kelivo_patch_file', {
        'path': ws('p.txt'),
        'old_string': 'aaa',
        'new_string': 'zzz',
      });
      expect(r['isError'], false);
      expect(File('${wsDir.path}/p.txt').readAsStringSync(), 'zzz bbb aaa');

      final miss = await callTool(engine, 'kelivo_patch_file', {
        'path': ws('p.txt'),
        'old_string': 'nope',
        'new_string': 'x',
      });
      expect(miss['isError'], true);
    });

    test('delete file records workspaceFile marker', () async {
      File('${wsDir.path}/del.txt').writeAsStringSync('x');
      final r = await callTool(engine, 'kelivo_delete', {
        'path': ws('del.txt'),
      });
      expect(r['isError'], false);
      expect(File('${wsDir.path}/del.txt').existsSync(), isFalse);
      expect(deleted, contains('@workspaces/del.txt'));
    });

    test('delete on a read-only mount fails with read-only error', () async {
      File('${docsDir.path}/keep.txt').writeAsStringSync('x');
      final r = await callTool(engine, 'kelivo_delete', {
        'path': '@docs/keep.txt',
      });
      expect(r['isError'], true);
      expect(textOf(r), contains('read-only'));
      expect(File('${docsDir.path}/keep.txt').existsSync(), isTrue);
      expect(deleted, isEmpty);
    });

    test('delete mount root is rejected', () async {
      final r = await callTool(engine, 'kelivo_delete', {
        'path': '@workspaces',
      });
      expect(r['isError'], true);
      expect(textOf(r), contains('mount root'));
    });

    test('delete non-empty dir requires recursive', () async {
      Directory('${wsDir.path}/d').createSync();
      File('${wsDir.path}/d/f').writeAsStringSync('x');
      final r = await callTool(engine, 'kelivo_delete', {'path': ws('d')});
      expect(r['isError'], true);
      expect(textOf(r), contains('recursive'));

      final r2 = await callTool(engine, 'kelivo_delete', {
        'path': ws('d'),
        'recursive': true,
      });
      expect(r2['isError'], false);
      expect(Directory('${wsDir.path}/d').existsSync(), isFalse);
      // A recursive directory deletion propagates as a single directory mark
      // (peers apply it as a user-confirmed recursive local delete).
      expect(deleted, contains('@workspaces/d'));
    });

    test('delete inside dot-prefixed paths records no marker', () async {
      Directory('${wsDir.path}/.fetch_cache').createSync();
      File('${wsDir.path}/.fetch_cache/cache.bin').writeAsStringSync('x');
      final r = await callTool(engine, 'kelivo_delete', {
        'path': ws('.fetch_cache/cache.bin'),
      });
      expect(r['isError'], false);
      // Never-synced content must not produce markers (ADR-0021).
      expect(deleted, isEmpty);
    });

    test(
      'move of a directory out of workspaces records a directory mark',
      () async {
        mounts[1] = FilesystemMount(
          alias: 'docs',
          path: docsDir.path,
          readOnly: false,
        );
        Directory('${wsDir.path}/proj').createSync();
        File('${wsDir.path}/proj/a.txt').writeAsStringSync('x');
        final r = await callTool(engine, 'kelivo_move', {
          'source': ws('proj'),
          'destination': '@docs/proj',
        });
        expect(r['isError'], false);
        expect(Directory('${docsDir.path}/proj').existsSync(), isTrue);
        expect(deleted, contains('@workspaces/proj'));
      },
    );

    test('glob matches patterns and skips dotfiles', () async {
      Directory('${wsDir.path}/src').createSync();
      Directory('${wsDir.path}/src/.dir').createSync();
      File('${wsDir.path}/src/a.dart').writeAsStringSync('');
      File('${wsDir.path}/src/b.md').writeAsStringSync('');
      File('${wsDir.path}/src/.hidden').writeAsStringSync('');
      File('${wsDir.path}/src/.dir/h.txt').writeAsStringSync('');

      final r = await callTool(engine, 'kelivo_glob', {
        'path': '@workspaces',
        'pattern': 'src/**/*.dart',
      });
      expect(r['isError'], false);
      final text = textOf(r);
      expect(text, contains('@workspaces/src/a.dart'));
      expect(text, isNot(contains('.hidden')));
      expect(text, isNot(contains('.dir')));

      final all = await callTool(engine, 'kelivo_glob', {
        'path': '@workspaces',
        'pattern': '**/*.md',
      });
      expect(textOf(all), contains('@workspaces/src/b.md'));
    });

    test('grep matches with line numbers and skips binary', () async {
      File(
        '${wsDir.path}/g.txt',
      ).writeAsStringSync('alpha\nbeta gamma\nalpha again\n');
      File('${wsDir.path}/bin.dat').writeAsBytesSync([1, 2, 0, 3]);
      final r = await callTool(engine, 'kelivo_grep', {
        'path': '@workspaces',
        'regex': r'alpha',
      });
      expect(r['isError'], false);
      final text = textOf(r);
      expect(text, contains('@workspaces/g.txt:1: alpha'));
      expect(text, contains('@workspaces/g.txt:3: alpha again'));
      expect(text, isNot(contains('bin.dat')));
    });

    test('grep result paths keep the searched subdirectory', () async {
      Directory('${wsDir.path}/src/nested').createSync(recursive: true);
      File('${wsDir.path}/src/nested/hit.txt').writeAsStringSync('needle here');
      final r = await callTool(engine, 'kelivo_grep', {
        'path': '@workspaces/src',
        'regex': r'needle',
      });
      expect(r['isError'], false);
      final text = textOf(r);
      // The result path must be the full searchable path, not just @workspaces.
      expect(text, contains('@workspaces/src/nested/hit.txt:1: needle here'));
      expect(text, isNot(contains('@workspaces/nested/hit.txt')));
    });

    test('mkdir recursive and non-recursive', () async {
      final nr = await callTool(engine, 'kelivo_mkdir', {'path': ws('a/b')});
      expect(nr['isError'], true);

      final r = await callTool(engine, 'kelivo_mkdir', {
        'path': ws('a/b'),
        'recursive': true,
      });
      expect(r['isError'], false);
      expect(Directory('${wsDir.path}/a/b').existsSync(), isTrue);
    });

    test('move within mount, rejects existing destination', () async {
      File('${wsDir.path}/m.txt').writeAsStringSync('x');
      File('${wsDir.path}/exists.txt').writeAsStringSync('y');

      final dup = await callTool(engine, 'kelivo_move', {
        'source': ws('m.txt'),
        'destination': ws('exists.txt'),
      });
      expect(dup['isError'], true);
      expect(textOf(dup), contains('already exists'));

      final r = await callTool(engine, 'kelivo_move', {
        'source': ws('m.txt'),
        'destination': ws('sub/m.txt'),
      });
      expect(r['isError'], false);
      expect(File('${wsDir.path}/m.txt').existsSync(), isFalse);
      expect(File('${wsDir.path}/sub/m.txt').existsSync(), isTrue);
      // Source deletion inside @workspaces records a marker.
      expect(deleted, contains('@workspaces/m.txt'));
    });

    test('move into a read-only mount fails', () async {
      File('${wsDir.path}/x.txt').writeAsStringSync('data');
      final r = await callTool(engine, 'kelivo_move', {
        'source': ws('x.txt'),
        'destination': '@docs/x.txt',
      });
      expect(r['isError'], true);
      expect(textOf(r), contains('read-only'));
      expect(File('${wsDir.path}/x.txt').existsSync(), isTrue);
      expect(File('${docsDir.path}/x.txt').existsSync(), isFalse);
      expect(deleted, isEmpty);
    });

    test('move across mounts works (copy + delete)', () async {
      // docs is ro by default — make it rw for this cross-mount move.
      mounts[1] = FilesystemMount(
        alias: 'docs',
        path: docsDir.path,
        readOnly: false,
      );
      File('${wsDir.path}/x.txt').writeAsStringSync('data');
      final r = await callTool(engine, 'kelivo_move', {
        'source': ws('x.txt'),
        'destination': '@docs/x.txt',
      });
      expect(r['isError'], false);
      expect(File('${wsDir.path}/x.txt').existsSync(), isFalse);
      expect(File('${docsDir.path}/x.txt').existsSync(), isTrue);
      // Target outside workspaces preserves mtime; source marker recorded.
      expect(deleted, contains('@workspaces/x.txt'));
    });

    test('move into workspaces sets mtime to now', () async {
      mounts[1] = FilesystemMount(
        alias: 'docs',
        path: docsDir.path,
        readOnly: false,
      );
      final src = File('${docsDir.path}/y.txt')
        ..writeAsStringSync('data')
        ..setLastModifiedSync(DateTime(2020, 1, 1));
      final r = await callTool(engine, 'kelivo_move', {
        'source': '@docs/y.txt',
        'destination': ws('y.txt'),
      });
      expect(r['isError'], false);
      final target = File('${wsDir.path}/y.txt');
      expect(target.existsSync(), isTrue);
      expect(
        target.lastModifiedSync().difference(DateTime.now()).abs().inMinutes,
        lessThan(2),
      );
      expect(src.existsSync(), isFalse);
    });

    test('same-mount directory move bumps child mtimes to now (incremental '
        'backup visibility)', () async {
      Directory('${wsDir.path}/old/deep').createSync(recursive: true);
      final child = File('${wsDir.path}/old/deep/child.txt')
        ..writeAsStringSync('x')
        ..setLastModifiedSync(DateTime(2020, 1, 1));

      final r = await callTool(engine, 'kelivo_move', {
        'source': ws('old'),
        'destination': ws('new'),
      });
      expect(r['isError'], false);
      expect(File('${wsDir.path}/old').existsSync(), isFalse);
      final moved = File('${wsDir.path}/new/deep/child.txt');
      expect(moved.existsSync(), isTrue);
      expect(
        moved.lastModifiedSync().difference(DateTime.now()).abs().inMinutes,
        lessThan(2),
        reason: 'moved children must be visible to since-filtered backups',
      );
      expect(child.existsSync(), isFalse);
    });

    test('zip and unzip round-trip with mtime', () async {
      Directory('${wsDir.path}/z').createSync();
      File('${wsDir.path}/z/a.txt').writeAsStringSync('hello');
      File('${wsDir.path}/z/b.txt').writeAsStringSync('world');

      final z = await callTool(engine, 'kelivo_zip', {
        'source': ws('z'),
        'destination': ws('z.zip'),
      });
      expect(z['isError'], false);
      expect(File('${wsDir.path}/z.zip').existsSync(), isTrue);

      final u = await callTool(engine, 'kelivo_unzip', {
        'source': ws('z.zip'),
        'destination': ws('out'),
      });
      expect(u['isError'], false);
      expect(File('${wsDir.path}/out/a.txt').readAsStringSync(), 'hello');
      expect(File('${wsDir.path}/out/b.txt').readAsStringSync(), 'world');
    });

    test('unzip into workspaces bumps entry mtimes to now', () async {
      Directory('${wsDir.path}/z2').createSync();
      final archived = File('${wsDir.path}/z2/old.txt')
        ..writeAsStringSync('x')
        ..setLastModifiedSync(DateTime(2020, 1, 1));
      final z = await callTool(engine, 'kelivo_zip', {
        'source': ws('z2'),
        'destination': ws('z2.zip'),
      });
      expect(z['isError'], false);

      final u = await callTool(engine, 'kelivo_unzip', {
        'source': ws('z2.zip'),
        'destination': ws('out2'),
      });
      expect(u['isError'], false);
      final extracted = File('${wsDir.path}/out2/old.txt');
      expect(extracted.existsSync(), isTrue);
      expect(
        extracted.lastModifiedSync().difference(DateTime.now()).abs().inMinutes,
        lessThan(2),
        reason: 'extracted content must be visible to since-filtered backups',
      );
      expect(archived.existsSync(), isTrue);
    });

    test(
      'recursive scans skip symlinks (no cycles, no boundary escape)',
      () async {
        // Symlink creation needs privileges on Windows — skip silently when
        // the platform refuses.
        final outside = File('${root.path}/outside.txt')
          ..writeAsStringSync('s');
        Directory('${wsDir.path}/tree').createSync();
        File('${wsDir.path}/tree/real.txt').writeAsStringSync('r');
        try {
          Link('${wsDir.path}/tree/cycle').createSync('${wsDir.path}/tree');
          Link('${wsDir.path}/tree/escape').createSync(outside.path);
        } catch (_) {
          return; // symlinks unsupported (Windows without developer mode)
        }

        // glob terminates (would hang forever if the cycle were followed).
        final g = await callTool(engine, 'kelivo_glob', {
          'path': '@workspaces',
          'pattern': '**/*',
        });
        expect(g['isError'], false);
        final globText = textOf(g);
        expect(globText, contains('@workspaces/tree/real.txt'));
        // Links themselves are skipped entirely.
        expect(globText, isNot(contains('cycle')));
        expect(globText, isNot(contains('escape')));
        expect(globText, isNot(contains('outside.txt')));

        // zip must not pack the escaped target either.
        final z = await callTool(engine, 'kelivo_zip', {
          'source': ws('tree'),
          'destination': ws('tree.zip'),
        });
        expect(z['isError'], false);
        final u = await callTool(engine, 'kelivo_unzip', {
          'source': ws('tree.zip'),
          'destination': ws('tree_out'),
        });
        expect(u['isError'], false);
        expect(File('${wsDir.path}/tree_out/real.txt').existsSync(), isTrue);
        expect(
          File('${wsDir.path}/tree_out/outside.txt').existsSync(),
          isFalse,
        );
      },
    );

    test('unzip rejects zip-slip entries', () async {
      // Build a malicious zip by hand: entry "../evil.txt".
      final zipPath = '${wsDir.path}/evil.zip';
      final encoder = ZipFileEncoder();
      encoder.create(zipPath);
      final evil = File('${root.path}/evil_payload.txt')
        ..writeAsStringSync('x');
      encoder.addFileSync(evil, '../evil.txt');
      encoder.closeSync();

      final r = await callTool(engine, 'kelivo_unzip', {
        'source': ws('evil.zip'),
        'destination': ws('out2'),
      });
      expect(r['isError'], true);
      expect(textOf(r), contains('Unsafe zip entry'));
    });

    test('unzip rejects Win32 trailing-space traversal entries', () async {
      // `.. ` (trailing space) normalizes to `..` on Windows — same escape.
      final zipPath = '${wsDir.path}/evil2.zip';
      final encoder = ZipFileEncoder();
      encoder.create(zipPath);
      final evil = File('${root.path}/evil2_payload.txt')
        ..writeAsStringSync('x');
      encoder.addFileSync(evil, '.. ');
      encoder.closeSync();

      final r = await callTool(engine, 'kelivo_unzip', {
        'source': ws('evil2.zip'),
        'destination': ws('out3'),
      });
      expect(r['isError'], true);
      expect(textOf(r), contains('Unsafe zip entry'));
    });

    test('tools/list advertises the 11 tool definitions', () async {
      final resp = await engine.handleMessage({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/list',
      });
      final tools = (resp as Map)['result']['tools'] as List;
      final names = tools.map((t) => (t as Map)['name']).toSet();
      expect(
        names,
        containsAll([
          'kelivo_read',
          'kelivo_write_file',
          'kelivo_patch_file',
          'kelivo_delete',
          'kelivo_glob',
          'kelivo_grep',
          'kelivo_outline',
          'kelivo_mkdir',
          'kelivo_move',
          'kelivo_zip',
          'kelivo_unzip',
        ]),
      );
    });

    test('read tolerates a single trailing slash (directory intent)', () async {
      Directory('${wsDir.path}/notes').createSync();
      File('${wsDir.path}/notes/a.md').writeAsStringSync('hello');
      final r = await callTool(engine, 'kelivo_read', {
        'path': '@workspaces/notes/',
      });
      expect(r['isError'], false);
      expect(textOf(r), contains('a.md'));

      final root = await callTool(engine, 'kelivo_read', {
        'path': '@workspaces/',
      });
      expect(root['isError'], false);
      expect(textOf(root), contains('notes'));
    });

    test(
      'trailing slash tolerance is read-only — other tools stay strict',
      () async {
        final w = await callTool(engine, 'kelivo_write_file', {
          'path': '@workspaces/x/',
          'content': 'hi',
        });
        expect(w['isError'], true);
        expect(textOf(w), contains('trailing slash'));

        final d = await callTool(engine, 'kelivo_delete', {
          'path': '@workspaces/x/',
        });
        expect(d['isError'], true);
        expect(textOf(d), contains('trailing slash'));
      },
    );

    test(
      'grep paginates with offset/limit and reports the next offset',
      () async {
        File('${wsDir.path}/many.txt').writeAsStringSync(
          List.generate(250, (i) => 'hit line ${i + 1}').join('\n'),
        );
        final page1 = await callTool(engine, 'kelivo_grep', {
          'path': '@workspaces',
          'regex': r'hit',
        });
        expect(page1['isError'], false);
        final text1 = textOf(page1);
        expect(text1, contains('many.txt:1: hit line 1'));
        expect(text1, isNot(contains('many.txt:101: hit line 101')));
        expect(text1, contains('offset=100'));

        final page2 = await callTool(engine, 'kelivo_grep', {
          'path': '@workspaces',
          'regex': r'hit',
          'offset': 100,
        });
        final text2 = textOf(page2);
        expect(text2, contains('many.txt:101: hit line 101'));
        expect(text2, isNot(contains('many.txt:1: hit line 1')));
        expect(text2, contains('offset=200'));

        final last = await callTool(engine, 'kelivo_grep', {
          'path': '@workspaces',
          'regex': r'hit',
          'offset': 200,
        });
        final textLast = textOf(last);
        expect(textLast, contains('many.txt:250: hit line 250'));
        expect(textLast, isNot(contains('truncated')));
      },
    );

    test('grep validates pagination and context bounds', () async {
      final badLimit = await callTool(engine, 'kelivo_grep', {
        'path': '@workspaces',
        'regex': r'x',
        'limit': 501,
      });
      expect(badLimit['isError'], true);

      final badOffset = await callTool(engine, 'kelivo_grep', {
        'path': '@workspaces',
        'regex': r'x',
        'offset': -1,
      });
      expect(badOffset['isError'], true);

      final badContext = await callTool(engine, 'kelivo_grep', {
        'path': '@workspaces',
        'regex': r'x',
        'before_context': 6,
      });
      expect(badContext['isError'], true);
    });

    test(
      'grep context lines use rg markers and dedupe overlapping windows',
      () async {
        File(
          '${wsDir.path}/ctx.txt',
        ).writeAsStringSync('a\nb\ntarget1\nc\nd\ne\ntarget2\nf\ng\n');
        final r = await callTool(engine, 'kelivo_grep', {
          'path': '@workspaces',
          'regex': r'target',
          'before_context': 2,
          'after_context': 1,
        });
        expect(r['isError'], false);
        final text = textOf(r);
        // Match lines use `:`, context lines use `-`.
        expect(text, contains('ctx.txt:1-a'));
        expect(text, contains('ctx.txt:3: target1'));
        expect(text, contains('ctx.txt:4-c'));
        // Overlapping windows merge: line 6 ('e') sits in the gap between the
        // two windows and is emitted exactly once.
        expect('ctx.txt:6-e'.allMatches(text).length, 1);
        expect(text, contains('ctx.txt:7: target2'));
        expect(text, contains('ctx.txt:8-f'));
      },
    );

    test('grep context lines count into the pagination window', () async {
      File(
        '${wsDir.path}/pg.txt',
      ).writeAsStringSync(List.generate(60, (i) => 'x line $i').join('\n'));
      final r = await callTool(engine, 'kelivo_grep', {
        'path': '@workspaces',
        'regex': r'x line (0|20|40)$',
        'before_context': 1,
        'after_context': 1,
        'limit': 5,
      });
      expect(r['isError'], false);
      final text = textOf(r);
      // Window = 5 result lines: match 0 (3 lines) + the first 2 lines of
      // match 20's window — the third window is cut off, so a truncation
      // hint appears and the last match is absent.
      expect(text, contains('truncated'));
      expect(text, contains('x line 0'));
      expect(text, isNot(contains('x line 40')));
    });

    test('grep truncation hint only fires when more results exist', () async {
      // Exactly limit results: the sentinel probe must suppress the hint.
      File(
        '${wsDir.path}/exact.txt',
      ).writeAsStringSync(List.generate(100, (i) => 'needle $i').join('\n'));
      final exact = await callTool(engine, 'kelivo_grep', {
        'path': '@workspaces',
        'regex': r'needle',
      });
      expect(exact['isError'], false);
      expect(textOf(exact), isNot(contains('truncated')));
      expect(textOf(exact), contains('needle 99'));

      // One past the limit: the hint appears.
      File(
        '${wsDir.path}/over.txt',
      ).writeAsStringSync(List.generate(101, (i) => 'needle $i').join('\n'));
      final over = await callTool(engine, 'kelivo_grep', {
        'path': '@workspaces',
        'regex': r'needle',
      });
      expect(over['isError'], false);
      expect(textOf(over), contains('truncated'));
      expect(textOf(over), contains('offset=100'));
    });

    test('grep order is deterministic across calls', () async {
      Directory('${wsDir.path}/d1').createSync();
      Directory('${wsDir.path}/d2').createSync();
      File('${wsDir.path}/d2/b.txt').writeAsStringSync('hit\n' * 3);
      File('${wsDir.path}/d1/a.txt').writeAsStringSync('hit\n' * 3);
      final r1 = await callTool(engine, 'kelivo_grep', {
        'path': '@workspaces',
        'regex': r'hit',
        'offset': 2,
      });
      final r2 = await callTool(engine, 'kelivo_grep', {
        'path': '@workspaces',
        'regex': r'hit',
        'offset': 2,
      });
      expect(textOf(r1), textOf(r2));
      // Deterministic walk order: directories first, then by lowercase
      // name — d1's file precedes d2's file.
      final r3 = await callTool(engine, 'kelivo_grep', {
        'path': '@workspaces',
        'regex': r'hit',
        'limit': 2,
      });
      expect(textOf(r3), contains('d1/a.txt'));
    });

    test('outline lists types and functions indented by depth', () async {
      File('${wsDir.path}/app.dart').writeAsStringSync(
        'class App {\n'
        '  App() {\n'
        '    helper();\n'
        '  }\n'
        '\n'
        '  void build(int x) {\n'
        '    if (x > 1) {\n'
        '      return;\n'
        '    }\n'
        '    inner();\n'
        '  }\n'
        '}\n'
        '\n'
        'String helper() {\n'
        "  return 'ok';\n"
        '}\n',
      );
      final r = await callTool(engine, 'kelivo_outline', {
        'path': ws('app.dart'),
      });
      expect(r['isError'], false);
      final text = textOf(r);
      expect(text, contains('(4 symbols)'));
      // The header is its own line — the first symbol must not be glued to
      // the "symbols):" line.
      expect(text, contains('symbols):\nclass App (1)'));
      expect(text, contains('  App (2)'));
      expect(text, contains('  build (6)'));
      expect(text, contains('helper (14)'));
      // Control statements are not symbols.
      expect(text, isNot(contains('if (')));
    });

    test(
      'outline rejects binary, unsupported extensions, and missing files',
      () async {
        // The extension check runs BEFORE the read: unknown extensions are
        // rejected without reading; binary rejection applies to supported
        // extensions only.
        File('${wsDir.path}/bin.dart').writeAsBytesSync([1, 2, 0, 3]);
        final b = await callTool(engine, 'kelivo_outline', {
          'path': ws('bin.dart'),
        });
        expect(b['isError'], true);
        expect(textOf(b), contains('Binary'));

        File('${wsDir.path}/bin.dat').writeAsBytesSync([1, 2, 0, 3]);
        final b2 = await callTool(engine, 'kelivo_outline', {
          'path': ws('bin.dat'),
        });
        expect(b2['isError'], true);
        expect(textOf(b2), contains('Unsupported'));

        File('${wsDir.path}/data.xyz').writeAsStringSync('x');
        final u = await callTool(engine, 'kelivo_outline', {
          'path': ws('data.xyz'),
        });
        expect(u['isError'], true);
        expect(textOf(u), contains('Unsupported'));

        final m = await callTool(engine, 'kelivo_outline', {
          'path': ws('missing.dart'),
        });
        expect(m['isError'], true);
        expect(textOf(m), contains('Not found'));
      },
    );

    test('outline supports python indentation nesting', () async {
      File('${wsDir.path}/mod.py').writeAsStringSync(
        'def top():\n'
        '    def nested():\n'
        '        pass\n'
        'class Klass:\n'
        '    def method(self):\n'
        '        pass\n',
      );
      final r = await callTool(engine, 'kelivo_outline', {
        'path': ws('mod.py'),
      });
      expect(r['isError'], false);
      final text = textOf(r);
      expect(text, contains('def top (1)'));
      expect(text, contains('  def nested (2)'));
      expect(text, contains('class Klass (4)'));
      expect(text, contains('  def method (5)'));
    });

    test('outline caps at 200 symbols with a truncation hint', () async {
      final content = StringBuffer();
      for (var i = 0; i < 250; i++) {
        content.writeln('void fn$i() {}');
      }
      File('${wsDir.path}/huge.dart').writeAsStringSync(content.toString());
      final r = await callTool(engine, 'kelivo_outline', {
        'path': ws('huge.dart'),
      });
      expect(r['isError'], false);
      final text = textOf(r);
      expect(text, contains('(200 symbols)'));
      expect(text, contains('cap 200'));
      expect(text, isNot(contains('fn249')));
    });

    test(
      'outline supports Go receiver methods and type declarations',
      () async {
        File('${wsDir.path}/srv.go').writeAsStringSync(
          'package main\n'
          '\n'
          'type Server struct {\n'
          '}\n'
          '\n'
          'func (s *Server) Handle() error {\n'
          '\treturn nil\n'
          '}\n'
          '\n'
          'func helper() int {\n'
          '\treturn 0\n'
          '}\n',
        );
        final r = await callTool(engine, 'kelivo_outline', {
          'path': ws('srv.go'),
        });
        expect(r['isError'], false);
        final text = textOf(r);
        expect(text, contains('type Server (3)'));
        expect(text, contains('func Handle (6)'));
        expect(text, contains('func helper (10)'));
      },
    );

    test(
      'outline captures async/noexcept/const-trailing method forms',
      () async {
        File('${wsDir.path}/async.dart').writeAsStringSync(
          'class Loader {\n'
          '  Future<void> load() async {\n'
          '    await Future.delayed(Duration.zero);\n'
          '  }\n'
          '\n'
          '  String get() const {\n'
          '    return "";\n'
          '  }\n'
          '}\n',
        );
        final r = await callTool(engine, 'kelivo_outline', {
          'path': ws('async.dart'),
        });
        expect(r['isError'], false);
        final text = textOf(r);
        expect(text, contains('class Loader (1)'));
        expect(text, contains('  load (2)'));
        expect(text, contains('  get (6)'));

        File('${wsDir.path}/n.cc').writeAsStringSync(
          'void run() noexcept {\n'
          '  work();\n'
          '}\n'
          'int maybe() noexcept(true) {\n'
          '  return 1;\n'
          '}\n',
        );
        final r2 = await callTool(engine, 'kelivo_outline', {
          'path': ws('n.cc'),
        });
        expect(r2['isError'], false);
        final text2 = textOf(r2);
        expect(text2, contains('run (1)'));
        expect(text2, contains('maybe (4)'));
      },
    );

    test('outline excludes synchronized/lock statements', () async {
      File('${wsDir.path}/locker.java').writeAsStringSync(
        'class Locker {\n'
        '  void run() {\n'
        '    synchronized (lockObj) {\n'
        '      work();\n'
        '    }\n'
        '    lock (m) {\n'
        '      work2();\n'
        '    }\n'
        '  }\n'
        '}\n',
      );
      final r = await callTool(engine, 'kelivo_outline', {
        'path': ws('locker.java'),
      });
      expect(r['isError'], false);
      final text = textOf(r);
      expect(text, contains('class Locker (1)'));
      expect(text, contains('  run (2)'));
      expect(text, isNot(contains('synchronized')));
      expect(text, isNot(contains('lock (')));
    });

    test('read truncates an over-budget single line', () async {
      // 64 KB single line, no newline — must not blow the 32 KB budget.
      File('${wsDir.path}/min.js').writeAsStringSync('x' * (64 * 1024));
      final r = await callTool(engine, 'kelivo_read', {'path': ws('min.js')});
      expect(r['isError'], false);
      final text = textOf(r);
      expect(text.length, lessThan(64 * 1024));
      expect(text, contains('1: '));
      expect(text, contains('truncated'));
    });

    test('grep and read reject non-integer numeric args', () async {
      final badLimit = await callTool(engine, 'kelivo_grep', {
        'path': '@workspaces',
        'regex': r'x',
        'limit': '10',
      });
      expect(badLimit['isError'], true);
      expect(textOf(badLimit), contains('expected an integer'));

      final badOffset = await callTool(engine, 'kelivo_grep', {
        'path': '@workspaces',
        'regex': r'x',
        'offset': 1.5,
      });
      expect(badOffset['isError'], true);

      File('${wsDir.path}/a.txt').writeAsStringSync('x');
      final badStart = await callTool(engine, 'kelivo_read', {
        'path': ws('a.txt'),
        'start_line': 'abc',
      });
      expect(badStart['isError'], true);
      expect(textOf(badStart), contains('expected an integer'));

      // start_line validation applies to directories too — never silently
      // ignored.
      Directory('${wsDir.path}/adir').createSync();
      final dirStart = await callTool(engine, 'kelivo_read', {
        'path': ws('adir'),
        'start_line': 'abc',
      });
      expect(dirStart['isError'], true);
      expect(textOf(dirStart), contains('expected an integer'));
    });

    test(
      'outline truncation hint only fires when symbols were dropped',
      () async {
        final content = StringBuffer();
        for (var i = 0; i < 200; i++) {
          content.writeln('void fn$i() {}');
        }
        File('${wsDir.path}/exact.dart').writeAsStringSync(content.toString());
        final r = await callTool(engine, 'kelivo_outline', {
          'path': ws('exact.dart'),
        });
        expect(r['isError'], false);
        final text = textOf(r);
        expect(text, contains('(200 symbols)'));
        expect(text, isNot(contains('cap 200')));
        expect(text, contains('fn199'));
      },
    );
  });
}
