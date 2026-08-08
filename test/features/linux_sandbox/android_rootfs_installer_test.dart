import 'dart:io';

import 'package:Cuplivo/features/linux_sandbox/services/android_rootfs_installer.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

void main() {
  group('AndroidRootfsPatcher', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('android_rootfs_patch_');
    });

    tearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('writes resolv.conf hosts hostname locale and tmp dirs', () async {
      final linux = Directory(p.join(tmp.path, 'linux'));
      final etc = Directory(p.join(linux.path, 'etc'));
      await etc.create(recursive: true);

      await AndroidRootfsPatcher.patch(linux);

      final resolv = await File(p.join(etc.path, 'resolv.conf')).readAsString();
      expect(resolv.contains('nameserver 1.1.1.1'), isTrue);
      expect(resolv.contains('Cuplivo sandbox'), isTrue);

      final hosts = await File(p.join(etc.path, 'hosts')).readAsString();
      expect(hosts.contains('127.0.0.1 localhost'), isTrue);
      expect(hosts.contains('::1 localhost'), isTrue);

      final hostname = (await File(
        p.join(etc.path, 'hostname'),
      ).readAsString()).trim();
      expect(hostname, 'localhost');

      final locale = await File(
        p.join(etc.path, 'default', 'locale'),
      ).readAsString();
      expect(locale.contains('LANG=C.UTF-8'), isTrue);

      expect(await Directory(p.join(linux.path, 'tmp')).exists(), isTrue);
      expect(
        await Directory(p.join(linux.path, 'var', 'tmp')).exists(),
        isTrue,
      );
      expect(await Directory(p.join(linux.path, 'root')).exists(), isTrue);
    });

    test('does not overwrite public DNS resolv.conf', () async {
      final linux = Directory(p.join(tmp.path, 'linux'));
      final etc = Directory(p.join(linux.path, 'etc'));
      await etc.create(recursive: true);
      final resolv = File(p.join(etc.path, 'resolv.conf'));
      await resolv.writeAsString('nameserver 9.9.9.9\n');

      await AndroidRootfsPatcher.patch(linux);

      expect(await resolv.readAsString(), 'nameserver 9.9.9.9\n');
    });
  });

  group('AndroidRootfsInstaller path jail', () {
    test('normalizeTarPath rejects path escape', () {
      expect(
        () => AndroidRootfsInstaller.normalizeTarPathForTest('../etc/passwd'),
        throwsStateError,
      );
      expect(
        AndroidRootfsInstaller.normalizeTarPathForTest('./usr/bin/bash'),
        'usr/bin/bash',
      );
      expect(AndroidRootfsInstaller.normalizeTarPathForTest(''), isNull);
    });
  });

  group('AndroidRootfsInstaller extract', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('android_rootfs_extract_');
    });

    tearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('extracts tar.gz entries under target with path jail', () async {
      final archive = Archive();
      archive.addFile(ArchiveFile.string('bin/sh', '#!/bin/sh\n'));
      archive.addFile(ArchiveFile.directory('etc'));
      archive.addFile(ArchiveFile.string('etc/os-release', 'NAME=Test\n'));
      archive.addFile(ArchiveFile.symlink('bin/bash', 'sh'));

      final tarBytes = TarEncoder().encodeBytes(archive);
      final gzBytes = GZipEncoder().encodeBytes(tarBytes);
      final tarGz = File(p.join(tmp.path, 'rootfs.tar.gz'));
      await tarGz.writeAsBytes(gzBytes, flush: true);

      final target = Directory(p.join(tmp.path, 'staging'));
      await target.create(recursive: true);

      final installer = AndroidRootfsInstaller(
        rawClient: MockClient((_) async => http.Response('unused', 500)),
      );
      await installer.extractTarGzForTest(
        archiveFile: tarGz,
        targetDir: target,
      );
      installer.close();

      expect(await File(p.join(target.path, 'bin', 'sh')).exists(), isTrue);
      expect(
        await File(p.join(target.path, 'etc', 'os-release')).readAsString(),
        'NAME=Test\n',
      );
      final link = Link(p.join(target.path, 'bin', 'bash'));
      expect(await link.exists(), isTrue);
      expect(await link.target(), 'sh');
    });
  });
}
