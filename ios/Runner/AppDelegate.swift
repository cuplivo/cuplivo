import Flutter
import UIKit
import BackgroundTasks
import UserNotifications
import ActivityKit

private let backgroundRefreshIdentifier = "com.cup11.cuplivo.background-generation.refresh"
private let backgroundProcessingIdentifier = "com.cup11.cuplivo.background-generation.processing"

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let fileSaveHandler = NativeFileSaveHandler()
  private let backgroundGenerationHandler = IosBackgroundGenerationHandler()
  private var linuxSandboxPlugin: CuplivoLinuxSandboxPlugin?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    backgroundGenerationHandler.registerBackgroundTasks()
    if let controller = window?.rootViewController as? FlutterViewController {
      linuxSandboxPlugin = CuplivoLinuxSandboxPlugin.register(messenger: controller.binaryMessenger)
      let clipboardChannel = FlutterMethodChannel(name: "app.clipboard", binaryMessenger: controller.binaryMessenger)
      clipboardChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
        if call.method == "getClipboardImages" {
          var paths: [String] = []
          if let image = UIPasteboard.general.image {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
              .appendingPathComponent("clipboard-images", isDirectory: true)
            do {
              try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
              Self.cleanupClipboardImages(in: dir)
              var data: Data?
              var ext = "png"
              if let png = image.pngData() {
                data = png
              } else if let jpeg = image.jpegData(compressionQuality: 0.95) {
                data = jpeg
                ext = "jpg"
              }
              if let data {
                let url = dir.appendingPathComponent("pasted_\(UUID().uuidString).\(ext)")
                try data.write(to: url)
                paths.append(url.path)
              }
            } catch {
              // ignore write error
            }
          }
          result(paths)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }

      let fileSaveChannel = FlutterMethodChannel(name: "app.file_save", binaryMessenger: controller.binaryMessenger)
      fileSaveHandler.presentingViewController = controller
      fileSaveChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
        guard call.method == "saveFileFromPath" else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.fileSaveHandler.handle(call: call, result: result)
      }

      let iosBackgroundChannel = FlutterMethodChannel(name: "app.ios_background_generation", binaryMessenger: controller.binaryMessenger)
      iosBackgroundChannel.setMethodCallHandler { [weak self] call, result in
        self?.backgroundGenerationHandler.handle(call: call, result: result)
      }

      // Exposes the real app tmp directory (NSTemporaryDirectory = <container>/tmp).
      // path_provider's getTemporaryDirectory() returns the Caches directory on
      // iOS, so the true tmp dir is unreachable from Dart without this channel.
      let iosTmpChannel = FlutterMethodChannel(name: "app.ios_tmp_directory", binaryMessenger: controller.binaryMessenger)
      iosTmpChannel.setMethodCallHandler { call, result in
        guard call.method == "getPath" else {
          result(FlutterMethodNotImplemented)
          return
        }
        result(NSTemporaryDirectory())
      }

      // Advanced background keep-alive (silent audio + location legs).
      BackgroundKeepAliveManager.shared.register(with: controller.binaryMessenger)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Bounded, TTL-based cleanup for paste-image temp files: repeated
  /// clipboard pastes no longer grow <container>/tmp without bound. Files
  /// older than 24 h are removed, then the oldest files are dropped while
  /// more than 100 files or 100 MB remain.
  private static func cleanupClipboardImages(in dir: URL) {
    let fm = FileManager.default
    guard let urls = try? fm.contentsOfDirectory(
      at: dir,
      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
      options: [.skipsHiddenFiles]
    ) else { return }
    let now = Date()
    let ttl: TimeInterval = 24 * 60 * 60
    let maxFiles = 100
    let maxBytes = 100 * 1024 * 1024

    var entries: [(url: URL, modified: Date, size: Int)] = []
    for url in urls where url.lastPathComponent.hasPrefix("pasted_") {
      let values = try? url.resourceValues(
        forKeys: [.contentModificationDateKey, .fileSizeKey]
      )
      entries.append((
        url,
        values?.contentModificationDate ?? .distantPast,
        values?.fileSize ?? 0
      ))
    }

    let stale = Set(
      entries.filter { now.timeIntervalSince($0.modified) > ttl }.map(\.url)
    )
    for url in stale {
      try? fm.removeItem(at: url)
    }
    entries.removeAll { stale.contains($0.url) }

    if entries.count > maxFiles || entries.reduce(0, { $0 + $1.size }) > maxBytes {
      let sorted = entries.sorted { $0.modified < $1.modified }
      var count = entries.count
      var bytes = entries.reduce(0, { $0 + $1.size })
      for entry in sorted {
        if count <= maxFiles && bytes <= maxBytes { break }
        try? fm.removeItem(at: entry.url)
        count -= 1
        bytes -= entry.size
      }
    }
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    backgroundGenerationHandler.dismissFinishedLiveActivityIfNeeded()
  }
}

private final class IosBackgroundGenerationHandler {
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var notificationsEnabled = false
  private var refreshEnabled = false
  private var liveActivity: Any?
  private var liveActivityDisplayTitle = ""
  private var liveActivityDetail = ""
  private var liveActivityTokenCount = 0
  private var liveActivityTokenLabel = ""
  private var liveActivityStartedAt = Date()
  private var liveActivityFinishedAt: Date?
  private var liveActivityFinishedDetail = ""
  private var liveActivityFinished = false
  private var liveActivityUpdateScheduled = false

  func registerBackgroundTasks() {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundRefreshIdentifier, using: nil) { task in
      self.handleBackgroundTask(task)
    }
    BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundProcessingIdentifier, using: nil) { task in
      self.handleBackgroundTask(task)
    }
  }

  func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getStatus":
      getStatus(result: result)
    case "requestNotificationAuthorization":
      requestNotificationAuthorization(result: result)
    case "openAppSettings":
      openAppSettings(result: result)
    case "openNotificationSettings":
      openNotificationSettings(result: result)
    case "start":
      start(arguments: call.arguments, result: result)
    case "update":
      update(arguments: call.arguments, result: result)
    case "finish":
      finish(arguments: call.arguments, result: result)
    case "cancel":
      cancel(arguments: call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func start(arguments: Any?, result: @escaping FlutterResult) {
    let args = arguments as? [String: Any] ?? [:]
    notificationsEnabled = args["notificationsEnabled"] as? Bool ?? false
    refreshEnabled = args["refreshEnabled"] as? Bool ?? false
    beginBackgroundTask()
    if refreshEnabled { scheduleBackgroundTasks() }
    if args["liveActivityEnabled"] as? Bool ?? false {
      startLiveActivity(
        title: args["title"] as? String ?? "Cuplivo",
        detail: args["detail"] as? String ?? "",
        tokenCount: args["tokenCount"] as? Int ?? 0,
        tokenLabel: args["tokenLabel"] as? String ?? ""
      )
    }
    result(true)
  }

  private func update(arguments: Any?, result: @escaping FlutterResult) {
    let args = arguments as? [String: Any] ?? [:]
    updateLiveActivity(
      detail: args["detail"] as? String ?? "",
      tokenCount: args["tokenCount"] as? Int ?? 0,
      tokenLabel: args["tokenLabel"] as? String ?? ""
    )
    result(true)
  }

  private func finish(arguments: Any?, result: @escaping FlutterResult) {
    let args = arguments as? [String: Any] ?? [:]
    let title = args["title"] as? String ?? "Cuplivo"
    let detail = args["detail"] as? String ?? ""
    finishLiveActivity(title: title, detail: detail)
    if notificationsEnabled { showCompletionNotification(title: title, body: detail) }
    endBackgroundTask()
    resetGenerationOptions()
    result(true)
  }

  private func cancel(arguments: Any?, result: @escaping FlutterResult) {
    let args = arguments as? [String: Any] ?? [:]
    finishLiveActivity(
      title: liveActivityDisplayTitle.isEmpty ? "Cuplivo" : liveActivityDisplayTitle,
      detail: args["detail"] as? String ?? ""
    )
    endBackgroundTask()
    resetGenerationOptions()
    result(true)
  }

  private func resetGenerationOptions() {
    notificationsEnabled = false
    refreshEnabled = false
  }

  private func getStatus(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      DispatchQueue.main.async {
        var liveActivitiesEnabled = false
        if #available(iOS 16.1, *) {
          liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        }
        result([
          "backgroundTaskActive": self.backgroundTask != .invalid,
          "liveActivityActive": self.isLiveActivityActive(),
          "notificationsAuthorized": settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
          "liveActivitiesEnabled": liveActivitiesEnabled,
        ])
      }
    }
  }

  private func requestNotificationAuthorization(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
      DispatchQueue.main.async { result(granted) }
    }
  }

  private func openAppSettings(result: @escaping FlutterResult) {
    guard let url = URL(string: UIApplication.openSettingsURLString) else {
      result(false)
      return
    }
    UIApplication.shared.open(url, options: [:]) { opened in
      result(opened)
    }
  }

  private func openNotificationSettings(result: @escaping FlutterResult) {
    let url: URL?
    if #available(iOS 16.0, *) {
      url = URL(string: UIApplication.openNotificationSettingsURLString)
    } else {
      url = URL(string: UIApplication.openSettingsURLString)
    }
    guard let url else {
      result(false)
      return
    }
    UIApplication.shared.open(url, options: [:]) { opened in
      result(opened)
    }
  }

  private func beginBackgroundTask() {
    if backgroundTask != .invalid { return }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "CuplivoBackgroundGeneration") { [weak self] in
      guard let self else { return }
      // Intelligent expiry: when the silent-audio keep-alive leg is active
      // the process is not in danger of termination, so re-arm a fresh
      // finite task instead of letting the generation die. Without
      // keep-alive, end the task and let the system suspend us.
      if BackgroundKeepAliveManager.shared.keepAliveEffective {
        let expiringId = self.backgroundTask
        self.backgroundTask = .invalid
        if expiringId != .invalid {
          UIApplication.shared.endBackgroundTask(expiringId)
        }
        self.beginBackgroundTask()
      } else {
        // No keep-alive backing us — the system really will suspend the app.
        // Record the interruption only when keep-alive was actually armed, so
        // users who never enabled it aren't told they were 'interrupted'.
        if BackgroundKeepAliveManager.shared.masterEnabled {
          BackgroundKeepAliveManager.shared.recordInterruption()
        }
        self.endBackgroundTask()
      }
    }
  }

  private func endBackgroundTask() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }

  private func scheduleBackgroundTasks() {
    let refresh = BGAppRefreshTaskRequest(identifier: backgroundRefreshIdentifier)
    refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    do {
      try BGTaskScheduler.shared.submit(refresh)
    } catch {
      NSLog("Cuplivo background refresh schedule failed: \(error)")
    }

    let processing = BGProcessingTaskRequest(identifier: backgroundProcessingIdentifier)
    processing.requiresNetworkConnectivity = true
    processing.requiresExternalPower = false
    processing.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    do {
      try BGTaskScheduler.shared.submit(processing)
    } catch {
      NSLog("Cuplivo background processing schedule failed: \(error)")
    }
  }

  private func handleBackgroundTask(_ task: BGTask) {
    if refreshEnabled { scheduleBackgroundTasks() }
    task.expirationHandler = { task.setTaskCompleted(success: false) }
    task.setTaskCompleted(success: true)
  }

  private func showCompletionNotification(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    let request = UNNotificationRequest(identifier: "cuplivo.background-generation.\(Date().timeIntervalSince1970)", content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
  }

  private func isLiveActivityActive() -> Bool {
    if #available(iOS 16.1, *) {
      return liveActivity as? Activity<CuplivoGenerationActivityAttributes> != nil
    }
    return false
  }

  private func startLiveActivity(title: String, detail: String, tokenCount: Int, tokenLabel: String) {
    if #available(iOS 16.1, *) {
      guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
      liveActivityDisplayTitle = title
      liveActivityDetail = detail
      liveActivityStartedAt = Date()
      liveActivityFinishedAt = nil
      liveActivityFinishedDetail = ""
      liveActivityFinished = false
      liveActivityTokenCount = tokenCount
      liveActivityTokenLabel = tokenLabel
      let state = liveActivityState(
        displayTitle: title,
        detail: detail,
        tokenCount: tokenCount,
        tokenLabel: tokenLabel,
        finishedAt: nil,
        isFinished: false
      )
      do {
        if #available(iOS 16.2, *) {
          liveActivity = try Activity<CuplivoGenerationActivityAttributes>.request(attributes: CuplivoGenerationActivityAttributes(title: title), content: ActivityContent(state: state, staleDate: nil), pushType: nil)
        } else {
          liveActivity = try Activity<CuplivoGenerationActivityAttributes>.request(attributes: CuplivoGenerationActivityAttributes(title: title), contentState: state, pushType: nil)
        }
      } catch {
        NSLog("Cuplivo live activity start failed: \(error)")
        liveActivity = nil
      }
    }
  }

  private func updateLiveActivity(detail: String, tokenCount: Int, tokenLabel: String) {
    guard isLiveActivityActive(), !liveActivityFinished else { return }
    liveActivityTokenCount = tokenCount
    liveActivityTokenLabel = tokenLabel
    liveActivityDetail = detail
    liveActivityFinishedAt = nil
    liveActivityFinishedDetail = ""
    pushLiveActivityUpdate()
  }

  /// Coalesces rapid Dart `update()` calls into a single system update per
  /// runloop turn: the first change schedules one dispatch, later changes in
  /// the same turn are picked up by the snapshot built in
  /// `performLiveActivityUpdate`.
  private func pushLiveActivityUpdate() {
    guard isLiveActivityActive(), !liveActivityFinished else { return }
    if liveActivityUpdateScheduled { return }
    liveActivityUpdateScheduled = true
    DispatchQueue.main.async { [weak self] in
      self?.liveActivityUpdateScheduled = false
      self?.performLiveActivityUpdate()
    }
  }

  private func performLiveActivityUpdate() {
    guard #available(iOS 16.1, *), let activity = liveActivity as? Activity<CuplivoGenerationActivityAttributes> else { return }
    guard !liveActivityFinished else { return }
    let state = liveActivityState(
      displayTitle: liveActivityDisplayTitle,
      detail: liveActivityDetail,
      tokenCount: liveActivityTokenCount,
      tokenLabel: liveActivityTokenLabel,
      finishedAt: nil,
      isFinished: false
    )
    Task {
      if #available(iOS 16.2, *) {
        await activity.update(ActivityContent(state: state, staleDate: nil))
      } else {
        await activity.update(using: state)
      }
    }
  }

  func dismissFinishedLiveActivityIfNeeded() {
    guard liveActivityFinished else { return }
    endLiveActivity(detail: liveActivityFinishedDetail)
  }

  private func finishLiveActivity(title: String, detail: String) {
    liveActivityDisplayTitle = title
    liveActivityDetail = detail
    if UIApplication.shared.applicationState == .active {
      liveActivityFinishedAt = Date()
      liveActivityFinishedDetail = detail
      liveActivityFinished = true
      endLiveActivity(detail: detail)
      return
    }
    markLiveActivityFinished(title: title, detail: detail)
  }

  private func markLiveActivityFinished(title: String, detail: String) {
    if #available(iOS 16.1, *), let activity = liveActivity as? Activity<CuplivoGenerationActivityAttributes> {
      let finishedAt = Date()
      liveActivityDisplayTitle = title
      liveActivityDetail = detail
      liveActivityFinishedAt = finishedAt
      liveActivityFinishedDetail = detail
      liveActivityFinished = true
      let state = liveActivityState(
        displayTitle: title,
        detail: detail,
        tokenCount: liveActivityTokenCount,
        tokenLabel: liveActivityTokenLabel,
        finishedAt: finishedAt,
        isFinished: true
      )
      Task {
        if #available(iOS 16.2, *) {
          await activity.update(ActivityContent(state: state, staleDate: nil))
        } else {
          await activity.update(using: state)
        }
      }
    }
  }

  private func endLiveActivity(detail: String) {
    if #available(iOS 16.1, *), let activity = liveActivity as? Activity<CuplivoGenerationActivityAttributes> {
      let state = liveActivityState(
        displayTitle: liveActivityDisplayTitle,
        detail: detail,
        tokenCount: liveActivityTokenCount,
        tokenLabel: liveActivityTokenLabel,
        finishedAt: liveActivityFinishedAt,
        isFinished: liveActivityFinished
      )
      Task {
        if #available(iOS 16.2, *) {
          await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
        } else {
          await activity.end(using: state, dismissalPolicy: .immediate)
        }
      }
      liveActivity = nil
      liveActivityDisplayTitle = ""
      liveActivityDetail = ""
      liveActivityTokenCount = 0
      liveActivityTokenLabel = ""
      liveActivityStartedAt = Date()
      liveActivityFinishedAt = nil
      liveActivityFinishedDetail = ""
      liveActivityFinished = false
    }
  }

  @available(iOS 16.1, *)
  private func liveActivityState(
    displayTitle: String,
    detail: String,
    tokenCount: Int,
    tokenLabel: String,
    finishedAt: Date?,
    isFinished: Bool
  ) -> CuplivoGenerationActivityAttributes.ContentState {
    let startedAt = liveActivityStartedAt
    let effectiveFinishedAt = finishedAt ?? Date()
    return CuplivoGenerationActivityAttributes.ContentState(
      displayTitle: displayTitle,
      detail: detail,
      tokenCount: tokenCount,
      tokenLabel: tokenLabel,
      startedAt: startedAt,
      finishedAt: finishedAt,
      elapsedSeconds: isFinished
        ? elapsedSeconds(from: startedAt, to: effectiveFinishedAt)
        : elapsedSeconds(since: startedAt),
      isFinished: isFinished
    )
  }

  private func elapsedSeconds(since startedAt: Date) -> Int {
    elapsedSeconds(from: startedAt, to: Date())
  }

  private func elapsedSeconds(from startedAt: Date, to endedAt: Date) -> Int {
    max(0, Int(endedAt.timeIntervalSince(startedAt)))
  }
}

private final class NativeFileSaveHandler: NSObject, UIDocumentPickerDelegate {
  weak var presentingViewController: UIViewController?
  private var pendingResult: FlutterResult?
  private var pendingExportURL: URL?

  func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    if pendingResult != nil {
      result(FlutterError(code: "busy", message: "Another save operation is already in progress.", details: nil))
      return
    }

    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "invalid_args", message: "Arguments must be a map.", details: nil))
      return
    }

    let rawSourcePath = (args["sourcePath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !rawSourcePath.isEmpty else {
      result(FlutterError(code: "invalid_args", message: "Missing sourcePath.", details: nil))
      return
    }

    let sourceURL = URL(fileURLWithPath: rawSourcePath)
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
      result(FlutterError(code: "not_found", message: "Source file does not exist.", details: nil))
      return
    }

    // UIDocumentPicker exports the file under its on-disk name, so honor the
    // Dart-provided fileName by staging an export copy with that name first.
    let exportURL: URL
    do {
      exportURL = try Self.stageExportCopy(
        of: sourceURL,
        fileName: args["fileName"] as? String
      )
    } catch {
      result(
        FlutterError(
          code: "stage_failed",
          message: error.localizedDescription,
          details: nil
        )
      )
      return
    }

    guard let presenter = topViewController(from: presentingViewController) else {
      try? FileManager.default.removeItem(at: exportURL)
      result(FlutterError(code: "unavailable", message: "Unable to present document picker.", details: nil))
      return
    }

    pendingResult = result
    pendingExportURL = exportURL

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }

      let picker: UIDocumentPickerViewController
      if #available(iOS 14.0, *) {
        picker = UIDocumentPickerViewController(forExporting: [exportURL], asCopy: true)
      } else {
        picker = UIDocumentPickerViewController(url: exportURL, in: .exportToService)
      }

      picker.delegate = self
      picker.modalPresentationStyle = .formSheet
      if let popover = picker.popoverPresentationController {
        popover.sourceView = presenter.view
        popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        popover.permittedArrowDirections = []
      }

      presenter.present(picker, animated: true)
    }
  }

  /// Copies [sourceURL] into a per-session temp directory under the requested
  /// [fileName] so the system document picker presents the Dart-provided name
  /// instead of the original on-disk filename.
  private static func stageExportCopy(of sourceURL: URL, fileName: String?) throws -> URL {
    let fm = FileManager.default
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("file-save-exports", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let name = Self.sanitizedFileName(fileName ?? sourceURL.lastPathComponent)
    let target = dir.appendingPathComponent(name)
    if fm.fileExists(atPath: target.path) {
      try fm.removeItem(at: target)
    }
    try fm.copyItem(at: sourceURL, to: target)
    return target
  }

  /// Strips path separators/control characters and caps the length so a
  /// model/user-supplied name cannot escape the staging directory.
  private static func sanitizedFileName(_ raw: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\:\u{0000}")
    let cleaned = raw
      .components(separatedBy: invalid)
      .joined(separator: "_")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let fallback = URL(fileURLWithPath: raw).lastPathComponent
    let base = cleaned.isEmpty ? fallback : cleaned
    return String(base.prefix(200))
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(with: false)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    finish(with: !urls.isEmpty)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
    finish(with: true)
  }

  private func finish(with value: Bool) {
    let result = pendingResult
    pendingResult = nil
    if let exportURL = pendingExportURL {
      pendingExportURL = nil
      try? FileManager.default.removeItem(at: exportURL)
    }
    result?(value)
  }

  private func topViewController(from controller: UIViewController?) -> UIViewController? {
    if let navigation = controller as? UINavigationController {
      return topViewController(from: navigation.visibleViewController)
    }
    if let tab = controller as? UITabBarController {
      return topViewController(from: tab.selectedViewController)
    }
    if let presented = controller?.presentedViewController {
      return topViewController(from: presented)
    }
    return controller
  }
}
