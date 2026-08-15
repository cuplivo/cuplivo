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
  private let requestLock = NSLock()
  private var pendingRequestIds = Set<String>()
  private var cancelledRequestIds = Set<String>()

  deinit {
    cancelAllRequests()
  }

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
    case "cancel":
      cancel(call: call, result: result)
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
    let rawRequestId = (args["requestId"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let requestId = rawRequestId.flatMap { $0.isEmpty ? nil : $0 }
      ?? "ios_install_\(UUID().uuidString)"
    if !registerRequest(requestId) {
      result(
        FlutterError(
          code: "duplicate_request",
          message: "requestId is already active: \(requestId)",
          details: nil))
      return
    }
    queue.async { [weak self] in
      guard let self else { return }
      defer { self.finishRequest(requestId) }
      // FlutterResult must be called on the platform (main) thread; this
      // queue is a background serial queue, so marshal the completion.
      let complete: (Any?) -> Void = { value in
        DispatchQueue.main.async { result(value) }
      }
      if self.consumeCancellation(requestId) {
        complete(
          FlutterError(
            code: "cancelled", message: "rootfs installation cancelled", details: nil))
        return
      }
      do {
        try CuplivoSandboxRootfsInstaller.install(
          to: URL(fileURLWithPath: rootfsPath),
          isCancelled: { self.isCancelled(requestId) }
        )
        if self.isCancelled(requestId) {
          complete(
            FlutterError(
              code: "cancelled", message: "rootfs installation cancelled", details: nil))
        } else {
          complete(nil)
        }
      } catch SandboxRootfsInstallerError.cancelled {
        complete(
          FlutterError(
            code: "cancelled", message: "rootfs installation cancelled", details: nil))
      } catch {
        NSLog("CuplivoLinuxSandboxPlugin: installBase failed: \(error)")
        complete(
          FlutterError(
            code: "extract_failed", message: error.localizedDescription, details: nil))
      }
    }
  }

  // MARK: - exec

  private func cancel(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    guard let requestId = (args["requestId"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines), !requestId.isEmpty
    else {
      result(FlutterError(code: "bad_args", message: "requestId required", details: nil))
      return
    }
    let pluginCancelled = markCancelled(requestId)
    let executorCancelled = CuplivoISHExecutor.cancelRequest(requestId)
    result(pluginCancelled || executorCancelled)
  }

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
    let rawRequestId = (args["requestId"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let requestId = rawRequestId.flatMap { $0.isEmpty ? nil : $0 }
      ?? "ios_shell_\(UUID().uuidString)"
    let rawTimeout = (args["timeoutMs"] as? NSNumber)?.doubleValue ?? 30_000
    // Guard the channel boundary: NaN/Infinity would trap later at the
    // Int(timeoutMs / 1000.0) conversion.
    let timeoutMs = rawTimeout.isFinite ? min(max(rawTimeout, 1), 3_600_000) : 30_000

    if !registerRequest(requestId) {
      result(
        FlutterError(
          code: "duplicate_request",
          message: "requestId is already active: \(requestId)",
          details: nil))
      return
    }

    queue.async { [weak self] in
      guard let self else { return }
      defer { self.finishRequest(requestId) }

      // FlutterResult must be called on the platform (main) thread; this
      // queue and the executor callback are background threads, so marshal
      // every completion through the main queue.
      let completionLock = NSLock()
      var completed = false
      let complete: (Any?) -> Void = { value in
        completionLock.lock()
        guard !completed else {
          completionLock.unlock()
          return
        }
        completed = true
        completionLock.unlock()
        DispatchQueue.main.async { result(value) }
      }

      if self.consumeCancellation(requestId) {
        complete(self.cancelledResult())
        return
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

      if self.isCancelled(requestId) {
        complete(self.cancelledResult())
        return
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

      let executionFinished = DispatchSemaphore(value: 0)
      CuplivoISHExecutor.executeCommand(
        command,
        requestId: requestId,
        cwd: guestCwd,
        timeout: timeoutMs / 1000.0
      ) { execResult in
        complete(execResult)
        executionFinished.signal()
      }
      // A cancel can race the hand-off to the native executor. At this point
      // the executor has registered the queued request, so repeat the cancel
      // to close that race without running the command unchecked.
      if self.isCancelled(requestId) {
        CuplivoISHExecutor.cancelRequest(requestId)
      }
      // Keep workspace bind-mount changes and guest execution serialized as
      // one operation. The executor is also serialized, but returning here
      // would allow the next workspace to be mounted before this command
      // starts using /workspace.
      //
      // Bound the wait: the executor normally completes within timeout plus a
      // short grace. If the completion never fires (e.g. an Objective-C
      // exception inside the executor), an unbounded wait would block this
      // serial queue forever and freeze every subsequent exec and installBase.
      let waitSeconds = Int(timeoutMs / 1000.0) + 90
      let waitResult = executionFinished.wait(timeout: .now() + .seconds(waitSeconds))
      if waitResult == .timedOut {
        NSLog(
          "CuplivoLinuxSandboxPlugin: exec completion timeout for \(requestId); cancelling"
        )
        CuplivoISHExecutor.cancelRequest(requestId)
        complete(self.timeoutResult())
      }
    }
  }

  private func registerRequest(_ requestId: String) -> Bool {
    requestLock.lock()
    defer { requestLock.unlock() }
    // Reject duplicates: two concurrent operations sharing one id would
    // collapse into a single registry entry, making one of them
    // uncancellable and letting a finishRequest target the wrong operation.
    guard !pendingRequestIds.contains(requestId) else { return false }
    pendingRequestIds.insert(requestId)
    return true
  }

  private func markCancelled(_ requestId: String) -> Bool {
    requestLock.lock()
    defer { requestLock.unlock() }
    guard pendingRequestIds.contains(requestId) else { return false }
    cancelledRequestIds.insert(requestId)
    return true
  }

  private func isCancelled(_ requestId: String) -> Bool {
    requestLock.lock()
    defer { requestLock.unlock() }
    return cancelledRequestIds.contains(requestId)
  }

  private func consumeCancellation(_ requestId: String) -> Bool {
    requestLock.lock()
    defer { requestLock.unlock() }
    return cancelledRequestIds.remove(requestId) != nil
  }

  private func finishRequest(_ requestId: String) {
    requestLock.lock()
    pendingRequestIds.remove(requestId)
    cancelledRequestIds.remove(requestId)
    requestLock.unlock()
  }

  private func cancelAllRequests() {
    requestLock.lock()
    cancelledRequestIds.formUnion(pendingRequestIds)
    requestLock.unlock()
    CuplivoISHExecutor.cancelAll()
  }

  private func cancelledResult() -> [String: Any] {
    return [
      "exitCode": -1,
      "stdout": "",
      "stderr": "",
      "timedOut": false,
      "cancelled": true,
      "stdoutTruncated": false,
      "stderrTruncated": false,
    ]
  }

  private func timeoutResult() -> [String: Any] {
    return [
      "exitCode": -1,
      "stdout": "",
      "stderr": "native executor did not finish in time",
      "timedOut": true,
      "cancelled": false,
      "stdoutTruncated": false,
      "stderrTruncated": false,
    ]
  }
}
