import 'dart:io';

import 'package:Cuplivo/utils/app_directories.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// The one rule that keeps a workspace id from being a filesystem path: the id
/// arrives from the wire (LAN sync) and from a backup, and it is interpolated
/// into `<appData>/workspaces/<id>/files`. The file *path* inside a workspace
/// has had four gates since slice 18; this is the segment that precedes it.
class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => '$path/cache';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isSafeWorkspaceId', () {
    test('accepts the ids this device creates', () {
      expect(isSafeWorkspaceId('3f2b1c4d-5e6a-4b7c-8d9e-0f1a2b3c4d5e'), isTrue);
      expect(isSafeWorkspaceId('workspace-1'), isTrue);
      expect(isSafeWorkspaceId('a.b'), isTrue);
    });

    test('refuses anything that is not one plain segment', () {
      for (final id in <String>[
        '..',
        '.',
        '',
        '../../..',
        '..\\..',
        'a/b',
        'a\\b',
        'C:',
        '/etc',
        'notes:stream',
        'evil.',
        'evil ',
        'con',
        'NUL.txt',
        'com1',
      ]) {
        expect(isSafeWorkspaceId(id), isFalse, reason: id);
      }
    });
  });

  group('AppDirectories.workspaceFilesDir', () {
    late Directory root;
    late PathProviderPlatform previous;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('app-dirs-');
      previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
    });

    tearDown(() async {
      PathProviderPlatform.instance = previous;
      try {
        await root.delete(recursive: true);
      } catch (_) {}
    });

    test('joins a real id under the app data root', () async {
      final dir = await AppDirectories.workspaceFilesDir('w-1');
      expect(dir.path, endsWith('workspaces/w-1/files'));
      expect(await dir.exists(), isTrue);
    });

    test('refuses an id that would leave the managed tree', () async {
      await expectLater(
        AppDirectories.workspaceFilesDir('..'),
        throwsArgumentError,
        reason: 'the sink must not join a traversal onto the app data root',
      );
      expect(
        Directory('${root.path}/files').existsSync(),
        isFalse,
        reason: 'and it must not have created anything on the way',
      );
    });
  });
}
