import 'dart:io';

import 'package:Cuplivo/features/linux_sandbox/services/linux_sandbox_path.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('LinuxSandboxPath.guestSegments', () {
    test('accepts relative paths and strips dots', () {
      expect(LinuxSandboxPath.guestSegments('a/b/c.txt'), ['a', 'b', 'c.txt']);
      expect(LinuxSandboxPath.guestSegments('./a/./b'), ['a', 'b']);
      expect(LinuxSandboxPath.guestSegments(''), isEmpty);
      expect(LinuxSandboxPath.guestSegments('.'), isEmpty);
      expect(LinuxSandboxPath.guestSegments('/'), isEmpty);
    });

    test('accepts backslash separators as relative segments', () {
      expect(LinuxSandboxPath.guestSegments(r'a\b\c'), ['a', 'b', 'c']);
    });

    test('rejects path escape via ..', () {
      expect(
        () => LinuxSandboxPath.guestSegments('../etc/passwd'),
        throwsA(
          isA<LinuxSandboxPathException>().having(
            (e) => e.code,
            'code',
            'path_escape',
          ),
        ),
      );
      expect(
        () => LinuxSandboxPath.guestSegments('a/../../b'),
        throwsA(isA<LinuxSandboxPathException>()),
      );
    });

    test('rejects absolute host paths', () {
      expect(
        () => LinuxSandboxPath.guestSegments('/etc/passwd'),
        throwsA(
          isA<LinuxSandboxPathException>().having(
            (e) => e.code,
            'code',
            'absolute_path',
          ),
        ),
      );
      expect(
        () => LinuxSandboxPath.guestSegments(r'C:\Windows\System32'),
        throwsA(isA<LinuxSandboxPathException>()),
      );
      expect(
        () => LinuxSandboxPath.guestSegments(r'\\server\share'),
        throwsA(isA<LinuxSandboxPathException>()),
      );
    });

    test('rejects unsafe Win32 segments', () {
      expect(
        () => LinuxSandboxPath.guestSegments('foo...'),
        throwsA(isA<LinuxSandboxPathException>()),
      );
      expect(
        () => LinuxSandboxPath.guestSegments('foo.'),
        throwsA(isA<LinuxSandboxPathException>()),
      );
      expect(
        () => LinuxSandboxPath.guestSegments('foo '),
        throwsA(isA<LinuxSandboxPathException>()),
      );
    });
  });

  group('LinuxSandboxPath.joinGuest / isUnderRoot', () {
    test('joins under root and detects containment', () {
      final root = p.normalize('/tmp/jail');
      final joined = LinuxSandboxPath.joinGuest(root, 'a/b.txt');
      expect(LinuxSandboxPath.isUnderRoot(root, joined), isTrue);
      expect(LinuxSandboxPath.isUnderRoot(root, root), isTrue);
      expect(
        LinuxSandboxPath.isUnderRoot(root, p.normalize('/tmp/other')),
        isFalse,
      );
    });

    test('joinGuest rejects escapes before joining', () {
      expect(
        () => LinuxSandboxPath.joinGuest('/tmp/jail', '../x'),
        throwsA(isA<LinuxSandboxPathException>()),
      );
    });
  });

  group('LinuxSandboxPath.resolveHostPath', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('linux_sandbox_path_');
    });

    tearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('resolves nested file path under jail', () async {
      final jail = Directory(p.join(tmp.path, 'jail'));
      await jail.create(recursive: true);
      final file = File(p.join(jail.path, 'docs', 'a.txt'));
      await file.parent.create(recursive: true);
      await file.writeAsString('hi');

      final resolved = await LinuxSandboxPath.resolveHostPath(
        jailRoot: jail.path,
        guestPath: 'docs/a.txt',
      );
      expect(p.equals(resolved, p.normalize(file.path)), isTrue);
    });

    test('rejects symlink escape when links resolve outside', () async {
      if (Platform.isWindows) {
        // Creating symlinks may require elevation; skip when unsupported.
        try {
          final outside = Directory(p.join(tmp.path, 'outside'));
          await outside.create();
          final jail = Directory(p.join(tmp.path, 'jail'));
          await jail.create();
          final link = Link(p.join(jail.path, 'escape'));
          await link.create(outside.path);
        } catch (_) {
          return;
        }
      }

      final outside = Directory(p.join(tmp.path, 'outside'));
      await outside.create(recursive: true);
      final secret = File(p.join(outside.path, 'secret.txt'));
      await secret.writeAsString('nope');

      final jail = Directory(p.join(tmp.path, 'jail'));
      await jail.create(recursive: true);
      final link = Link(p.join(jail.path, 'escape'));
      try {
        await link.create(outside.path);
      } catch (_) {
        return;
      }

      await expectLater(
        LinuxSandboxPath.resolveHostPath(
          jailRoot: jail.path,
          guestPath: 'escape/secret.txt',
        ),
        throwsA(
          isA<LinuxSandboxPathException>().having(
            (e) => e.code,
            'code',
            'path_escape',
          ),
        ),
      );
    });
  });
}
