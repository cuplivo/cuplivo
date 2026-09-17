import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:Cuplivo/core/services/backup/restore_lease_lock.dart';

void main() {
  group('RestoreLeaseLock', () {
    late Directory root;
    late File lockFile;

    setUp(() async {
      root = await Directory.systemTemp.createTemp(
        'kelivo_restore_lease_lock_test_',
      );
      lockFile = File(p.join(root.path, 'lease.lock'));
      await lockFile.create();
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test(
      'reacquires after a previous isolate left its descriptor open',
      () async {
        final leakedPath = lockFile.path;
        // A descriptor is not closed when its isolate goes away, which is what a
        // hot restart and an Android engine recreation both leave behind.
        await Isolate.run(() async {
          final leaked = await RestoreLeaseLock.tryAcquire(File(leakedPath));
          return leaked != null;
        });

        final lock = await RestoreLeaseLock.tryAcquire(lockFile);
        expect(
          lock,
          isNotNull,
          reason:
              'a descriptor-scoped lock would lock this process out of its '
              'own data until the process dies',
        );
        await lock!.release();
      },
    );

    test('release is idempotent and allows reacquire', () async {
      final held = await RestoreLeaseLock.tryAcquire(lockFile);
      expect(held, isNotNull);
      await held!.release();
      await held.release();

      final reacquired = await RestoreLeaseLock.tryAcquire(lockFile);
      expect(reacquired, isNotNull);
      await reacquired!.release();
    });
  });
}
