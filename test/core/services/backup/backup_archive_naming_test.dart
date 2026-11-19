import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/backup.dart';
import 'package:Cuplivo/core/services/backup/backup_archive_naming.dart';

/// An archive is named for the reader it is written for, and every reader
/// accepts both eras of the name.
void main() {
  const stamp = '2026-11-19T12-31-05.123456';

  test('the target decides the prefix', () {
    expect(
      BackupArchiveNaming.fileNameFor(BackupTarget.cuplivo, stamp),
      'cuplivo_backup_$stamp.zip',
    );
    expect(
      BackupArchiveNaming.fileNameFor(BackupTarget.kelivo, stamp),
      'kelivo_backup_$stamp.zip',
    );
  });

  test('both prefixes stay readable, whatever case the file system kept', () {
    for (final prefix in BackupArchiveNaming.readablePrefixes) {
      expect(BackupArchiveNaming.isReadable('${prefix}x.zip'), isTrue);
      expect(BackupArchiveNaming.isReadable('${prefix}x.kbackup'), isTrue);
      expect(BackupArchiveNaming.isArchiveName('${prefix}x.zip'), isTrue);
      expect(BackupArchiveNaming.isArchiveName('${prefix}x.kbackup'), isTrue);
    }
    // 4.7.0 wrote every archive with the Kelivo prefix; the upper-case check is
    // how a file synced through a case-insensitive store still counts.
    expect(BackupArchiveNaming.isReadable('KELIVO_BACKUP_x.zip'), isTrue);
    expect(BackupArchiveNaming.isReadable('kelivo-snapshot-1.zip'), isFalse);
    expect(BackupArchiveNaming.isReadable('cuplivo_auto_x.zip'), isFalse);
    expect(
      BackupArchiveNaming.isArchiveName('kelivo_backup_x.partial'),
      isFalse,
    );
    expect(BackupArchiveNaming.isArchiveName('cuplivo_backup_x.json'), isFalse);
  });

  test('the timestamp parses whatever case the store kept', () {
    // The same premise the discovery test states: a store can hand a name back
    // in another case, and isArchiveName already accepts it. Ordering must not
    // disagree with discovery about the same file.
    final expected = DateTime(2026, 11, 19, 12, 31, 5, 123, 456);
    expect(
      BackupArchiveNaming.timestampFromFileName(
        'CUPLIVO_BACKUP_2026-11-19T12-31-05.123456.ZIP',
      ),
      expected,
    );
    expect(
      BackupArchiveNaming.timestampFromFileName(
        'cuplivo_backup_2026-11-19t12-31-05.123456.zip',
      ),
      expected,
    );
  });

  test('the timestamp parses from either prefix', () {
    final expected = DateTime(2026, 11, 19, 12, 31, 5, 123, 456);
    expect(
      BackupArchiveNaming.timestampFromFileName('cuplivo_backup_$stamp.zip'),
      expected,
    );
    expect(
      BackupArchiveNaming.timestampFromFileName('kelivo_backup_$stamp.kbackup'),
      expected,
    );
    expect(
      BackupArchiveNaming.timestampFromFileName('kelivo-snapshot-1.zip'),
      isNull,
    );
    expect(
      BackupArchiveNaming.timestampFromFileName(
        'kelivo_auto_x_2026-11-19T12-31-05.123456.zip',
      ),
      isNull,
    );
  });
}
