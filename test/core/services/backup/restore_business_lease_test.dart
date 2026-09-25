import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:Cuplivo/core/services/backup/restore_business_lease.dart';
import 'package:Cuplivo/core/services/backup/restore_durability.dart';

final class _FailingOwnerDurability implements RestoreDurability {
  _FailingOwnerDurability(this.delegate);

  final RestoreDurability delegate;

  @override
  Future<void> renameAndSync({
    required FileSystemEntity source,
    required String targetPath,
  }) => delegate.renameAndSync(source: source, targetPath: targetPath);

  @override
  Future<void> restrictDirectory(Directory directory) =>
      delegate.restrictDirectory(directory);

  @override
  Future<void> restrictFile(File file) {
    if (p.basename(file.path).startsWith('owner_')) {
      throw FileSystemException('injected_owner_restrict', file.path);
    }
    return delegate.restrictFile(file);
  }

  @override
  Future<void> syncDirectory(Directory directory, {bool fullBarrier = false}) =>
      delegate.syncDirectory(directory, fullBarrier: fullBarrier);

  @override
  Future<void> syncFile(File file, {bool fullBarrier = false}) =>
      delegate.syncFile(file, fullBarrier: fullBarrier);
}

void main() {
  group('RestoreBusinessLease', () {
    late Directory root;
    late Directory appData;

    setUp(() async {
      root = await Directory.systemTemp.createTemp(
        'kelivo_restore_business_lease_test_',
      );
      appData = Directory(p.join(root.path, 'app_data'));
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test(
      'rejects a duplicate process-local acquire and allows reacquire',
      () async {
        final first = await RestoreBusinessLease.acquire(
          appDataDirectory: appData,
        );
        addTearDown(first.close);

        await expectLater(
          RestoreBusinessLease.acquire(appDataDirectory: appData),
          throwsA(isA<RestoreBusinessLeaseUnavailable>()),
        );
        expect(first.isClosed, isFalse);
        expect(first.instanceId, matches(RegExp(r'^[a-f0-9]{32}$')));
        expect(first.processId, pid);

        final leaseDirectory = Directory(
          p.join(appData.path, RestoreBusinessLease.leaseDirectoryName),
        );
        expect(
          await FileSystemEntity.type(leaseDirectory.path, followLinks: false),
          FileSystemEntityType.directory,
        );
        expect(
          await FileSystemEntity.type(first.lockFile.path, followLinks: false),
          FileSystemEntityType.file,
        );
        final ownerFiles = await leaseDirectory
            .list(followLinks: false)
            .where((entry) => p.basename(entry.path).startsWith('owner_'))
            .toList();
        expect(ownerFiles, hasLength(1));
        final ownerIdentity =
            jsonDecode(await File(ownerFiles.single.path).readAsString())
                as Map<String, dynamic>;
        expect(ownerIdentity['instanceId'], first.instanceId);
        expect(ownerIdentity['probePort'], isA<int>());
        if (!Platform.isWindows) {
          expect((await leaseDirectory.stat()).mode & 0x1ff, 0x1c0);
          expect((await first.lockFile.stat()).mode & 0x1ff, 0x180);
        }

        await first.close();
        expect(first.isClosed, isTrue);
        await first.close();

        final second = await RestoreBusinessLease.acquire(
          appDataDirectory: appData,
        );
        expect(second.instanceId, isNot(first.instanceId));
        expect(second.processId, first.processId);
        await second.close();
      },
    );

    test(
      'fails without waiting once the foreign lock grace is spent',
      () async {
        final helper = File(p.join(root.path, 'business_lease_helper.dart'));
        await helper.writeAsString(_helperSource, flush: true);
        final packageConfig = p.join(
          Directory.current.path,
          '.dart_tool',
          'package_config.json',
        );
        final releaseFile = File(p.join(root.path, 'release_helper'));
        final process = await Process.start('dart', [
          '--packages=$packageConfig',
          helper.path,
          appData.path,
          releaseFile.path,
        ], workingDirectory: Directory.current.path);
        addTearDown(() async {
          process.kill();
          await process.stdin.close();
        });
        final errors = StringBuffer();
        final errorSubscription = process.stderr
            .transform(utf8.decoder)
            .listen(errors.write);
        addTearDown(errorSubscription.cancel);
        final ready = await process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 15));
        expect(ready, 'ready', reason: errors.toString());

        final stopwatch = Stopwatch()..start();
        await expectLater(
          RestoreBusinessLease.acquire(
            appDataDirectory: appData,
            foreignLockGrace: Duration.zero,
          ),
          throwsA(isA<RestoreBusinessLeaseUnavailable>()),
        );
        stopwatch.stop();
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));

        // The holder's marker must survive a losing acquire, and the loser must
        // not leave one of its own behind.
        final leaseDirectory = Directory(
          p.join(appData.path, RestoreBusinessLease.leaseDirectoryName),
        );
        final ownerNames = await leaseDirectory
            .list(followLinks: false)
            .map((entry) => p.basename(entry.path))
            .where((name) => name.startsWith('owner_'))
            .toList();
        expect(ownerNames, hasLength(1));
        expect(ownerNames.single, isNot('owner_$pid'));

        expect(process.kill(), isTrue);
        await process.exitCode.timeout(const Duration(seconds: 15));

        final lease = await RestoreBusinessLease.acquire(
          appDataDirectory: appData,
        );
        await lease.close();
      },
    );

    test('waits out a previous process that is still dying', () async {
      final helper = File(p.join(root.path, 'business_lease_helper.dart'));
      await helper.writeAsString(_helperSource, flush: true);
      final packageConfig = p.join(
        Directory.current.path,
        '.dart_tool',
        'package_config.json',
      );
      final releaseFile = File(p.join(root.path, 'release_helper'));
      final process = await Process.start('dart', [
        '--packages=$packageConfig',
        helper.path,
        appData.path,
        releaseFile.path,
      ], workingDirectory: Directory.current.path);
      addTearDown(() async {
        process.kill();
        await process.stdin.close();
      });
      final ready = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 15));
      expect(ready, 'ready');

      // A phone cannot run the app twice, so the only lock another process can
      // hold there is one on its way out.
      Timer(const Duration(milliseconds: 400), () => releaseFile.createSync());

      final lease = await RestoreBusinessLease.acquire(
        appDataDirectory: appData,
        foreignLockGrace: const Duration(seconds: 10),
      );
      addTearDown(lease.close);
      expect(lease.isClosed, isFalse);
      await process.exitCode.timeout(const Duration(seconds: 15));
    });

    test(
      'reclaims an orphaned same-process owner in every build mode',
      () async {
        final leaseDirectory = Directory(
          p.join(appData.path, RestoreBusinessLease.leaseDirectoryName),
        );
        await leaseDirectory.create(recursive: true);
        final staleOwner = File(p.join(leaseDirectory.path, 'owner_$pid'));
        await staleOwner.writeAsString('stale-debug-isolate');

        final lease = await RestoreBusinessLease.acquire(
          appDataDirectory: appData,
        );

        expect(lease.processId, pid);
        final ownerIdentity =
            jsonDecode(await staleOwner.readAsString()) as Map<String, dynamic>;
        expect(ownerIdentity['instanceId'], lease.instanceId);
        await lease.close();
      },
    );

    test(
      'waits out a same-process owner that is still shutting down',
      () async {
        final leaseDirectory = Directory(
          p.join(appData.path, RestoreBusinessLease.leaseDirectoryName),
        );
        await leaseDirectory.create(recursive: true);
        final outgoingOwner = File(p.join(leaseDirectory.path, 'owner_$pid'));
        final outgoing = await _FakeOwnerProbe.open(outgoingOwner);
        addTearDown(outgoing.close);
        // Android recreates the engine before the outgoing isolate is gone.
        Timer(const Duration(milliseconds: 400), outgoing.close);

        final elapsed = Stopwatch()..start();
        final lease = await RestoreBusinessLease.acquire(
          appDataDirectory: appData,
        );
        elapsed.stop();
        addTearDown(lease.close);

        expect(elapsed.elapsed, greaterThan(const Duration(milliseconds: 300)));
        expect(lease.processId, pid);
        final ownerIdentity =
            jsonDecode(await outgoingOwner.readAsString())
                as Map<String, dynamic>;
        expect(ownerIdentity['instanceId'], lease.instanceId);
      },
    );

    test('keeps a same-process owner that only stalls its probe', () async {
      final leaseDirectory = Directory(
        p.join(appData.path, RestoreBusinessLease.leaseDirectoryName),
      );
      await leaseDirectory.create(recursive: true);
      final outgoingOwner = File(p.join(leaseDirectory.path, 'owner_$pid'));
      final outgoing = await _FakeOwnerProbe.open(
        outgoingOwner,
        // A device returning to the foreground can stall the outgoing
        // isolate past a probe timeout without it being dead.
        silentReplies: 2,
      );
      addTearDown(outgoing.close);

      await expectLater(
        RestoreBusinessLease.acquire(
          appDataDirectory: appData,
          sameProcessOwnerGrace: const Duration(milliseconds: 600),
        ),
        throwsA(isA<RestoreBusinessLeaseUnavailable>()),
      );
      expect(await outgoingOwner.exists(), isTrue);
      expect(outgoing.probeCount, greaterThan(2));
    });

    test('fails once a same-process owner outlives the grace window', () async {
      final leaseDirectory = Directory(
        p.join(appData.path, RestoreBusinessLease.leaseDirectoryName),
      );
      await leaseDirectory.create(recursive: true);
      final outgoingOwner = File(p.join(leaseDirectory.path, 'owner_$pid'));
      final outgoing = await _FakeOwnerProbe.open(outgoingOwner);
      addTearDown(outgoing.close);

      await expectLater(
        RestoreBusinessLease.acquire(
          appDataDirectory: appData,
          sameProcessOwnerGrace: const Duration(milliseconds: 200),
        ),
        throwsA(isA<RestoreBusinessLeaseUnavailable>()),
      );

      await outgoing.close();
      final lease = await RestoreBusinessLease.acquire(
        appDataDirectory: appData,
      );
      await lease.close();
    });

    test(
      'reacquires after an engine restart left the lock descriptor open',
      () async {
        final leaseDirectory = Directory(
          p.join(appData.path, RestoreBusinessLease.leaseDirectoryName),
        );
        await leaseDirectory.create(recursive: true);
        final appDataPath = appData.path;
        // A hot restart, and an Android activity recreation, run main() again
        // inside the surviving process: the previous root isolate is gone but
        // its lock descriptor and its owner marker are both left behind.
        final acquired = await Isolate.run(() async {
          final previous = await RestoreBusinessLease.acquire(
            appDataDirectory: Directory(appDataPath),
          );
          return previous.processId;
        });
        expect(acquired, pid);
        final leftoverOwner = File(p.join(leaseDirectory.path, 'owner_$pid'));
        expect(await leftoverOwner.exists(), isTrue);

        final lease = await RestoreBusinessLease.acquire(
          appDataDirectory: appData,
        );
        addTearDown(lease.close);
        expect(lease.isClosed, isFalse);
        expect(lease.processId, pid);
      },
    );

    test('rejects a duplicate acquire from another isolate', () async {
      final lease = await RestoreBusinessLease.acquire(
        appDataDirectory: appData,
      );
      addTearDown(lease.close);
      final appDataPath = appData.path;

      final rejected = await Isolate.run(() async {
        try {
          final duplicate = await RestoreBusinessLease.acquire(
            appDataDirectory: Directory(appDataPath),
            sameProcessOwnerGrace: const Duration(milliseconds: 200),
          );
          await duplicate.close();
          return false;
        } on RestoreBusinessLeaseUnavailable {
          return true;
        }
      });

      expect(rejected, isTrue);
      expect(lease.isClosed, isFalse);
    });

    test(
      'propagates owner durability failure and removes its marker',
      () async {
        await expectLater(
          RestoreBusinessLease.acquire(
            appDataDirectory: appData,
            durability: _FailingOwnerDurability(RestorePlatformDurability()),
          ),
          throwsA(
            isA<FileSystemException>().having(
              (error) => error.message,
              'message',
              'injected_owner_restrict',
            ),
          ),
        );

        final leaseDirectory = Directory(
          p.join(appData.path, RestoreBusinessLease.leaseDirectoryName),
        );
        expect(
          await leaseDirectory
              .list(followLinks: false)
              .where((entry) => p.basename(entry.path).startsWith('owner_'))
              .toList(),
          isEmpty,
        );
        final lease = await RestoreBusinessLease.acquire(
          appDataDirectory: appData,
        );
        await lease.close();
      },
    );

    test('rejects a directory at the fixed lock-file path', () async {
      final lockPath = p.join(
        appData.path,
        RestoreBusinessLease.leaseDirectoryName,
        RestoreBusinessLease.lockFileName,
      );
      await Directory(lockPath).create(recursive: true);

      await expectLater(
        RestoreBusinessLease.acquire(appDataDirectory: appData),
        throwsA(isA<StateError>()),
      );

      await Directory(lockPath).delete();
      final lease = await RestoreBusinessLease.acquire(
        appDataDirectory: appData,
      );
      await lease.close();
    });

    test(
      'rejects a link at the fixed lock-file path',
      () async {
        final leaseDirectory = Directory(
          p.join(appData.path, RestoreBusinessLease.leaseDirectoryName),
        );
        await leaseDirectory.create(recursive: true);
        final target = File(p.join(root.path, 'target.lock'));
        await target.create();
        await Link(
          p.join(leaseDirectory.path, RestoreBusinessLease.lockFileName),
        ).create(target.path);

        await expectLater(
          RestoreBusinessLease.acquire(appDataDirectory: appData),
          throwsA(isA<StateError>()),
        );
      },
      skip: Platform.isWindows
          ? 'Symlink setup is not portable on Windows.'
          : false,
    );
  });
}

/// Stands in for the owner probe of an outgoing engine's isolate.
final class _FakeOwnerProbe {
  _FakeOwnerProbe._(this._server, this._token, this._silentReplies);

  final ServerSocket _server;
  final String _token;
  int _silentReplies;
  var _closed = false;

  /// How many probes this owner has been asked to answer.
  var probeCount = 0;

  static Future<_FakeOwnerProbe> open(
    File ownerFile, {
    int silentReplies = 0,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    const token = 'outgoing-engine-instance';
    final probe = _FakeOwnerProbe._(server, token, silentReplies);
    server.listen(probe._answer, onError: (_) {});
    await ownerFile.writeAsString(
      jsonEncode({'instanceId': token, 'probePort': server.port}),
      flush: true,
    );
    return probe;
  }

  Future<void> _answer(Socket socket) async {
    probeCount++;
    if (_silentReplies > 0) {
      _silentReplies--;
      await socket.close();
      return;
    }
    try {
      final request = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      socket.writeln(request == _token ? 'alive' : 'denied');
      await socket.flush();
    } catch (_) {
      // A malformed probe is not part of what these tests assert.
    } finally {
      await socket.close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close();
  }
}

const _helperSource = r'''
import 'dart:io';

import 'package:Cuplivo/core/services/backup/restore_business_lease.dart';

Future<void> main(List<String> arguments) async {
  final lease = await RestoreBusinessLease.acquire(
    appDataDirectory: Directory(arguments[0]),
  );
  stdout.writeln('ready');
  await stdout.flush();
  final releaseFile = File(arguments[1]);
  while (!await releaseFile.exists()) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  await lease.close();
}
''';
