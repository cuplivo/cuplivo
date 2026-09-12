import 'package:Cuplivo/core/models/workspace.dart';
import 'package:Cuplivo/core/services/workspace/linux_sandbox_service.dart';
import 'package:Cuplivo/core/services/workspace/sandbox_distro.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Alpine dependency package mapping', () {
    test('maps common packages to apk names', () {
      expect(
        LinuxSandboxService.packageNamesForDependency(
          WorkspaceDependencyIds.githubCli,
          family: SandboxDistroFamily.alpine,
        ),
        'github-cli',
      );
      expect(
        LinuxSandboxService.packageNamesForDependency(
          WorkspaceDependencyIds.curl,
          family: SandboxDistroFamily.alpine,
        ),
        'curl',
      );
      expect(
        LinuxSandboxService.packageNamesForDependency(
          WorkspaceDependencyIds.opensshClient,
          family: SandboxDistroFamily.alpine,
        ),
        'openssh-client-default',
      );
      expect(
        LinuxSandboxService.packageNamesForDependency(
          WorkspaceDependencyIds.archive,
          family: SandboxDistroFamily.alpine,
        ),
        'zip unzip',
      );
    });

    test('office mapping includes both zip tools', () {
      final packages = LinuxSandboxService.packageNamesForDependency(
        WorkspaceDependencyIds.office,
        family: SandboxDistroFamily.alpine,
      );

      expect(packages.split(' '), containsAll(<String>['zip', 'unzip']));
    });
  });

  group('LinuxSandboxService.buildApkInstallSteps', () {
    test('runs recover before update before install', () {
      final steps = LinuxSandboxService.buildApkInstallSteps(packages: 'git');
      expect(steps.map((s) => s.stage).toList(), [
        'recover',
        'update',
        'install',
      ]);
    });

    test('recover clears the stale apk lock', () {
      final steps = LinuxSandboxService.buildApkInstallSteps(packages: 'git');
      expect(steps.first.stage, 'recover');
      expect(steps.first.command, contains('rm -f /lib/apk/db/lock'));
    });

    test('update runs apk update without mirror setup by default', () {
      final steps = LinuxSandboxService.buildApkInstallSteps(packages: 'git');
      expect(steps[1].command, 'apk update');
    });

    test('update prepends mirror setup when provided', () {
      final mirror = LinuxSandboxService.apkMirrorSetup(
        'https://mirrors.aliyun.com/alpine',
      );
      final steps = LinuxSandboxService.buildApkInstallSteps(
        packages: 'git',
        mirrorSetup: mirror,
      );
      expect(steps[1].command, '${mirror}apk update');
    });

    test('install targets the requested packages', () {
      final steps = LinuxSandboxService.buildApkInstallSteps(
        packages: 'python3 py3-pip',
      );
      expect(steps.last.command, 'apk add python3 py3-pip');
    });

    test('uses fixed staged timeouts', () {
      final steps = LinuxSandboxService.buildApkInstallSteps(packages: 'git');
      expect(steps[0].timeoutSeconds, 120);
      expect(steps[1].timeoutSeconds, 600);
      expect(steps[2].timeoutSeconds, 1800);
    });
  });

  group('LinuxSandboxService.apkMirrorSetup', () {
    test('rewrites repositories for the bundled Alpine version', () {
      final setup = LinuxSandboxService.apkMirrorSetup(
        'https://mirrors.tuna.tsinghua.edu.cn/alpine',
      );
      expect(
        setup,
        contains(
          'https://mirrors.tuna.tsinghua.edu.cn/alpine/v'
          '${LinuxSandboxService.alpineVersion}/main',
        ),
      );
      expect(
        setup,
        contains(
          'https://mirrors.tuna.tsinghua.edu.cn/alpine/v'
          '${LinuxSandboxService.alpineVersion}/community',
        ),
      );
      expect(setup, contains('> /etc/apk/repositories'));
      expect(setup, endsWith('&& '));
    });

    test('normalizes a detected guest version to the repository branch', () {
      final setup = LinuxSandboxService.apkMirrorSetup(
        'https://mirrors.aliyun.com/alpine',
        version: '3.24.1',
      );
      expect(setup, contains('https://mirrors.aliyun.com/alpine/v3.24/main'));
      expect(
        setup,
        contains('https://mirrors.aliyun.com/alpine/v3.24/community'),
      );
      expect(setup, isNot(contains('v3.24.1')));
    });

    test('falls back to the bundled version for an injected version', () {
      final setup = LinuxSandboxService.apkMirrorSetup(
        'https://mirrors.aliyun.com/alpine',
        version: "3.24'; touch /tmp/pwned; echo '",
      );
      expect(
        setup,
        contains(
          'https://mirrors.aliyun.com/alpine/v'
          '${LinuxSandboxService.alpineVersion}/main',
        ),
      );
      expect(setup, isNot(contains('pwned')));
      expect(setup, isNot(contains('touch')));
    });
  });

  test('apkMirrorBaseUrls maps named sources only', () {
    expect(
      LinuxSandboxService.apkMirrorBaseUrls.keys,
      containsAll(['tuna', 'aliyun']),
    );
    expect(LinuxSandboxService.apkMirrorBaseUrls, isNot(contains('auto')));
    expect(LinuxSandboxService.apkMirrorBaseUrls, isNot(contains('official')));
  });

  group('LinuxSandboxService.resolveApkMirrorFor', () {
    test('resolves a named mirror', () {
      expect(
        LinuxSandboxService.resolveApkMirrorFor(
          const DependencyInstallPref(sourceId: 'aliyun'),
        ),
        'https://mirrors.aliyun.com/alpine',
      );
    });

    test('auto and official restore the official Alpine CDN', () {
      for (final source in ['auto', 'official']) {
        expect(
          LinuxSandboxService.resolveApkMirrorFor(
            DependencyInstallPref(sourceId: source),
          ),
          'https://dl-cdn.alpinelinux.org/alpine',
        );
      }
    });

    test('unknown named sources restore the official CDN', () {
      expect(
        LinuxSandboxService.resolveApkMirrorFor(
          const DependencyInstallPref(sourceId: 'somebody'),
        ),
        'https://dl-cdn.alpinelinux.org/alpine',
      );
    });

    test('custom URL is used after sanitization', () {
      expect(
        LinuxSandboxService.resolveApkMirrorFor(
          const DependencyInstallPref(
            sourceId: 'custom',
            customUrl: 'https://mirror.example/alpine',
          ),
        ),
        'https://mirror.example/alpine',
      );
    });

    test(
      'a mirror set by one dependency never leaks into the next install',
      () {
        // Sequence regression (issue #531 review, iOS parity): a named mirror
        // chosen for one dependency must not stay active when the next one
        // selects the official CDN.
        final first = LinuxSandboxService.resolveApkMirrorFor(
          const DependencyInstallPref(sourceId: 'tuna'),
        );
        final second = LinuxSandboxService.resolveApkMirrorFor(
          const DependencyInstallPref(sourceId: 'official'),
        );
        expect(first, contains('tuna'));
        expect(second, 'https://dl-cdn.alpinelinux.org/alpine');
        expect(
          LinuxSandboxService.apkMirrorSetup(second),
          contains(
            'https://dl-cdn.alpinelinux.org/alpine/v'
            '${LinuxSandboxService.alpineVersion}/main',
          ),
        );
      },
    );

    test('malformed custom URL throws instead of silently falling back', () {
      expect(
        () => LinuxSandboxService.resolveApkMirrorFor(
          const DependencyInstallPref(
            sourceId: 'custom',
            customUrl: 'https://mirror.example/alpine; rm -rf /',
          ),
        ),
        throwsStateError,
      );
    });

    test('empty custom URL restores the official CDN', () {
      expect(
        LinuxSandboxService.resolveApkMirrorFor(
          const DependencyInstallPref(sourceId: 'custom'),
        ),
        'https://dl-cdn.alpinelinux.org/alpine',
      );
    });
  });
}
