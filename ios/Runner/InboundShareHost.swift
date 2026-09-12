import Foundation
import Flutter
import UIKit

/// Host-side counterpart of the Cuplivo Share Extension. Reads the App Group
/// share inbox and delivers staged content to Dart over the
/// `app.inbound_share` channel. See CONTEXT.md → Inbound Share.
final class InboundShareHost {
  static let appGroupId = "group.com.cup11.cuplivo"

  /// Staging inboxes older than this are orphaned (the process died between
  /// the native write and the Dart import) and are deleted on the next read.
  private static let stagingTTL: TimeInterval = 24 * 60 * 60

  private let channel: FlutterMethodChannel
  private var lastDeliveredInboxPath: String?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "app.inbound_share",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "getInitialShare" else {
        result(FlutterMethodNotImplemented)
        return
      }
      if let payload = self?.pendingPayload() {
        self?.lastDeliveredInboxPath = payload["stagingDir"] as? String
        result(payload)
      } else {
        result(nil)
      }
    }
  }

  /// Called when the app is opened via `cuplivo://share` and on activation
  /// (covers the local-notification fallback, which opens the app without a
  /// URL). At most one inbox directory is delivered per call.
  func deliverPendingShare() {
    guard let payload = pendingPayload() else { return }
    let path = payload["stagingDir"] as? String
    if let path, path == lastDeliveredInboxPath { return }
    lastDeliveredInboxPath = path
    channel.invokeMethod("onShare", arguments: payload)
  }

  private func pendingPayload() -> [String: Any]? {
    guard let root = inboxRoot() else { return nil }
    let fm = FileManager.default
    guard
      let entries = try? fm.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [
          .contentModificationDateKey,
          .isDirectoryKey,
        ],
        options: [.skipsHiddenFiles]
      )
    else { return nil }

    let dirs = entries
      .filter {
        (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      }
      .sorted { lhs, rhs in
        let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate) ?? .distantPast
        let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate) ?? .distantPast
        return left < right
      }

    let cutoff = Date().addingTimeInterval(-Self.stagingTTL)
    for dir in dirs {
      let modified = (try? dir.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate) ?? .distantPast
      if modified < cutoff {
        do {
          try fm.removeItem(at: dir)
        } catch {
          NSLog(
            "Cuplivo inbound share: unable to purge stale inbox "
              + "\(dir.lastPathComponent): \(error)"
          )
        }
        continue
      }
      if let payload = buildPayload(inboxDir: dir) {
        return payload
      }
    }
    return nil
  }

  private func buildPayload(inboxDir: URL) -> [String: Any]? {
    let manifestURL = inboxDir.appendingPathComponent("manifest.json")
    guard
      let data = try? Data(contentsOf: manifestURL),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    var images: [String] = []
    for name in (json["images"] as? [String]) ?? [] {
      let url = inboxDir.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: url.path) {
        images.append(url.path)
      }
    }

    var files: [[String: Any]] = []
    for entry in (json["files"] as? [[String: Any]]) ?? [] {
      guard let name = entry["name"] as? String else { continue }
      let url = inboxDir.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      files.append([
        "path": url.path,
        "name": name,
        "mime": entry["mime"] as? String ?? "",
      ])
    }

    let text = json["text"] as? String
    if text == nil && images.isEmpty && files.isEmpty { return nil }

    var payload: [String: Any] = [
      "images": images,
      "files": files,
      "stagingDir": inboxDir.path,
    ]
    if let text { payload["text"] = text }
    return payload
  }

  private func inboxRoot() -> URL? {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: Self.appGroupId
      )
    else {
      NSLog("Cuplivo inbound share: App Group container unavailable")
      return nil
    }
    let root = container.appendingPathComponent(
      "share_inbox",
      isDirectory: true
    )
    if !FileManager.default.fileExists(atPath: root.path) {
      try? FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
      )
    }
    return root
  }
}
