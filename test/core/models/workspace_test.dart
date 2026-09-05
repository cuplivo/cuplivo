import 'package:Cuplivo/core/models/workspace.dart';
import 'package:Cuplivo/core/services/workspace/linux_sandbox_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default tools are read write patch', () {
    final ws = Workspace.createDefault();
    expect(ws.isToolEnabled(WorkspaceToolNames.read), isTrue);
    expect(ws.isToolEnabled(WorkspaceToolNames.write), isTrue);
    expect(ws.isToolEnabled(WorkspaceToolNames.patch), isTrue);
    expect(ws.isToolEnabled(WorkspaceToolNames.glob), isFalse);
    expect(ws.isToolEnabled(WorkspaceToolNames.download), isFalse);
    expect(ws.isToolEnabled(WorkspaceToolNames.shell), isFalse);
    expect(ws.isToolNeedsApproval(WorkspaceToolNames.delete), isTrue);
    expect(ws.isToolNeedsApproval(WorkspaceToolNames.shell), isTrue);
    expect(ws.isToolNeedsApproval(WorkspaceToolNames.download), isFalse);
    expect(ws.isToolNeedsApproval(WorkspaceToolNames.read), isFalse);
    expect(ws.alias, Workspace.defaultAlias);
    expect(ws.keepTerminalAfterExit, isFalse);
    expect(ws.terminalPersistentKeepAlive, isFalse);
    expect(ws.autoStartLinuxSandbox, isFalse);
  });

  group('workspace dependency prerequisites', () {
    test('keeps the dependency catalog in the required install order', () {
      expect(WorkspaceDependencyIds.ordered, <String>[
        WorkspaceDependencyIds.base,
        WorkspaceDependencyIds.python,
        WorkspaceDependencyIds.nodejs,
        WorkspaceDependencyIds.git,
        WorkspaceDependencyIds.githubCli,
        WorkspaceDependencyIds.curl,
        WorkspaceDependencyIds.opensshClient,
        WorkspaceDependencyIds.archive,
        WorkspaceDependencyIds.office,
        WorkspaceDependencyIds.buildEssential,
      ]);
    });

    test('office requires both Python and Node.js', () {
      expect(
        WorkspaceDependencyIds.missingPrerequisites(
          WorkspaceDependencyIds.office,
          const <String, bool>{},
        ),
        <String>[WorkspaceDependencyIds.python, WorkspaceDependencyIds.nodejs],
      );
      expect(
        WorkspaceDependencyIds.missingPrerequisites(
          WorkspaceDependencyIds.office,
          const <String, bool>{WorkspaceDependencyIds.nodejs: true},
        ),
        <String>[WorkspaceDependencyIds.python],
      );
      expect(
        WorkspaceDependencyIds.missingPrerequisites(
          WorkspaceDependencyIds.office,
          const <String, bool>{WorkspaceDependencyIds.python: true},
        ),
        <String>[WorkspaceDependencyIds.nodejs],
      );
      expect(
        WorkspaceDependencyIds.missingPrerequisites(
          WorkspaceDependencyIds.office,
          const <String, bool>{
            WorkspaceDependencyIds.python: true,
            WorkspaceDependencyIds.nodejs: true,
          },
        ),
        isEmpty,
      );
    });

    test('GitHub CLI requires Git', () {
      expect(
        WorkspaceDependencyIds.missingPrerequisites(
          WorkspaceDependencyIds.githubCli,
          const <String, bool>{},
        ),
        <String>[WorkspaceDependencyIds.git],
      );
      expect(
        WorkspaceDependencyIds.missingPrerequisites(
          WorkspaceDependencyIds.githubCli,
          const <String, bool>{WorkspaceDependencyIds.git: true},
        ),
        isEmpty,
      );
    });
  });

  test('json roundtrip preserves tools prefs and approvals', () {
    final ws = Workspace.createDefault().copyWith(
      displayName: '测试',
      tools: {
        for (final t in WorkspaceToolNames.filesystemTools) t: true,
        WorkspaceToolNames.shell: true,
      },
      toolApprovals: {
        for (final t in WorkspaceToolNames.allTools) t: false,
        WorkspaceToolNames.write: true,
      },
      shellEnabled: true,
      keepTerminalAfterExit: true,
      terminalPersistentKeepAlive: true,
      autoStartLinuxSandbox: true,
      safMounts: const [
        WorkspaceSafMount(
          id: 'mount-id',
          alias: 'notes',
          uri: 'content://tree/notes',
          displayName: 'Notes',
        ),
      ],
      dependencyPrefs: {
        WorkspaceDependencyIds.python: const DependencyInstallPref(
          sourceId: 'tuna',
        ),
      },
    );
    final back = Workspace.fromJson(ws.toJson());
    expect(back.displayName, '测试');
    expect(back.isToolEnabled(WorkspaceToolNames.write), isTrue);
    expect(back.shellEnabled, isTrue);
    expect(back.keepTerminalAfterExit, isTrue);
    expect(back.terminalPersistentKeepAlive, isTrue);
    expect(back.autoStartLinuxSandbox, isTrue);
    expect(back.prefFor(WorkspaceDependencyIds.python).sourceId, 'tuna');
    expect(back.isToolNeedsApproval(WorkspaceToolNames.write), isTrue);
    expect(back.isToolNeedsApproval(WorkspaceToolNames.delete), isFalse);
    expect(back.safMounts, hasLength(1));
    expect(back.safMounts.single.id, 'mount-id');
    expect(back.safMounts.single.alias, 'notes');
    expect(back.safMounts.single.uri, 'content://tree/notes');
  });

  test('legacy workspace json without SAF mounts loads an empty list', () {
    final ws = Workspace.fromJson({
      'id': 'legacy',
      'displayName': 'Legacy',
      'alias': 'legacy',
    });
    expect(ws.safMounts, isEmpty);
    expect(ws.keepTerminalAfterExit, isFalse);
    expect(ws.terminalPersistentKeepAlive, isFalse);
    expect(ws.autoStartLinuxSandbox, isFalse);
  });

  test('terminal child flags are normalized off when parent is disabled', () {
    final ws = Workspace.fromJson({
      'id': 'invalid-terminal-settings',
      'displayName': 'Invalid',
      'alias': 'invalid',
      'keepTerminalAfterExit': false,
      'terminalPersistentKeepAlive': true,
      'autoStartLinuxSandbox': true,
    });

    expect(ws.keepTerminalAfterExit, isFalse);
    expect(ws.terminalPersistentKeepAlive, isFalse);
    expect(ws.autoStartLinuxSandbox, isFalse);
    expect(ws.toJson()['terminalPersistentKeepAlive'], isFalse);
    expect(ws.toJson()['autoStartLinuxSandbox'], isFalse);
  });

  test('copyWith parent-off cascades both terminal child flags', () {
    final ws = Workspace.createDefault().copyWith(
      keepTerminalAfterExit: true,
      terminalPersistentKeepAlive: true,
      autoStartLinuxSandbox: true,
    );
    final disabled = ws.copyWith(keepTerminalAfterExit: false);

    expect(disabled.keepTerminalAfterExit, isFalse);
    expect(disabled.terminalPersistentKeepAlive, isFalse);
    expect(disabled.autoStartLinuxSandbox, isFalse);
  });

  test('legacy kelivo tool keys map to short names', () {
    final ws = Workspace.fromJson({
      'id': 'x',
      'displayName': 'D',
      'alias': 'default',
      'tools': {'kelivo_read': true, 'kelivo_write_file': true},
    });
    expect(ws.isToolEnabled(WorkspaceToolNames.read), isTrue);
    expect(ws.isToolEnabled(WorkspaceToolNames.write), isTrue);
  });

  test('rootfs source official resolves only official url', () {
    final urls = LinuxSandboxService.resolveRootfsUrls(
      abi: 'arm64-v8a',
      pref: const DependencyInstallPref(sourceId: 'official'),
    );
    expect(urls, hasLength(1));
    expect(urls.single, contains('cdimage.ubuntu.com'));
    expect(urls.single, isNot(contains('aliyun')));
  });

  test('rootfs source auto lists official then mirrors', () {
    final urls = LinuxSandboxService.resolveRootfsUrls(
      abi: 'arm64-v8a',
      pref: const DependencyInstallPref(sourceId: 'auto'),
    );
    expect(urls.length, 3);
    expect(urls.first, contains('cdimage.ubuntu.com'));
    expect(urls[1], contains('tuna.tsinghua'));
    expect(urls[2], contains('aliyun'));
  });

  test('rootfs source aliyun is single aliyun url', () {
    final urls = LinuxSandboxService.resolveRootfsUrls(
      abi: 'arm64-v8a',
      pref: const DependencyInstallPref(sourceId: 'aliyun'),
    );
    expect(urls, hasLength(1));
    expect(urls.single, contains('aliyun'));
  });

  test('armeabi-v7a rootfs auto sources all use Ubuntu armhf', () {
    final urls = LinuxSandboxService.resolveRootfsUrls(
      abi: 'armeabi-v7a',
      pref: const DependencyInstallPref(sourceId: 'auto'),
    );
    expect(urls, hasLength(3));
    expect(urls, everyElement(contains('base-armhf.tar.gz')));
  });

  test('armeabi-v7a named rootfs sources retain the selected mirror', () {
    const expectedHosts = {
      'official': 'cdimage.ubuntu.com',
      'tuna': 'tuna.tsinghua.edu.cn',
      'aliyun': 'mirrors.aliyun.com',
    };
    for (final entry in expectedHosts.entries) {
      final urls = LinuxSandboxService.resolveRootfsUrls(
        abi: 'armeabi-v7a',
        pref: DependencyInstallPref(sourceId: entry.key),
      );
      expect(urls, hasLength(1));
      expect(urls.single, contains(entry.value));
      expect(urls.single, contains('base-armhf.tar.gz'));
    }
  });

  test('64-bit rootfs source architecture mappings are unchanged', () {
    final arm64 = LinuxSandboxService.resolveRootfsUrls(
      abi: 'arm64-v8a',
      pref: const DependencyInstallPref(sourceId: 'official'),
    );
    final x86 = LinuxSandboxService.resolveRootfsUrls(
      abi: 'x86_64',
      pref: const DependencyInstallPref(sourceId: 'official'),
    );
    expect(arm64.single, contains('base-arm64.tar.gz'));
    expect(x86.single, contains('base-amd64.tar.gz'));
  });
}
