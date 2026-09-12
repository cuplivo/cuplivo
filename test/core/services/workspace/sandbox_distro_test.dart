import 'dart:io';

import 'package:Cuplivo/core/services/workspace/linux_sandbox_service.dart';
import 'package:Cuplivo/core/services/workspace/sandbox_distro.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('SandboxDistro.parseOsRelease', () {
    test('parses a quoted Alpine identity', () {
      final distro = SandboxDistro.parseOsRelease(
        'NAME="Alpine Linux"\n'
        'ID=alpine\n'
        'VERSION_ID=3.24.1\n'
        'PRETTY_NAME="Alpine Linux v3.24"\n',
      );
      expect(distro, isNotNull);
      expect(distro!.id, 'alpine');
      expect(distro.family, SandboxDistroFamily.alpine);
      expect(distro.version, '3.24.1');
    });

    test('parses Ubuntu and Debian identities', () {
      final ubuntu = SandboxDistro.parseOsRelease(
        'ID=ubuntu\nVERSION_ID="24.04"\n',
      );
      expect(ubuntu!.family, SandboxDistroFamily.ubuntu);
      expect(ubuntu.version, '24.04');

      final debian = SandboxDistro.parseOsRelease(
        'ID=debian\nVERSION_ID=13\nVERSION_CODENAME=trixie\n',
      );
      expect(debian!.family, SandboxDistroFamily.debian);
      expect(debian.version, '13');
    });

    test('falls back to ID_LIKE for derivatives', () {
      final distro = SandboxDistro.parseOsRelease(
        'ID=linuxmint\nID_LIKE="ubuntu debian"\nVERSION_ID=22\n',
      );
      expect(distro!.family, SandboxDistroFamily.ubuntu);
      expect(distro.id, 'linuxmint');
    });

    test('splits ID_LIKE on tabs and repeated spaces', () {
      expect(
        SandboxDistro.parseOsRelease(
          'ID=unknown\nID_LIKE="debian\tubuntu"\n',
        )!.family,
        SandboxDistroFamily.debian,
      );
      expect(
        SandboxDistro.parseOsRelease(
          'ID=unknown\nID_LIKE="debian  ubuntu"\n',
        )!.family,
        SandboxDistroFamily.debian,
      );
    });

    test('ignores lines whose key is not an identifier', () {
      final distro = SandboxDistro.parseOsRelease(
        'bad key = ignored\n'
        'ID=alpine\n'
        'VERSION_ID=3.24.1\n',
      );
      expect(distro!.id, 'alpine');
      expect(distro.family, SandboxDistroFamily.alpine);
      expect(distro.version, '3.24.1');
    });

    test('ignores comments, blanks and malformed lines', () {
      final distro = SandboxDistro.parseOsRelease(
        '# comment\n'
        '\n'
        'not-a-key-value\n'
        'ID=alpine\n'
        '=orphan\n',
      );
      expect(distro!.id, 'alpine');
      expect(distro.version, isNull);
    });

    test('returns null for unknown distributions', () {
      expect(SandboxDistro.parseOsRelease('ID=arch\n'), isNull);
      expect(SandboxDistro.parseOsRelease(''), isNull);
    });

    test('drops a VERSION_ID that is not a plain numeric version', () {
      final distro = SandboxDistro.parseOsRelease(
        "ID=alpine\nVERSION_ID=3.24'; id; echo '\n",
      );
      expect(distro!.family, SandboxDistroFamily.alpine);
      expect(distro.version, isNull);
    });
  });

  group('SandboxDistro.sanitizeVersion', () {
    test('keeps dotted numeric versions and rejects everything else', () {
      expect(SandboxDistro.sanitizeVersion('3.24.1'), '3.24.1');
      expect(SandboxDistro.sanitizeVersion(' 24.04 '), '24.04');
      expect(SandboxDistro.sanitizeVersion('13'), '13');
      expect(SandboxDistro.sanitizeVersion(null), isNull);
      expect(SandboxDistro.sanitizeVersion(''), isNull);
      expect(SandboxDistro.sanitizeVersion('3.24 beta'), isNull);
      expect(SandboxDistro.sanitizeVersion("3.24'; id"), isNull);
      expect(SandboxDistro.sanitizeVersion('3.24; rm -rf /'), isNull);
    });
  });

  group('SandboxDistro marker round trip', () {
    test('round-trips every family and version', () {
      const samples = [
        SandboxDistro(
          id: 'alpine',
          family: SandboxDistroFamily.alpine,
          version: '3.21',
        ),
        SandboxDistro(id: 'ubuntu', family: SandboxDistroFamily.ubuntu),
        SandboxDistro(
          id: 'debian',
          family: SandboxDistroFamily.debian,
          version: '13',
        ),
      ];
      for (final sample in samples) {
        final restored = SandboxDistro.fromMarker(sample.toMarker());
        expect(restored, isNotNull);
        expect(restored!.id, sample.id);
        expect(restored.family, sample.family);
        expect(restored.version, sample.version);
      }
    });

    test('rejects a truncated or unknown marker', () {
      expect(SandboxDistro.fromMarker(''), isNull);
      expect(SandboxDistro.fromMarker('family=alpine\n'), isNull);
      expect(SandboxDistro.fromMarker('id=alpine\nfamily=plan9\n'), isNull);
    });

    test('drops a shell-injection payload in a hand-edited marker', () {
      final restored = SandboxDistro.fromMarker(
        "id=alpine\nfamily=alpine\nversion=3.24'; id; echo '\n",
      );
      expect(restored!.family, SandboxDistroFamily.alpine);
      expect(restored.version, isNull);
    });

    test('rejects a marker whose id contradicts its family', () {
      expect(SandboxDistro.fromMarker('id=alpine\nfamily=ubuntu\n'), isNull);
      // A derivative id that maps to no family stays valid with its family.
      final mint = SandboxDistro.fromMarker('id=linuxmint\nfamily=ubuntu\n');
      expect(mint!.family, SandboxDistroFamily.ubuntu);
    });
  });

  group('LinuxSandboxService distro marker files', () {
    test('writes and reads the marker atomically under .sandbox', () async {
      final workspace = await Directory.systemTemp.createTemp(
        'cuplivo_distro_marker_',
      );
      addTearDown(() => workspace.delete(recursive: true));
      const distro = SandboxDistro(
        id: 'alpine',
        family: SandboxDistroFamily.alpine,
        version: '3.24.1',
      );

      await LinuxSandboxService.writeDistroMarker(workspace.path, distro);
      final marker = LinuxSandboxService.distroMarkerFile(workspace.path);
      expect(await marker.exists(), isTrue);
      expect(
        p.equals(marker.parent.path, p.join(workspace.path, '.sandbox')),
        isTrue,
      );

      final restored = await LinuxSandboxService.readDistroMarker(
        workspace.path,
      );
      expect(restored!.family, SandboxDistroFamily.alpine);
      expect(restored.version, '3.24.1');

      await marker.writeAsString('broken');
      expect(
        await LinuxSandboxService.readDistroMarker(workspace.path),
        isNull,
      );
    });

    test('detects the distribution from the extracted os-release', () async {
      final workspace = await Directory.systemTemp.createTemp(
        'cuplivo_distro_detect_',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final osRelease = File(
        p.join(workspace.path, '.sandbox', 'linux', 'etc', 'os-release'),
      );
      await osRelease.parent.create(recursive: true);
      await osRelease.writeAsString('ID=alpine\nVERSION_ID=3.24.1\n');

      final detected = await LinuxSandboxService.detectDistro(workspace.path);
      expect(detected!.family, SandboxDistroFamily.alpine);
      expect(detected.version, '3.24.1');

      await osRelease.delete();
      expect(await LinuxSandboxService.detectDistro(workspace.path), isNull);
    });
  });

  group('LinuxSandboxService.archiveExtensionForUrl', () {
    test('mirrors the URL extension instead of a fixed .tar.gz', () {
      expect(
        LinuxSandboxService.archiveExtensionForUrl(
          'https://example.com/rootfs.tar.xz',
        ),
        '.tar.xz',
      );
      expect(
        LinuxSandboxService.archiveExtensionForUrl(
          'https://example.com/rootfs.txz?token=1',
        ),
        '.txz',
      );
      expect(
        LinuxSandboxService.archiveExtensionForUrl(
          'https://example.com/rootfs.TAR.GZ',
        ),
        '.tar.gz',
      );
      expect(
        LinuxSandboxService.archiveExtensionForUrl(
          'https://example.com/rootfs.tar',
        ),
        '.tar',
      );
    });

    test('defaults to .tar.gz for extension-less URLs', () {
      expect(
        LinuxSandboxService.archiveExtensionForUrl(
          'https://example.com/download',
        ),
        '.tar.gz',
      );
      expect(
        LinuxSandboxService.archiveExtensionForUrl('not a url'),
        '.tar.gz',
      );
    });

    test('falls back to the query string of signed URLs', () {
      expect(
        LinuxSandboxService.archiveExtensionForUrl(
          'https://mirrors.example.com/download'
          '?file=alpine-minirootfs-3.24.1-x86_64.tar.xz&X-Amz-Signature=abc',
        ),
        '.tar.xz',
      );
      expect(
        LinuxSandboxService.archiveExtensionForUrl(
          'https://mirrors.example.com/download?name=rootfs.tgz',
        ),
        '.tgz',
      );
    });

    test('prefers the path suffix over an extension in the query', () {
      expect(
        LinuxSandboxService.archiveExtensionForUrl(
          'https://example.com/rootfs.tar.xz?fallback=other.tar.gz',
        ),
        '.tar.xz',
      );
    });

    test('ignores extensions in host names and unrelated parameters', () {
      expect(
        LinuxSandboxService.archiveExtensionForUrl(
          'https://files.tar.example.com/download?ref=v1',
        ),
        '.tar.gz',
      );
      expect(
        LinuxSandboxService.archiveExtensionForUrl(
          'https://host/download?x=1.tar.gz.bak',
        ),
        '.tar.gz',
      );
    });
  });
}
