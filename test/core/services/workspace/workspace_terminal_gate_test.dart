import 'package:Cuplivo/core/services/workspace/linux_sandbox_service.dart';
import 'package:Cuplivo/core/services/workspace/workspace_terminal_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS is androidOnly', () {
    expect(
      WorkspaceTerminalAdmission.evaluate(
        isAndroid: false,
        isIOS: true,
        readOnly: false,
        status: SandboxStatus.ready,
      ),
      WorkspaceTerminalGate.androidOnly,
    );
  });

  test('desktop is unsupported', () {
    expect(
      WorkspaceTerminalAdmission.evaluate(
        isAndroid: false,
        isIOS: false,
        readOnly: false,
        status: SandboxStatus.unsupported,
      ),
      WorkspaceTerminalGate.unsupported,
    );
  });

  test('desktop stays unsupported even when sandbox looks ready', () {
    expect(
      WorkspaceTerminalAdmission.evaluate(
        isAndroid: false,
        isIOS: false,
        readOnly: true,
        status: SandboxStatus.ready,
      ),
      WorkspaceTerminalGate.unsupported,
    );
  });

  test('readOnly wins over ready', () {
    expect(
      WorkspaceTerminalAdmission.evaluate(
        isAndroid: true,
        isIOS: false,
        readOnly: true,
        status: SandboxStatus.ready,
      ),
      WorkspaceTerminalGate.readOnly,
    );
  });

  test('Android disabled is baseMissing', () {
    expect(
      WorkspaceTerminalAdmission.evaluate(
        isAndroid: true,
        isIOS: false,
        readOnly: false,
        status: SandboxStatus.disabled,
      ),
      WorkspaceTerminalGate.baseMissing,
    );
  });

  test('Android runtimeMissing', () {
    expect(
      WorkspaceTerminalAdmission.evaluate(
        isAndroid: true,
        isIOS: false,
        readOnly: false,
        status: SandboxStatus.runtimeMissing,
      ),
      WorkspaceTerminalGate.runtimeMissing,
    );
  });

  test('Android broken', () {
    expect(
      WorkspaceTerminalAdmission.evaluate(
        isAndroid: true,
        isIOS: false,
        readOnly: false,
        status: SandboxStatus.broken,
      ),
      WorkspaceTerminalGate.broken,
    );
  });

  test('Android installing is baseMissing', () {
    expect(
      WorkspaceTerminalAdmission.evaluate(
        isAndroid: true,
        isIOS: false,
        readOnly: false,
        status: SandboxStatus.installing,
      ),
      WorkspaceTerminalGate.baseMissing,
    );
  });

  test('Android unsupported status is androidOnly', () {
    expect(
      WorkspaceTerminalAdmission.evaluate(
        isAndroid: true,
        isIOS: false,
        readOnly: false,
        status: SandboxStatus.unsupported,
      ),
      WorkspaceTerminalGate.androidOnly,
    );
  });

  test('Android ready and writable is ready', () {
    expect(
      WorkspaceTerminalAdmission.evaluate(
        isAndroid: true,
        isIOS: false,
        readOnly: false,
        status: SandboxStatus.ready,
      ),
      WorkspaceTerminalGate.ready,
    );
  });
}
