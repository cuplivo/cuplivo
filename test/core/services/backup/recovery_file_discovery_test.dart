import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/services/backup/local_copy_catalog.dart';
import 'package:Cuplivo/core/services/backup/recovery_file_discovery.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('recovery-discovery-');
  });
  tearDown(() => root.delete(recursive: true));

  test('trash traversal never follows links outside the data root', () async {
    final outside = await Directory.systemTemp.createTemp('outside-recovery-');
    addTearDown(() => outside.delete(recursive: true));
    final secret = await File(
      '${outside.path}/kelivo.db',
    ).writeAsString('outside');
    final trash = await Directory('${root.path}/.Trash').create();
    await Link('${trash.path}/linked').create(outside.path);
    await Link('${trash.path}/kelivo.db').create(secret.path);
    expect(await RecoveryFileDiscovery.databases(root), isEmpty);
    expect(await secret.readAsString(), 'outside');
  }, skip: Platform.isWindows ? 'Symlink creation requires privileges' : false);

  test(
    'a bounded incomplete search blocks empty initialization evidence checks',
    () async {
      final path = '${root.path}/.Trash/${List.filled(12, 'nested').join('/')}';
      await Directory(path).create(recursive: true);
      await File('$path/kelivo.db').writeAsString('retained');
      final catalog = LocalCopyCatalog(appDataDirectory: root);
      await catalog.list();
      expect(catalog.hadReadErrors, isTrue);
      expect(await RecoveryFileDiscovery.hasPriorData(root), isTrue);
      expect(await File('$path/kelivo.db').readAsString(), 'retained');
    },
  );

  test('discovers a drop-in archive under either naming', () async {
    for (final name in [
      'kelivo_backup_2026-11-01T10-00-00.000000.zip',
      'cuplivo_backup_2026-11-01T10-00-00.000000.zip',
    ]) {
      await File('${root.path}/$name').writeAsString('archive');
    }
    await File('${root.path}/notes.zip').writeAsString('not ours');
    await File(
      '${root.path}/cuplivo_backup_2026-11-01.txt',
    ).writeAsString('wrong extension');

    final discovered = await RecoveryFileDiscovery.archives(root);
    expect(discovered.map((file) => file.uri.pathSegments.last).toSet(), {
      'kelivo_backup_2026-11-01T10-00-00.000000.zip',
      'cuplivo_backup_2026-11-01T10-00-00.000000.zip',
    });
    expect(await RecoveryFileDiscovery.hasPriorData(root), isTrue);
  });

  test('isSnapshotArchive accepts both prefixes and nothing else', () {
    for (final name in [
      'kelivo-snapshot-2026-11-01T10-00-00.000000.zip',
      'kelivo_backup_2026-11-01T10-00-00.000000.zip',
      'cuplivo_backup_2026-11-01T10-00-00.000000.zip',
    ]) {
      expect(
        RecoveryFileDiscovery.isSnapshotArchive(name),
        isTrue,
        reason: name,
      );
    }
    expect(RecoveryFileDiscovery.isSnapshotArchive('backup.zip'), isFalse);
    expect(
      RecoveryFileDiscovery.isSnapshotArchive('cuplivo_backup_2026-11-01.txt'),
      isFalse,
    );
  });
}
