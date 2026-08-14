import 'package:Cuplivo/core/services/workspace/linux_sandbox_service.dart';
import 'package:Cuplivo/core/services/workspace/workspace_terminal_session.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSession implements WorkspaceTerminalSessionPort {
  int closeCount = 0;
  int startCount = 0;
  int writeCount = 0;

  @override
  Future<void> start(
    SandboxPtyLaunchSpec spec, {
    required int rows,
    required int columns,
  }) async {
    startCount += 1;
  }

  @override
  void write(List<int> data) {
    writeCount += 1;
  }

  @override
  void resize({required int rows, required int columns}) {}

  @override
  Stream<List<int>> get output => const Stream<List<int>>.empty();

  @override
  Future<int> get exitCode => Future<int>.value(0);

  @override
  Future<void> close() async {
    closeCount += 1;
  }
}

SandboxPtyLaunchSpec _spec() => const SandboxPtyLaunchSpec(
  executable: '/bin/bash',
  arguments: ['-l'],
  environment: {'TERM': 'xterm-256color'},
  workingDirectory: '/tmp',
);

void main() {
  test('dispose closes the session once', () async {
    final fake = _FakeSession();
    final controller = WorkspaceTerminalController(session: fake);
    await controller.dispose();
    await controller.dispose();
    expect(controller.closed, isTrue);
    expect(fake.closeCount, 1);
  });

  test('stop does not mark controller closed so start can retry', () async {
    final fake = _FakeSession();
    final controller = WorkspaceTerminalController(session: fake);
    await controller.stop();
    await controller.start(_spec(), rows: 24, columns: 80);
    expect(controller.closed, isFalse);
    expect(fake.closeCount, 1);
    expect(fake.startCount, 1);
    await controller.dispose();
    expect(fake.closeCount, 2);
  });

  test('start and write are rejected after dispose', () async {
    final fake = _FakeSession();
    final controller = WorkspaceTerminalController(session: fake);
    await controller.dispose();
    expect(
      () => controller.start(_spec(), rows: 24, columns: 80),
      throwsStateError,
    );
    controller.write([1]);
    expect(fake.startCount, 0);
    expect(fake.writeCount, 0);
  });

  test('fromChannelMap rejects missing arguments and environment', () {
    expect(
      () => SandboxPtyLaunchSpec.fromChannelMap({
        'executable': '/proot',
      }, fallbackWorkingDirectory: '/ws'),
      throwsStateError,
    );
    expect(
      () => SandboxPtyLaunchSpec.fromChannelMap({
        'executable': '/proot',
        'arguments': <String>['-l'],
      }, fallbackWorkingDirectory: '/ws'),
      throwsStateError,
    );
  });

  test('fromChannelMap parses a valid payload', () {
    final spec = SandboxPtyLaunchSpec.fromChannelMap({
      'executable': '/proot',
      'arguments': ['--root-id', '/bin/bash', '-l'],
      'environment': {'PROOT_LOADER': '/loader'},
      'workingDirectory': '/ws',
    }, fallbackWorkingDirectory: '/fallback');
    expect(spec.executable, '/proot');
    expect(spec.arguments, ['--root-id', '/bin/bash', '-l']);
    expect(spec.environment['PROOT_LOADER'], '/loader');
    expect(spec.workingDirectory, '/ws');
  });

  test('parseVolumeCtrlEvent rejects non-bool', () {
    expect(SandboxPtyLaunchSpec.parseVolumeCtrlEvent(true), isTrue);
    expect(SandboxPtyLaunchSpec.parseVolumeCtrlEvent(false), isFalse);
    expect(
      () => SandboxPtyLaunchSpec.parseVolumeCtrlEvent('true'),
      throwsStateError,
    );
  });
}
