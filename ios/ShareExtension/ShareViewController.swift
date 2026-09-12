import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// Principal view controller of the Cuplivo Share Extension.
///
/// Writes everything another app shared into the App Group inbox
/// (`group.com.cup11.cuplivo/share_inbox/<uuid>/`) with a `manifest.json`,
/// then tries to foreground the host app via `cuplivo://share`. When that
/// fails it posts a local notification so the user can continue manually.
final class ShareViewController: UIViewController {
  private let appGroupId = "group.com.cup11.cuplivo"
  private let ioQueue = DispatchQueue(label: "com.cup11.cuplivo.share-extension.io")

  private var didCollect = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground

    let label = UILabel()
    label.text = NSLocalizedString("share_opening", comment: "")
    label.textAlignment = .center
    label.numberOfLines = 0
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      label.leadingAnchor.constraint(
        greaterThanOrEqualTo: view.leadingAnchor,
        constant: 24
      ),
      label.trailingAnchor.constraint(
        lessThanOrEqualTo: view.trailingAnchor,
        constant: -24
      ),
    ])
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !didCollect else { return }
    didCollect = true
    collectAndFinish()
  }

  // MARK: - Collection

  private func collectAndFinish() {
    guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
      finish()
      return
    }
    let providers = items.flatMap { $0.attachments ?? [] }
    guard let inbox = makeInbox() else {
      finish()
      return
    }

    var text: String?
    var images: [String] = []
    var files: [[String: Any]] = []
    let group = DispatchGroup()

    for provider in providers {
      group.enter()
      load(provider: provider, inbox: inbox) { loaded in
        // NSItemProvider handlers run on arbitrary queues; the collections
        // below are shared across them, so serialize the mutations.
        DispatchQueue.main.async {
          switch loaded {
          case .text(let value):
            if text == nil { text = value }
          case .image(let name):
            images.append(name)
          case .file(let entry):
            files.append(entry)
          case .none:
            break
          }
          group.leave()
        }
      }
    }

    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      self.writeManifest(inbox: inbox, text: text, images: images, files: files)
      self.openHostApp()
    }
  }

  private enum Loaded {
    case text(String)
    case image(String)
    case file([String: Any])
    case none
  }

  private func load(
    provider: NSItemProvider,
    inbox: URL,
    completion: @escaping (Loaded) -> Void
  ) {
    if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
      provider.loadItem(
        forTypeIdentifier: UTType.plainText.identifier,
        options: nil
      ) { item, _ in
        let value =
          (item as? String)
          ?? (item as? NSAttributedString)?.string
        completion(value.map { Loaded.text($0) } ?? .none)
      }
      return
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
      provider.loadItem(
        forTypeIdentifier: UTType.url.identifier,
        options: nil
      ) { item, _ in
        if let url = item as? URL {
          completion(.text(url.absoluteString))
        } else if let data = item as? Data,
          let url = URL(dataRepresentation: data, relativeTo: nil)
        {
          completion(.text(url.absoluteString))
        } else {
          completion(.none)
        }
      }
      return
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
      copyItem(
        provider: provider,
        typeIdentifier: UTType.image.identifier,
        inbox: inbox,
        completion: completion
      )
      return
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      copyItem(
        provider: provider,
        typeIdentifier: UTType.fileURL.identifier,
        inbox: inbox,
        completion: completion
      )
      return
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
      let isImage = provider.hasItemConformingToTypeIdentifier(
        UTType.image.identifier
      )
      copyItem(
        provider: provider,
        typeIdentifier: UTType.data.identifier,
        inbox: inbox,
        isImage: isImage,
        completion: completion
      )
      return
    }
    completion(.none)
  }

  private func copyItem(
    provider: NSItemProvider,
    typeIdentifier: String,
    inbox: URL,
    isImage: Bool = false,
    completion: @escaping (Loaded) -> Void
  ) {
    provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) {
      [weak self] url, error in
      guard let self, let url, error == nil else {
        completion(.none)
        return
      }
      // `async`, never `sync`: this completion can run on an arbitrary queue,
      // and syncing onto it from itself would deadlock the extension.
      self.ioQueue.async {
        let name = self.uniqueName(
          in: inbox,
          preferred: url.lastPathComponent
        )
        let destination = inbox.appendingPathComponent(name)
        do {
          try FileManager.default.copyItem(at: url, to: destination)
        } catch {
          NSLog("Cuplivo share extension: copy failed: \(error)")
          completion(.none)
          return
        }
        let mime = Self.mimeType(for: destination)
        if isImage || mime.hasPrefix("image/") {
          completion(.image(name))
        } else {
          completion(.file(["name": name, "mime": mime]))
        }
      }
    }
  }

  // MARK: - Inbox

  private func makeInbox() -> URL? {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupId
      )
    else {
      NSLog("Cuplivo share extension: App Group container unavailable")
      return nil
    }
    let inbox = container
      .appendingPathComponent("share_inbox", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: inbox,
        withIntermediateDirectories: true
      )
    } catch {
      NSLog("Cuplivo share extension: unable to create inbox: \(error)")
      return nil
    }
    return inbox
  }

  private func uniqueName(in inbox: URL, preferred: String) -> String {
    let safe = Self.sanitized(preferred)
    let nsName = safe as NSString
    let ext = nsName.pathExtension
    let base = nsName.deletingPathExtension
    var candidate = safe
    var counter = 1
    while FileManager.default.fileExists(
      atPath: inbox.appendingPathComponent(candidate).path
    ) {
      candidate = ext.isEmpty
        ? "\(base)(\(counter))"
        : "\(base)(\(counter)).\(ext)"
      counter += 1
    }
    return candidate
  }

  private static func sanitized(_ raw: String) -> String {
    let base = (raw as NSString).lastPathComponent
    let cleaned = base
      .components(separatedBy: CharacterSet(charactersIn: "/\\:\u{0000}"))
      .joined(separator: "_")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
      return "shared_\(UUID().uuidString)"
    }
    return String(cleaned.prefix(200))
  }

  private static func mimeType(for url: URL) -> String {
    let extensionName = url.pathExtension
    if !extensionName.isEmpty,
      let type = UTType(filenameExtension: extensionName),
      let mime = type.preferredMIMEType
    {
      return mime
    }
    return "application/octet-stream"
  }

  private func writeManifest(
    inbox: URL,
    text: String?,
    images: [String],
    files: [[String: Any]]
  ) {
    var payload: [String: Any] = [
      "images": images,
      "files": files,
    ]
    if let text { payload["text"] = text }
    guard let data = try? JSONSerialization.data(withJSONObject: payload)
    else { return }
    do {
      try data.write(to: inbox.appendingPathComponent("manifest.json"))
    } catch {
      NSLog("Cuplivo share extension: manifest write failed: \(error)")
    }
  }

  // MARK: - Hand-off

  private func openHostApp() {
    guard let url = URL(string: "cuplivo://share") else {
      finish()
      return
    }
    extensionContext?.open(url) { [weak self] success in
      if !success {
        self?.notifyUser()
      }
      self?.finish()
    }
  }

  private func notifyUser() {
    let content = UNMutableNotificationContent()
    content.title = "Cuplivo"
    content.body = NSLocalizedString("share_notification_body", comment: "")
    let request = UNNotificationRequest(
      identifier: "cuplivo.share.\(UUID().uuidString)",
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().add(request) { error in
      if let error {
        NSLog("Cuplivo share extension: notification failed: \(error)")
      }
    }
  }

  private func finish() {
    DispatchQueue.main.async { [weak self] in
      self?.extensionContext?.completeRequest(
        returningItems: nil,
        completionHandler: nil
      )
    }
  }
}
