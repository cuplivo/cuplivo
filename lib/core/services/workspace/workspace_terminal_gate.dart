import 'linux_sandbox_service.dart';

enum WorkspaceTerminalGate {
  ready,
  androidOnly,
  unsupported,
  readOnly,
  runtimeMissing,
  baseMissing,
  broken,
}

class WorkspaceTerminalAdmission {
  const WorkspaceTerminalAdmission._();

  static WorkspaceTerminalGate evaluate({
    required bool isAndroid,
    required bool isIOS,
    required bool readOnly,
    required SandboxStatus status,
  }) {
    if (!isAndroid) {
      return isIOS
          ? WorkspaceTerminalGate.androidOnly
          : WorkspaceTerminalGate.unsupported;
    }
    if (readOnly) return WorkspaceTerminalGate.readOnly;
    switch (status) {
      case SandboxStatus.ready:
        return WorkspaceTerminalGate.ready;
      case SandboxStatus.runtimeMissing:
        return WorkspaceTerminalGate.runtimeMissing;
      case SandboxStatus.disabled:
      case SandboxStatus.installing:
        return WorkspaceTerminalGate.baseMissing;
      case SandboxStatus.broken:
        return WorkspaceTerminalGate.broken;
      case SandboxStatus.unsupported:
        return WorkspaceTerminalGate.androidOnly;
    }
  }
}
