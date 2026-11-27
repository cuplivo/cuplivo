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

  test('discovers archives from both naming eras', () async {
    for (final name in [
      'cuplivo_backup_2026-11-19T12-31-05.123456.zip',
      'kelivo_backup_2026-11-19T12-31-05.123456.zip',
      // A case-insensitive store can hand the name back upper-cased.
      'CUPLIVO_BACKUP_2026-11-20T00-00-00.000001.ZIP',
      'backup.zip',
      'kelivo_auto_x_2026-11-19T12-31-05.123456.zip',
    ]) {
      File('${root.path}/$name').writeAsStringSync('archive');
    }

    final names = (await RecoveryFileDiscovery.archives(
      root,
    )).map((file) => file.uri.pathSegments.last).toSet();
    expect(
      names,
      containsAll([
        'cuplivo_backup_2026-11-19T12-31-05.123456.zip',
        'kelivo_backup_2026-11-19T12-31-05.123456.zip',
        'CUPLIVO_BACKUP_2026-11-20T00-00-00.000001.ZIP',
      ]),
    );
    // Not every .zip in the data directory is a backup this build wrote.
    expect(names, isNot(contains('backup.zip')));
    expect(
      names,
      isNot(contains('kelivo_auto_x_2026-11-19T12-31-05.123456.zip')),
    );
    expect(await RecoveryFileDiscovery.hasPriorData(root), isTrue);
  });

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
}
