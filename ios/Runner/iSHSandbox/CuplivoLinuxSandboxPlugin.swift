//
//  CuplivoLinuxSandboxPlugin.swift
//  Runner
//
//  iOS bridge for the Linux sandbox, mirroring the Android
//  LinuxSandboxPlugin contract on the same MethodChannel. Rootfs download
//  orchestration lives in Dart on Android; on iOS the rootfs ships in the
//  app bundle and is extracted here.
//

import Flutter
import Foundation

final class CuplivoLinuxSandboxPlugin: NSObject {
  static let channelName = "cuplivo/linux_sandbox"

  private let queue = DispatchQueue(label: "com.cuplivo.linux_sandbox", qos: .userInitiated)
  private var channel: FlutterMethodChannel?
  private var mountedWorkspaceHostPath: String?

  @discardableResult
  static func register(messenger: FlutterBinaryMessenger) -> CuplivoLinuxSandboxPlugin {
    let plugin = CuplivoLinuxSandboxPlugin()
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak plugin] call, result in
      plugin?.handle(call, result: result)
    }
    plugin.channel = channel
    return plugin
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      // The iSH libraries are statically linked; if this channel answers at
      // all, the runtime is present.
      result(true)
    case "getAbi":
      result("arm64-v8a")
    case "isBooted":
      result(CuplivoISHKernel.shared().isBooted)
    case "installBase":
      installBase(call: call, result: result)
    case "exec":
      exec(call: call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - installBase

  private func installBase(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    guard let rootfsPath = (args["rootfsPath"] as? String)?.trimmingCharacters(in: .whitespaces),
      !rootfsPath.isEmpty
    else {
      result(FlutterError(code: "bad_args", message: "rootfsPath required", details: nil))
      return
    }
    // The kernel boots exactly once per process against one fakefs tree.
    // Reinstalling while booted would leave a stale mount; require relaunch.
    if CuplivoISHKernel.shared().isBooted {
      result(
        FlutterError(
          code: "booted_restart_required",
          message: "Sandbox is running; restart the app to reinstall the base.",
          details: nil))
      return
    }
    queue.async {
      // FlutterResult must be called on the platform (main) thread; this
      // queue is a background serial queue, so marshal the completion.
      let complete: (Any?) -> Void = { value in
        DispatchQueue.main.async { result(value) }
      }
      do {
        try CuplivoSandboxRootfsInstaller.install(to: URL(fileURLWithPath: rootfsPath))
        complete(nil)
      } catch {
        NSLog("CuplivoLinuxSandboxPlugin: installBase failed: \(error)")
        complete(
          FlutterError(
            code: "extract_failed", message: error.localizedDescription, details: nil))
      }
    }
  }

  // MARK: - exec

  private func exec(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    guard
      let workspacePath = (args["workspacePath"] as? String)?
        .trimmingCharacters(in: .whitespaces),
      !workspacePath.isEmpty,
      let command = args["command"] as? String, !command.isEmpty,
      let rootfsPath = (args["rootfsPath"] as? String)?
        .trimmingCharacters(in: .whitespaces), !rootfsPath.isEmpty
    else {
      result(
        FlutterError(
          code: "bad_args",
          message: "workspacePath, command and rootfsPath required",
          details: nil))
      return
    }
    let cwd = args["cwd"] as? String
    let timeoutMs = (args["timeoutMs"] as? NSNumber)?.doubleValue ?? 30_000

    queue.async { [weak self] in
      guard let self else { return }

      // FlutterResult must be called on the platform (main) thread; this
      // queue and the executor callback are background threads, so marshal
      // every completion through the main queue.
      let complete: (Any?) -> Void = { value in
        DispatchQueue.main.async { result(value) }
      }

      let metaDb = URL(fileURLWithPath: rootfsPath).appendingPathComponent("meta.db")
      guard FileManager.default.fileExists(atPath: metaDb.path) else {
        complete(
          FlutterError(
            code: "rootfs_missing",
            message: "rootfs not installed at \(rootfsPath)",
            details: nil))
        return
      }

      let kernel = CuplivoISHKernel.shared()
      if !kernel.isBooted {
        let err = kernel.boot(withRootPath: rootfsPath)
        if err < 0 {
          complete(
            FlutterError(
              code: "boot_failed",
              message: "iSH kernel boot failed: \(err)",
              details: nil))
          return
        }
      } else if kernel.bootRootPath != rootfsPath {
        complete(
          FlutterError(
            code: "boot_path_mismatch",
            message: "kernel already booted with a different rootfs; restart the app",
            details: nil))
        return
      }

      // Bind-mount the workspace host directory onto /workspace (rebinds
      // when switching workspaces; fakefs updates the slot in place).
      if self.mountedWorkspaceHostPath != workspacePath {
        let mountErr = kernel.bindMountPath("/workspace", toHostPath: workspacePath)
        if mountErr < 0 {
          complete(
            FlutterError(
              code: "mount_failed",
              message: "failed to mount workspace into guest: \(mountErr)",
              details: nil))
          return
        }
        self.mountedWorkspaceHostPath = workspacePath
      }

      // Guest cwd mapping mirrors Android's GuestCommandRunner.
      let guestCwd: String
      let trimmedCwd = cwd?.trimmingCharacters(in: .whitespaces) ?? ""
      if trimmedCwd.isEmpty {
        guestCwd = "/workspace"
      } else if trimmedCwd.hasPrefix("/workspace") {
        guestCwd = trimmedCwd
      } else {
        var rel = trimmedCwd
        while (rel.hasPrefix("/")) { rel.removeFirst() }
        guestCwd = "/workspace/\(rel)"
      }

      CuplivoISHExecutor.executeCommand(
        command,
        cwd: guestCwd,
        timeout: timeoutMs / 1000.0
      ) { execResult in
        complete(execResult)
      }
    }
  }
}
