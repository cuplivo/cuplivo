import 'dart:io';

import 'package:Cuplivo/utils/open_directory.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('directoryOpenCommandFor', () {
    test('windows opens with explorer using the plain path', () {
      const path = r'C:\Users\me\AppData\Roaming\Cuplivo\logs';
      final command = directoryOpenCommandFor(TargetPlatform.windows, path);
      expect(command?.$1, 'explorer');
      expect(command?.$2, [path]);
      // Regression guard for issue #789: never hand a file:/// URL to
      // url_launcher for a directory.
      expect(command!.$2.single.startsWith('file:'), isFalse);
    });

    test('windows normalizes forward slashes to backslashes', () {
      // Regression for issue #789: a path built as '...\\cuplivo/logs' made
      // explorer.exe open the wrong folder because it cannot resolve
      // forward-slash paths.
      final command = directoryOpenCommandFor(
        TargetPlatform.windows,
        'C:/Users/me/AppData/Roaming/com.psyche/cuplivo/logs',
      );
      expect(command?.$1, 'explorer');
      expect(command?.$2, [
        r'C:\Users\me\AppData\Roaming\com.psyche\cuplivo\logs',
      ]);
    });

    test('macOS opens with open', () {
      const path = '/Users/me/Library/Application Support/Cuplivo/logs';
      final command = directoryOpenCommandFor(TargetPlatform.macOS, path);
      expect(command?.$1, 'open');
      // POSIX separators must pass through untouched.
      expect(command?.$2, [path]);
    });

    test('linux opens with xdg-open', () {
      const path = '/home/me/.local/share/Cuplivo/logs';
      final command = directoryOpenCommandFor(TargetPlatform.linux, path);
      expect(command?.$1, 'xdg-open');
      expect(command?.$2, [path]);
    });

    test('non-desktop platforms have no directory opener', () {
      expect(
        directoryOpenCommandFor(TargetPlatform.android, '/data/logs'),
        isNull,
      );
      expect(directoryOpenCommandFor(TargetPlatform.iOS, '/data/logs'), isNull);
      expect(
        directoryOpenCommandFor(TargetPlatform.fuchsia, '/data/logs'),
        isNull,
      );
    });
  });

  group('openDirectoryInFileManager', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('throws FileSystemException when the directory is missing', () async {
      // Desktop platform override so command resolution succeeds; the missing
      // path must fail before any process is spawned (Windows detached
      // launches give no failure feedback otherwise).
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final missing = p.join(
        Directory.systemTemp.path,
        'cuplivo-missing-${DateTime.now().microsecondsSinceEpoch}',
      );
      expect(Directory(missing).existsSync(), isFalse);
      await expectLater(
        openDirectoryInFileManager(missing),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('throws UnsupportedError on mobile platforms', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await expectLater(
        openDirectoryInFileManager(Directory.systemTemp.path),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });
}
