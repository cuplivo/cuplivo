import 'dart:io';

import 'package:Cuplivo/features/linux_sandbox/services/sandbox_disk_layout.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => p.join(root, 'cache');

  @override
  Future<String?> getTemporaryPath() async => p.join(root, 'tmp');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late PathProviderPlatform previous;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sandbox_disk_layout_');
    previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
  });

  tearDown(() async {
    PathProviderPlatform.instance = previous;
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  group('SandboxDiskLayout', () {
    test('ensureLayout creates files/linux/tmp', () async {
      const id = 'sb-new';
      await SandboxDiskLayout.ensureLayout(id);
      final root = await SandboxDiskLayout.sandboxRoot(id);
      expect(await root.exists(), isTrue);
      expect(await (await SandboxDiskLayout.filesDir(id)).exists(), isTrue);
      expect(await (await SandboxDiskLayout.linuxDir(id)).exists(), isTrue);
      expect(await (await SandboxDiskLayout.tmpDir(id)).exists(), isTrue);
      expect(await SandboxDiskLayout.hasBaseEnvMarker(id), isFalse);
    });

    test('writeBaseEnvMarker and hasBaseEnvMarker', () async {
      const id = 'sb-marker';
      await SandboxDiskLayout.writeBaseEnvMarker(id);
      expect(await SandboxDiskLayout.hasBaseEnvMarker(id), isTrue);
    });

    test('migrates v1 flat root into files/', () async {
      const id = 'sb-v1';
      final base = await SandboxDiskLayout.sandboxesBase();
      final root = Directory(p.join(base.path, id));
      await root.create(recursive: true);
      await File(p.join(root.path, 'notes.txt')).writeAsString('hello');
      await Directory(p.join(root.path, 'docs')).create();
      await File(p.join(root.path, 'docs', 'a.md')).writeAsString('# a');

      await SandboxDiskLayout.ensureLayout(id);

      final files = await SandboxDiskLayout.filesDir(id);
      expect(await files.exists(), isTrue);
      expect(await File(p.join(files.path, 'notes.txt')).exists(), isTrue);
      expect(
        await File(p.join(files.path, 'notes.txt')).readAsString(),
        'hello',
      );
      expect(await File(p.join(files.path, 'docs', 'a.md')).exists(), isTrue);
      // Flat entries must leave the root.
      expect(await File(p.join(root.path, 'notes.txt')).exists(), isFalse);
      expect(await Directory(p.join(root.path, 'docs')).exists(), isFalse);
      expect(await (await SandboxDiskLayout.linuxDir(id)).exists(), isTrue);
      expect(await (await SandboxDiskLayout.tmpDir(id)).exists(), isTrue);
    });

    test('does not re-migrate when files/ already exists', () async {
      const id = 'sb-already';
      await SandboxDiskLayout.ensureLayout(id);
      final files = await SandboxDiskLayout.filesDir(id);
      await File(p.join(files.path, 'keep.txt')).writeAsString('keep');
      final root = await SandboxDiskLayout.sandboxRoot(id);
      await File(p.join(root.path, 'stray.txt')).writeAsString('stray');

      await SandboxDiskLayout.ensureLayout(id);

      expect(await File(p.join(files.path, 'keep.txt')).exists(), isTrue);
      // Stray at root is left alone once files/ exists (not a v1 migrate).
      expect(await File(p.join(root.path, 'stray.txt')).exists(), isTrue);
      expect(await File(p.join(files.path, 'stray.txt')).exists(), isFalse);
    });

    test('destroySandboxTree removes the tree', () async {
      const id = 'sb-destroy';
      await SandboxDiskLayout.writeBaseEnvMarker(id);
      final root = await SandboxDiskLayout.sandboxRoot(id);
      expect(await root.exists(), isTrue);
      await SandboxDiskLayout.destroySandboxTree(id);
      expect(await root.exists(), isFalse);
    });
  });
}
