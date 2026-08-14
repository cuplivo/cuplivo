import 'package:Cuplivo/core/services/workspace/linux_sandbox_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LinuxSandboxService.buildAptInstallSteps', () {
    test('runs recover before update before install', () {
      final steps = LinuxSandboxService.buildAptInstallSteps(packages: 'git');
      expect(steps.map((s) => s.stage).toList(), [
        'recover',
        'update',
        'install',
      ]);
    });

    test('recover repairs interrupted dpkg state without deleting locks', () {
      final steps = LinuxSandboxService.buildAptInstallSteps(packages: 'git');
      final recover = steps.first;
      expect(recover.stage, 'recover');
      // Lock files must not be unlinked: fcntl locks are released when the
      // holder exits, and deleting the inode under a live holder would let a
      // second dpkg mutate the database concurrently.
      expect(recover.command, isNot(contains('rm -f /var/lib/dpkg/lock')));
      expect(recover.command, contains('dpkg --configure -a'));
      expect(
        recover.command,
        contains('apt-get -o Acquire::Lock::Timeout=600 -f install -y'),
      );
      expect(recover.command, contains('DEBIAN_FRONTEND=noninteractive'));
    });

    test('every apt invocation waits on a held lock instead of failing', () {
      final steps = LinuxSandboxService.buildAptInstallSteps(packages: 'git');
      for (final step in steps) {
        expect(step.command, contains('-o Acquire::Lock::Timeout=600'));
      }
    });

    test('update runs apt-get update without mirror setup by default', () {
      final steps = LinuxSandboxService.buildAptInstallSteps(packages: 'git');
      final update = steps[1];
      expect(update.stage, 'update');
      expect(update.command, 'apt-get -o Acquire::Lock::Timeout=600 update -y');
    });

    test('update prepends mirror setup when provided', () {
      const mirror =
          "printf '%s\\n' 'deb https://mirror.example/ubuntu noble main universe' > /etc/apt/sources.list && ";
      final steps = LinuxSandboxService.buildAptInstallSteps(
        packages: 'git',
        mirrorSetup: mirror,
      );
      expect(
        steps[1].command,
        '${mirror}apt-get -o Acquire::Lock::Timeout=600 update -y',
      );
    });

    test('install targets the requested packages and cleans cache', () {
      final steps = LinuxSandboxService.buildAptInstallSteps(
        packages: 'python3 python3-pip',
      );
      final install = steps.last;
      expect(install.stage, 'install');
      expect(
        install.command,
        contains(
          'apt-get -o Acquire::Lock::Timeout=600 install -y '
          '--no-install-recommends python3 python3-pip',
        ),
      );
      // The cache-clean invocation must carry the same lock timeout, or a
      // held lock would fail the whole chained step after the install.
      expect(
        install.command,
        endsWith('&& apt-get -o Acquire::Lock::Timeout=600 clean'),
      );
    });

    test('office installs the document toolchain with an extended timeout', () {
      final steps = LinuxSandboxService.buildAptInstallSteps(
        packages:
            'libreoffice pandoc poppler-utils python3-lxml '
            'python3-pil python3-reportlab python3-openpyxl python3-pandas '
            'python3-defusedxml',
        installTimeoutSeconds: 2700,
      );
      expect(steps.last.timeoutSeconds, 2700);
      expect(steps.last.command, contains('libreoffice'));
      expect(steps.last.command, contains('pandoc poppler-utils'));
    });

    test('uses fixed staged timeouts', () {
      final steps = LinuxSandboxService.buildAptInstallSteps(packages: 'git');
      expect(steps[0].timeoutSeconds, 900);
      expect(steps[1].timeoutSeconds, 600);
      expect(steps[2].timeoutSeconds, 1800);
    });
  });
}
