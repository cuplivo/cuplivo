import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/features/linux_sandbox/models/linux_sandbox.dart';
import 'package:Cuplivo/features/linux_sandbox/services/sandbox_runtime.dart';
import 'package:Cuplivo/features/linux_sandbox/services/sandbox_tools_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingRuntime implements SandboxRuntime {
  final List<String> calls = <String>[];

  @override
  String get sandboxId => 'fake';

  @override
  bool get isSupported => true;

  @override
  LinuxSandboxRuntimeMode get runtimeMode => LinuxSandboxRuntimeMode.wsl;

  @override
  Future<void> ensureReady() async {
    calls.add('ensureReady');
  }

  @override
  Future<SandboxInstallResult> installBaseEnv({
    void Function(double? progress, String stage)? onProgress,
  }) async {
    calls.add('installBaseEnv');
    return SandboxInstallResult.success(runtimeMode);
  }

  @override
  Future<LinuxSandboxStatus> probeStatus() async => LinuxSandboxStatus.ready;

  @override
  Future<Directory> rootDirectory() async {
    throw UnimplementedError();
  }

  @override
  Future<SandboxToolResult> read(String path) async {
    calls.add('read:$path');
    return SandboxToolResult.success('content:$path');
  }

  @override
  Future<SandboxToolResult> write(String path, String content) async {
    calls.add('write:$path:$content');
    return SandboxToolResult.success('ok');
  }

  @override
  Future<SandboxToolResult> edit(
    String path,
    String oldString,
    String newString,
  ) async {
    calls.add('edit:$path:$oldString->$newString');
    return SandboxToolResult.success('edited');
  }

  @override
  Future<SandboxToolResult> shell(String command, {Duration? timeout}) async {
    calls.add('shell:$command:${timeout?.inSeconds}');
    return SandboxToolResult.success('out', exitCode: 0);
  }

  @override
  Future<List<SandboxFsEntry>> listDir([String path = '']) async =>
      const <SandboxFsEntry>[];

  @override
  Future<void> destroyDisk() async {}
}

LinuxSandbox _readySandbox({
  Map<String, LinuxSandboxToolConfig>? tools,
  LinuxSandboxRuntimeMode mode = LinuxSandboxRuntimeMode.wsl,
}) {
  return LinuxSandbox(
    id: '1',
    name: 's',
    status: LinuxSandboxStatus.ready,
    runtimeMode: mode,
    tools: tools,
  );
}

void main() {
  group('SandboxToolsService', () {
    test('isSandboxTool recognizes only sandbox tools', () {
      expect(
        SandboxToolsService.isSandboxTool(LinuxSandboxToolNames.read),
        isTrue,
      );
      expect(
        SandboxToolsService.isSandboxTool(LinuxSandboxToolNames.shell),
        isTrue,
      );
      expect(SandboxToolsService.isSandboxTool('clipboard_tool'), isFalse);
    });

    test('toolNeedsApproval respects config', () {
      final sandbox = _readySandbox();
      expect(
        SandboxToolsService.toolNeedsApproval(
          sandbox,
          LinuxSandboxToolNames.read,
        ),
        isFalse,
      );
      expect(
        SandboxToolsService.toolNeedsApproval(
          sandbox,
          LinuxSandboxToolNames.write,
        ),
        isTrue,
      );
    });

    test('buildToolDefinitions empty without sandbox or tools support', () {
      expect(
        SandboxToolsService.buildToolDefinitions(
          sandbox: null,
          supportsTools: true,
        ),
        isEmpty,
      );
      expect(
        SandboxToolsService.buildToolDefinitions(
          sandbox: _readySandbox(),
          supportsTools: false,
        ),
        isEmpty,
      );
    });

    test('buildToolDefinitions empty when status is not ready', () {
      for (final status in [
        LinuxSandboxStatus.notReady,
        LinuxSandboxStatus.installing,
        LinuxSandboxStatus.broken,
        LinuxSandboxStatus.disabled,
      ]) {
        final defs = SandboxToolsService.buildToolDefinitions(
          sandbox: LinuxSandbox(id: '1', name: 's', status: status),
          supportsTools: true,
        );
        expect(defs, isEmpty, reason: 'status=$status');
      }
    });

    test('buildToolDefinitions includes enabled tools only when ready', () {
      final sandbox = _readySandbox(
        tools: {
          ...LinuxSandbox.defaultTools(),
          LinuxSandboxToolNames.shell: const LinuxSandboxToolConfig(
            enabled: false,
            needsApproval: true,
          ),
        },
      );
      final defs = SandboxToolsService.buildToolDefinitions(
        sandbox: sandbox,
        supportsTools: true,
      );
      final names = defs
          .map((d) => (d['function'] as Map)['name'] as String)
          .toList();
      expect(names, contains(LinuxSandboxToolNames.read));
      expect(names, contains(LinuxSandboxToolNames.write));
      expect(names, contains(LinuxSandboxToolNames.edit));
      expect(names, isNot(contains(LinuxSandboxToolNames.shell)));
    });

    test('buildToolDefinitions wsl shell copy mentions WSL Linux', () {
      final defs = SandboxToolsService.buildToolDefinitions(
        sandbox: _readySandbox(mode: LinuxSandboxRuntimeMode.wsl),
        supportsTools: true,
      );
      final shell = defs.firstWhere(
        (d) => (d['function'] as Map)['name'] == LinuxSandboxToolNames.shell,
      );
      final desc = (shell['function'] as Map)['description'] as String;
      expect(desc.toLowerCase(), contains('wsl'));
      expect(desc.toLowerCase(), contains('linux'));
    });

    test('buildToolDefinitions localJail shell copy stays honest if used', () {
      final defs = SandboxToolsService.buildToolDefinitions(
        sandbox: _readySandbox(mode: LinuxSandboxRuntimeMode.localJail),
        supportsTools: true,
      );
      final shell = defs.firstWhere(
        (d) => (d['function'] as Map)['name'] == LinuxSandboxToolNames.shell,
      );
      final desc = (shell['function'] as Map)['description'] as String;
      expect(desc.toLowerCase(), contains('not a linux'));
      expect(desc.toLowerCase(), contains('folder jail'));
    });

    test('tryHandleToolCall returns null for non-sandbox tools', () async {
      final result = await SandboxToolsService.tryHandleToolCall(
        name: 'clipboard_tool',
        args: const {},
        sandbox: _readySandbox(),
        runtime: _RecordingRuntime(),
      );
      expect(result, isNull);
    });

    test(
      'tryHandleToolCall dispatches read/write/edit/shell when ready',
      () async {
        final runtime = _RecordingRuntime();
        final sandbox = _readySandbox();

        final read = await SandboxToolsService.tryHandleToolCall(
          name: LinuxSandboxToolNames.read,
          args: {'path': 'a.txt'},
          sandbox: sandbox,
          runtime: runtime,
        );
        expect(jsonDecode(read!)['content'], 'content:a.txt');

        final write = await SandboxToolsService.tryHandleToolCall(
          name: LinuxSandboxToolNames.write,
          args: {'path': 'a.txt', 'content': 'hi'},
          sandbox: sandbox,
          runtime: runtime,
        );
        expect(jsonDecode(write!)['ok'], isTrue);

        final edit = await SandboxToolsService.tryHandleToolCall(
          name: LinuxSandboxToolNames.edit,
          args: {'path': 'a.txt', 'old_string': 'a', 'new_string': 'b'},
          sandbox: sandbox,
          runtime: runtime,
        );
        expect(jsonDecode(edit!)['ok'], isTrue);

        final shell = await SandboxToolsService.tryHandleToolCall(
          name: LinuxSandboxToolNames.shell,
          args: {'command': 'echo hi', 'timeout_seconds': 10},
          sandbox: sandbox,
          runtime: runtime,
        );
        expect(jsonDecode(shell!)['exit_code'], 0);

        expect(runtime.calls, contains('ensureReady'));
        expect(runtime.calls, contains('read:a.txt'));
        expect(runtime.calls, contains('write:a.txt:hi'));
        expect(runtime.calls, contains('edit:a.txt:a->b'));
        expect(runtime.calls, contains('shell:echo hi:10'));
      },
    );

    test('tryHandleToolCall gates on status', () async {
      final runtime = _RecordingRuntime();

      Future<String> errorFor(LinuxSandboxStatus status) async {
        final raw = await SandboxToolsService.tryHandleToolCall(
          name: LinuxSandboxToolNames.read,
          args: {'path': 'x'},
          sandbox: LinuxSandbox(id: '1', name: 's', status: status),
          runtime: runtime,
        );
        return (jsonDecode(raw!) as Map)['error'] as String;
      }

      expect(await errorFor(LinuxSandboxStatus.notReady), 'sandbox_not_ready');
      expect(await errorFor(LinuxSandboxStatus.disabled), 'sandbox_not_ready');
      expect(
        await errorFor(LinuxSandboxStatus.installing),
        'sandbox_installing',
      );
      expect(await errorFor(LinuxSandboxStatus.broken), 'sandbox_broken');
      expect(runtime.calls, isEmpty);
    });

    test('tryHandleToolCall reports disabled tool', () async {
      final sandbox = _readySandbox(
        tools: {
          ...LinuxSandbox.defaultTools(),
          LinuxSandboxToolNames.read: const LinuxSandboxToolConfig(
            enabled: false,
            needsApproval: false,
          ),
        },
      );
      final raw = await SandboxToolsService.tryHandleToolCall(
        name: LinuxSandboxToolNames.read,
        args: {'path': 'x'},
        sandbox: sandbox,
        runtime: _RecordingRuntime(),
      );
      final map = jsonDecode(raw!) as Map<String, dynamic>;
      expect(map['error'], 'tool_disabled');
    });
  });
}
