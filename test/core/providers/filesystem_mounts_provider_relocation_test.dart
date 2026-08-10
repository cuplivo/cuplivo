import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/filesystem_mounts_provider.dart';
import 'package:Cuplivo/core/services/mcp/kelivo_filesystem/kelivo_filesystem_server.dart';
import 'package:Cuplivo/utils/app_directories.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.supportPath, this.documentsPath);

  final String supportPath;
  final String documentsPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String support;
  late String docs;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('kelivo_reloc_test_');
    support = '${tmp.path}/support';
    docs = '${tmp.path}/documents';
    Directory(support).createSync();
    Directory(docs).createSync();
    PathProviderPlatform.instance = _FakePathProviderPlatform(support, docs);
    SharedPreferences.setMockInitialValues({});
    // Relocation is a desktop feature: force the desktop target so the
    // workspaces_dir_v1 pref is honored and the support dir is used.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<FilesystemMountsProvider> makeProvider() async {
    final provider = FilesystemMountsProvider();
    await provider.init();
    return provider;
  }

  group('AppDirectories path helpers', () {
    test('root parents match children (drive root / POSIX root)', () {
      expect(AppDirectories.isPathInside('C:/appdata/x', 'C:/'), isTrue);
      expect(AppDirectories.isPathInside('/appdata/x', '/'), isTrue);
      expect(AppDirectories.isPathInside('C:/appdata2', 'C:/appdata'), isFalse);
      expect(AppDirectories.isPathInside('C:/', 'C:/appdata'), isFalse);
      expect(AppDirectories.pathsOverlap('C:/', 'C:/appdata/upload'), isTrue);
      expect(AppDirectories.pathsOverlap('D:/', 'C:/appdata/upload'), isFalse);
    });

    test('isFilesystemRootPath recognizes roots in both canonical forms', () {
      // 'C:/' — the Windows-normalized drive root (trailing slash kept).
      // 'C:'  — the same path after POSIX normalization (slash stripped).
      // The load-time guard must reject both or a restored pref slips
      // through on the other platform.
      expect(AppDirectories.isFilesystemRootPath('C:/'), isTrue);
      expect(AppDirectories.isFilesystemRootPath('C:'), isTrue);
      expect(AppDirectories.isFilesystemRootPath('c:'), isTrue);
      expect(AppDirectories.isFilesystemRootPath('/'), isTrue);
      expect(AppDirectories.isFilesystemRootPath('C:/Users'), isFalse);
      expect(AppDirectories.isFilesystemRootPath('/tmp/x'), isFalse);
    });
  });

  group('setWorkspacesLocation validation', () {
    test(
      'relocating to the app-data root (contains the sandbox) is rejected',
      () async {
        final provider = await makeProvider();
        final err = await provider.setWorkspacesLocation(
          support,
          moveFiles: false,
        );
        expect(err, FilesystemMountsProvider.errorSyncOverlap);
      },
    );

    test('relocating into a sync tree (upload) is rejected', () async {
      final provider = await makeProvider();
      final err = await provider.setWorkspacesLocation(
        '$support/upload',
        moveFiles: false,
      );
      expect(err, FilesystemMountsProvider.errorSyncOverlap);
    });

    test('relocating inside the current sandbox is rejected', () async {
      final provider = await makeProvider();
      final err = await provider.setWorkspacesLocation(
        '$support/workspaces/sub',
        moveFiles: false,
      );
      expect(err, FilesystemMountsProvider.errorInsideWorkspaces);
    });

    test('relocating to the same path is a no-op success', () async {
      final provider = await makeProvider();
      final err = await provider.setWorkspacesLocation(
        '$support/workspaces',
        moveFiles: true,
      );
      expect(err, isNull);
    });

    test(
      'relocating to a folder containing an external mount is rejected',
      () async {
        final provider = await makeProvider();
        final mountRoot = Directory('${tmp.path}/data/photos')
          ..createSync(recursive: true);
        final addErr = await provider.addExternalMount(
          alias: 'photos',
          path: mountRoot.path,
        );
        expect(addErr, isNull);
        final err = await provider.setWorkspacesLocation(
          '${tmp.path}/data',
          moveFiles: false,
        );
        expect(err, FilesystemMountsProvider.errorSyncOverlap);
      },
    );

    test('relocating inside an external mount is rejected', () async {
      final provider = await makeProvider();
      final mountRoot = Directory('${tmp.path}/data/photos')
        ..createSync(recursive: true);
      final addErr = await provider.addExternalMount(
        alias: 'photos',
        path: mountRoot.path,
      );
      expect(addErr, isNull);
      final err = await provider.setWorkspacesLocation(
        '${mountRoot.path}/sub',
        moveFiles: false,
      );
      expect(err, FilesystemMountsProvider.errorSyncOverlap);
    });
  });

  group('setWorkspacesLocation move', () {
    test('non-empty destination with moveFiles is rejected', () async {
      final provider = await makeProvider();
      final dst = Directory('${tmp.path}/newhome')..createSync();
      File('${dst.path}/keep.txt').writeAsStringSync('x');
      final err = await provider.setWorkspacesLocation(
        dst.path,
        moveFiles: true,
      );
      expect(err, FilesystemMountsProvider.errorDestinationNotEmpty);
      // Nothing changed.
      expect(provider.workspaces!.path, '$support/workspaces');
    });

    test('non-empty destination without moveFiles is allowed', () async {
      final provider = await makeProvider();
      final dst = Directory('${tmp.path}/newhome')..createSync();
      File('${dst.path}/keep.txt').writeAsStringSync('x');
      final err = await provider.setWorkspacesLocation(
        dst.path,
        moveFiles: false,
      );
      expect(err, isNull);
      expect(provider.workspaces!.path, dst.path);
    });

    test('successful relocation moves files, persists the pref, and updates '
        'the single resolution point', () async {
      final provider = await makeProvider();
      final ws = Directory('$support/workspaces');
      ws.createSync(recursive: true);
      File('${ws.path}/a.txt').writeAsStringSync('hello');
      final dst = Directory('${tmp.path}/newhome2')..createSync();

      final err = await provider.setWorkspacesLocation(
        dst.path,
        moveFiles: true,
      );
      expect(err, isNull);

      expect(provider.workspaces!.path, dst.path);
      expect(File('${dst.path}/a.txt').readAsStringSync(), 'hello');
      expect(
        ws.existsSync(),
        isFalse,
        reason: 'same-volume rename moves the dir',
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppDirectories.workspacesDirPrefsKey), dst.path);
      final resolved = await AppDirectories.getWorkspacesDirectory();
      expect(resolved.path, dst.path);
    });

    test(
      'destination with a missing parent forces the copy fallback: nested '
      'directories land intact, mtimes are preserved, source is removed',
      () async {
        final provider = await makeProvider();
        final ws = Directory('$support/workspaces');
        ws.createSync(recursive: true);
        Directory('${ws.path}/nested/deep').createSync(recursive: true);
        File('${ws.path}/top.txt').writeAsStringSync('t');
        final nested = File('${ws.path}/nested/deep/f.txt');
        nested.writeAsStringSync('f');
        final oldMtime = nested.lastModifiedSync();
        // Parent of the destination does not exist: rename throws on every
        // platform, so this deterministically exercises the copy fallback
        // (the same code path a cross-volume move takes).
        final dst = '${tmp.path}/not-there/dest';

        final err = await provider.setWorkspacesLocation(dst, moveFiles: true);
        expect(err, isNull);

        expect(File('$dst/top.txt').readAsStringSync(), 't');
        final movedNested = File('$dst/nested/deep/f.txt');
        expect(movedNested.readAsStringSync(), 'f');
        expect(
          movedNested.lastModifiedSync().difference(oldMtime).inSeconds.abs(),
          lessThan(2),
          reason: 'relocation is a physical move — mtimes survive the copy',
        );
        expect(ws.existsSync(), isFalse);
        expect(provider.workspaces!.path, dst);
      },
    );
  });

  group('workspaces_dir_v1 load-time validation', () {
    test(
      'restored drive-root pref falls back to the default location',
      () async {
        SharedPreferences.setMockInitialValues({
          AppDirectories.workspacesDirPrefsKey: 'C:/',
        });
        final resolved = await AppDirectories.getWorkspacesDirectory();
        expect(resolved.path, '$support/workspaces');
      },
    );

    test(
      'restored sync-tree pref falls back to the default location',
      () async {
        SharedPreferences.setMockInitialValues({
          AppDirectories.workspacesDirPrefsKey: '$support/upload',
        });
        final resolved = await AppDirectories.getWorkspacesDirectory();
        expect(resolved.path, '$support/workspaces');
      },
    );

    test('restored relative pref falls back to the default location', () async {
      SharedPreferences.setMockInitialValues({
        AppDirectories.workspacesDirPrefsKey: 'relative/workspaces',
      });
      final resolved = await AppDirectories.getWorkspacesDirectory();
      expect(resolved.path, '$support/workspaces');
    });

    test('restored valid pref is honored', () async {
      SharedPreferences.setMockInitialValues({
        AppDirectories.workspacesDirPrefsKey: '${tmp.path}/elsewhere',
      });
      final resolved = await AppDirectories.getWorkspacesDirectory();
      expect(resolved.path, '${tmp.path}/elsewhere');
    });
  });

  group('legacy persisted mounts at load', () {
    test(
      'mount overlapping the sync scope is skipped but kept in prefs',
      () async {
        SharedPreferences.setMockInitialValues({
          FilesystemMountsProvider.prefsKey: jsonEncode([
            FilesystemMount(
              alias: 'photos',
              path: '$support/workspaces/photos',
              readOnly: true,
            ).toJson(),
          ]),
        });
        final provider = await makeProvider();
        expect(provider.externalMounts, isEmpty);
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString(FilesystemMountsProvider.prefsKey),
          isNotNull,
          reason: 'the config is preserved — only the mount is skipped',
        );
      },
    );

    test('non-overlapping legacy mount still loads', () async {
      SharedPreferences.setMockInitialValues({
        FilesystemMountsProvider.prefsKey: jsonEncode([
          FilesystemMount(
            alias: 'photos',
            path: '${tmp.path}/data/photos',
            readOnly: true,
          ).toJson(),
        ]),
      });
      final provider = await makeProvider();
      expect(provider.externalMounts, hasLength(1));
      expect(provider.externalMounts.first.alias, 'photos');
    });
  });
}
