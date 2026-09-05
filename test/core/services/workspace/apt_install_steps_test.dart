import 'package:Cuplivo/core/models/workspace.dart';
import 'package:Cuplivo/core/services/workspace/linux_sandbox_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Ubuntu dependency package mapping', () {
    test('maps common packages to apt names', () {
      expect(
        LinuxSandboxService.packageNamesForDependency(
          WorkspaceDependencyIds.githubCli,
          ios: false,
        ),
        'gh',
      );
      expect(
        LinuxSandboxService.packageNamesForDependency(
          WorkspaceDependencyIds.curl,
          ios: false,
        ),
        'curl',
      );
      expect(
        LinuxSandboxService.packageNamesForDependency(
          WorkspaceDependencyIds.opensshClient,
          ios: false,
        ),
        'openssh-client',
      );
      expect(
        LinuxSandboxService.packageNamesForDependency(
          WorkspaceDependencyIds.archive,
          ios: false,
        ),
        'zip unzip',
      );
    });

    test('office mapping includes both zip tools', () {
      final packages = LinuxSandboxService.packageNamesForDependency(
        WorkspaceDependencyIds.office,
        ios: false,
      );

      expect(packages.split(' '), containsAll(<String>['zip', 'unzip']));
    });
  });

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

    test('uses fixed staged timings', () {
      final steps = LinuxSandboxService.buildAptInstallSteps(packages: 'git');
      expect(steps[0].timeoutSeconds, 900);
      expect(steps[1].timeoutSeconds, 1200);
      expect(steps[2].timeoutSeconds, 1800);
    });
  });
  group('LinuxSandboxService.aptMirrorSetup', () {
    const tuna = 'https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports';

    test('rewrites the deb822 sources file with the given mirror', () {
      final setup = LinuxSandboxService.aptMirrorSetup(tuna);
      expect(
        setup,
        contains("cat > /etc/apt/sources.list.d/ubuntu.sources <<'EOF'"),
      );
      expect(setup, contains('URIs: $tuna/'));
      expect(setup, contains('Types: deb'));
      expect(setup, contains('Suites: noble noble-updates noble-backports'));
      expect(setup, contains('Suites: noble-security'));
      expect(
        setup,
        contains('Components: main universe restricted multiverse'),
      );
      expect(
        setup,
        contains('Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg'),
      );
      // The legacy one-line file must go, or apt merges the default archive
      // back in alongside the configured mirror.
      expect(setup, contains('rm -f /etc/apt/sources.list'));
    });

    test('runs fail-fast under set -e', () {
      final setup = LinuxSandboxService.aptMirrorSetup(tuna);
      expect(setup, startsWith('set -e\n'));
      // A failed rewrite must abort the chained apt-get update instead of
      // refreshing package lists from stale or merged sources.
      expect(
        setup,
        startsWith('set -e\ncat > /etc/apt/sources.list.d/ubuntu.sources'),
      );
    });

    test('splits the security suite onto its own mirror URL when provided', () {
      final setup = LinuxSandboxService.aptMirrorSetup(
        'http://archive.ubuntu.com/ubuntu',
        securityMirrorUrl: 'http://security.ubuntu.com/ubuntu',
      );
      expect(setup, contains('URIs: http://archive.ubuntu.com/ubuntu/'));
      expect(setup, contains('URIs: http://security.ubuntu.com/ubuntu/'));
    });

    test('composes with the update command on a new line', () {
      final setup = LinuxSandboxService.aptMirrorSetup(tuna);
      final steps = LinuxSandboxService.buildAptInstallSteps(
        packages: 'git',
        mirrorSetup: setup,
      );
      expect(steps[1].command, startsWith(setup));
      expect(
        steps[1].command,
        contains('\napt-get -o Acquire::Lock::Timeout=600 update -y'),
      );
      expect(setup.endsWith('\n'), isTrue);
    });

    test('maps named mirrors per ABI: ports for ARM, ubuntu for amd64', () {
      expect(
        LinuxSandboxService.aptMirrorBaseUrls['armeabi-v7a']?['tuna'],
        'https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports',
      );
      expect(
        LinuxSandboxService.aptMirrorBaseUrls['arm64-v8a']?['aliyun'],
        'https://mirrors.aliyun.com/ubuntu-ports',
      );
      expect(
        LinuxSandboxService.aptMirrorBaseUrls['x86_64']?['tuna'],
        'https://mirrors.tuna.tsinghua.edu.cn/ubuntu',
      );
    });
  });

  group('LinuxSandboxService.resolveAptMirrorFor', () {
    test('resolves a named mirror for the ABI', () {
      expect(
        LinuxSandboxService.resolveAptMirrorFor(
          abi: 'armeabi-v7a',
          pref: const DependencyInstallPref(sourceId: 'tuna'),
        ),
        (
          base: 'https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports',
          security: 'https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports',
        ),
      );
      expect(
        LinuxSandboxService.resolveAptMirrorFor(
          abi: 'x86_64',
          pref: const DependencyInstallPref(sourceId: 'aliyun'),
        ),
        (
          base: 'https://mirrors.aliyun.com/ubuntu',
          security: 'https://mirrors.aliyun.com/ubuntu',
        ),
      );
    });

    test('auto and official restore the ABI official archive', () {
      for (final source in ['auto', 'official']) {
        expect(
          LinuxSandboxService.resolveAptMirrorFor(
            abi: 'arm64-v8a',
            pref: DependencyInstallPref(sourceId: source),
          ),
          (
            base: 'http://ports.ubuntu.com/ubuntu-ports',
            security: 'http://ports.ubuntu.com/ubuntu-ports',
          ),
        );
      }
    });

    test('amd64 official splits the security suite', () {
      expect(
        LinuxSandboxService.resolveAptMirrorFor(
          abi: 'x86_64',
          pref: const DependencyInstallPref(sourceId: 'official'),
        ),
        (
          base: 'http://archive.ubuntu.com/ubuntu',
          security: 'http://security.ubuntu.com/ubuntu',
        ),
      );
    });

    test('unknown named sources restore the official archive', () {
      expect(
        LinuxSandboxService.resolveAptMirrorFor(
          abi: 'arm64-v8a',
          pref: const DependencyInstallPref(sourceId: 'somebody'),
        ),
        (
          base: 'http://ports.ubuntu.com/ubuntu-ports',
          security: 'http://ports.ubuntu.com/ubuntu-ports',
        ),
      );
    });

    test('custom URL is used after sanitization', () {
      expect(
        LinuxSandboxService.resolveAptMirrorFor(
          abi: 'arm64-v8a',
          pref: const DependencyInstallPref(
            sourceId: 'custom',
            customUrl: 'https://mirror.example/ubuntu-ports',
          ),
        ),
        (
          base: 'https://mirror.example/ubuntu-ports',
          security: 'https://mirror.example/ubuntu-ports',
        ),
      );
    });

    test(
      'a mirror set by one dependency never leaks into the next install',
      () {
        // Sequence regression (issue #531 review): dependency 1 picks TUNA,
        // dependency 2 picks Official — the generated sources must restore
        // ports.ubuntu.com, not keep the TUNA rewrite the first install left
        // in the workspace-global deb822 file.
        final first = LinuxSandboxService.resolveAptMirrorFor(
          abi: 'armeabi-v7a',
          pref: const DependencyInstallPref(sourceId: 'tuna'),
        );
        final second = LinuxSandboxService.resolveAptMirrorFor(
          abi: 'armeabi-v7a',
          pref: const DependencyInstallPref(sourceId: 'official'),
        );
        expect(first.base, contains('tuna'));
        expect(second.base, 'http://ports.ubuntu.com/ubuntu-ports');
        expect(
          LinuxSandboxService.aptMirrorSetup(second.base),
          contains('URIs: http://ports.ubuntu.com/ubuntu-ports/'),
        );
      },
    );

    test('malformed custom URL throws instead of silently falling back', () {
      expect(
        () => LinuxSandboxService.resolveAptMirrorFor(
          abi: 'arm64-v8a',
          pref: const DependencyInstallPref(
            sourceId: 'custom',
            customUrl: 'https://mirror.example/ubuntu; rm -rf /',
          ),
        ),
        throwsStateError,
      );
    });

    test('empty custom URL restores the official archive', () {
      expect(
        LinuxSandboxService.resolveAptMirrorFor(
          abi: 'arm64-v8a',
          pref: const DependencyInstallPref(sourceId: 'custom'),
        ),
        (
          base: 'http://ports.ubuntu.com/ubuntu-ports',
          security: 'http://ports.ubuntu.com/ubuntu-ports',
        ),
      );
    });
  });
}
