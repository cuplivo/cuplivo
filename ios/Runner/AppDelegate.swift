import Flutter
import UIKit
import BackgroundTasks
import UserNotifications
import ActivityKit
import EventKit

private let backgroundRefreshIdentifier = "com.cup11.cuplivo.background-generation.refresh"
private let backgroundProcessingIdentifier = "com.cup11.cuplivo.background-generation.processing"

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let fileSaveHandler = NativeFileSaveHandler()
  private let backgroundGenerationHandler = IosBackgroundGenerationHandler()
  private let deviceLocalToolsHandler = DeviceLocalToolsHandler()
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

      let deviceToolsChannel = FlutterMethodChannel(name: "app.device_tools", binaryMessenger: controller.binaryMessenger)
      deviceToolsChannel.setMethodCallHandler { [weak self] call, result in
        self?.deviceLocalToolsHandler.handle(call: call, result: result)
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
    backgroundGenerationHandler.endOrphanedLiveActivities(reason: "applicationDidBecomeActive")
  }
}

private final class IosBackgroundGenerationHandler {
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var notificationsEnabled = false
  private var refreshEnabled = false
  private var liveActivity: Any?
  private var liveActivityRefreshTimer: Timer?
  private var liveActivityDisplayTitle = ""
  private var liveActivityDetail = ""
  private var liveActivityTokenCount = 0
  private var liveActivityTokenLabel = ""
  private var liveActivityStartedAt = Date()
  private var liveActivityFinishedAt: Date?
  private var liveActivityFinishedDetail = ""
  private var liveActivityFinished = false
  private var liveActivityWavePhase = 0

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

  /// Ends every live instance of `CuplivoGenerationActivityAttributes` that
  /// this process does not own. The owning reference lives only in memory,
  /// so instances created by a previous process (killed, crashed, or force-
  /// quit) would otherwise linger on the Lock Screen / Dynamic Island until
  /// system expiry. Enumerating by attributes type needs no persistence.
  ///
  /// Internal (not private) because AppDelegate calls it from
  /// applicationDidBecomeActive, mirroring dismissFinishedLiveActivityIfNeeded.
  ///
  /// Safe to call while a generation is running: the in-process owner is
  /// skipped, and each end task captures its own activity object, so it can
  /// never tear down an instance created afterwards.
  func endOrphanedLiveActivities(reason: String) {
    if #available(iOS 16.1, *) {
      guard !isLiveActivityActive() else { return }
      let activities = Activity<CuplivoGenerationActivityAttributes>.activities
      for activity in activities {
        let shouldEnd: Bool
        if #available(iOS 16.2, *) {
          shouldEnd = activity.activityState == .active || activity.activityState == .stale
        } else {
          shouldEnd = activity.activityState == .active
        }
        guard shouldEnd else { continue }
        NSLog("Cuplivo live activity orphan cleanup (\(reason)): ending \(activity.id)")
        endOrphanedLiveActivity(activity)
      }
    }
  }

  @available(iOS 16.1, *)
  private func endOrphanedLiveActivity(_ activity: Activity<CuplivoGenerationActivityAttributes>) {
    // Reuse the exact final content state shape of finishLiveActivity's
    // active-app path (endLiveActivity): finished card with elapsed time.
    // Keep the orphan's own start time / wave phase so the tombstone shows
    // truthful data. `content` is non-optional on iOS 16.2+; use the legacy
    // optional contentState on iOS 16.1, falling back to a clean finished
    // card only when that legacy system state is unavailable.
    let finishedAt = Date()
    let fallbackState = CuplivoGenerationActivityAttributes.ContentState(
      displayTitle: activity.attributes.title,
      detail: "",
      tokenCount: 0,
      tokenLabel: "",
      startedAt: finishedAt,
      finishedAt: finishedAt,
      elapsedSeconds: 0,
      wavePhase: 0,
      isFinished: true
    )
    let priorState: CuplivoGenerationActivityAttributes.ContentState
    if #available(iOS 16.2, *) {
      priorState = activity.content.state
    } else {
      priorState = activity.contentState ?? fallbackState
    }
    let state = CuplivoGenerationActivityAttributes.ContentState(
      displayTitle: activity.attributes.title,
      detail: priorState.detail,
      tokenCount: priorState.tokenCount,
      tokenLabel: priorState.tokenLabel,
      startedAt: priorState.startedAt,
      finishedAt: finishedAt,
      elapsedSeconds: elapsedSeconds(from: priorState.startedAt, to: finishedAt),
      wavePhase: priorState.wavePhase,
      isFinished: true
    )
    Task {
      if #available(iOS 16.2, *) {
        await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
      } else {
        await activity.end(using: state, dismissalPolicy: .immediate)
      }
    }
  }

  private func startLiveActivity(title: String, detail: String, tokenCount: Int, tokenLabel: String) {
    if #available(iOS 16.1, *) {
      guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
      // Defensive: reclaim any leftover instance (e.g. from a previous
      // process) before creating a new one, so at most one generation card
      // is ever on screen.
      endOrphanedLiveActivities(reason: "beforeStart")
      liveActivityDisplayTitle = title
      liveActivityDetail = detail
      liveActivityStartedAt = Date()
      liveActivityFinishedAt = nil
      liveActivityFinishedDetail = ""
      liveActivityFinished = false
      liveActivityWavePhase = 0
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
        startLiveActivityRefreshTimer()
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
  }

  func dismissFinishedLiveActivityIfNeeded() {
    guard liveActivityFinished else { return }
    endLiveActivity(detail: liveActivityFinishedDetail)
  }

  private func finishLiveActivity(title: String, detail: String) {
    liveActivityDisplayTitle = title
    liveActivityDetail = detail
    stopLiveActivityRefreshTimer()
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
      stopLiveActivityRefreshTimer()
      liveActivityDisplayTitle = ""
      liveActivityDetail = ""
      liveActivityTokenCount = 0
      liveActivityTokenLabel = ""
      liveActivityStartedAt = Date()
      liveActivityFinishedAt = nil
      liveActivityFinishedDetail = ""
      liveActivityFinished = false
      liveActivityWavePhase = 0
    }
  }

  private func startLiveActivityRefreshTimer() {
    stopLiveActivityRefreshTimer()
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      self?.refreshLiveActivity()
    }
    liveActivityRefreshTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func stopLiveActivityRefreshTimer() {
    liveActivityRefreshTimer?.invalidate()
    liveActivityRefreshTimer = nil
  }

  private func refreshLiveActivity() {
    guard #available(iOS 16.1, *), let activity = liveActivity as? Activity<CuplivoGenerationActivityAttributes> else { return }
    guard !liveActivityFinished else { return }
    liveActivityWavePhase += 1
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
      wavePhase: liveActivityWavePhase,
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

/// Native backend for the AI assistant's device-local tools on iOS.
///
/// Calendar query/create is implemented with EventKit. Screen time has no
/// generally available query API on iOS (the Screen Time frameworks require a
/// special Family Controls entitlement), so it is not exposed here; the Dart
/// side never offers that tool on iOS.
///
/// Methods receive the tool arguments as a JSON string and return a JSON
/// string payload. Errors the LLM should see (missing permission, bad
/// arguments) are returned as JSON payloads with an "error" field.
///
/// Fork note: `createCalendarEvent` additionally accepts `reminder_minutes`
/// (minutes before start, >= 1) and sets an EKAlarm — a deliberate Cuplivo
/// extension over upstream Kelivo v1.2.1, addressing Chevey339/kelivo#920
/// (created events carried no notification).
private final class DeviceLocalToolsHandler {
  private let eventStore = EKEventStore()

  func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = Self.parseArgs(call.arguments)
    switch call.method {
    case "hasUsageStatsPermission":
      result(false)
    case "openUsageAccessSettings":
      result(nil)
    case "hasCalendarPermission":
      result(hasCalendarPermission())
    case "requestCalendarPermission":
      requestCalendarPermission(result: result)
    case "queryCalendar":
      ensureCalendarAccess { [weak self] granted in
        guard let self else { return }
        guard granted else {
          result(Self.noPermissionPayload)
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          let payload = self.queryCalendar(args: args)
          DispatchQueue.main.async { result(payload) }
        }
      }
    case "createCalendarEvent":
      ensureCalendarAccess { [weak self] granted in
        guard let self else { return }
        guard granted else {
          result(Self.noPermissionPayload)
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          let payload = self.createCalendarEvent(args: args)
          DispatchQueue.main.async { result(payload) }
        }
      }
    case "getScreenTime":
      result(Self.errorPayload(
        "UNSUPPORTED_PLATFORM",
        "Screen time queries are not available on iOS; Apple does not provide a general-purpose API for this."
      ))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Permission

  private static let noPermissionPayload = errorPayload(
    "NO_PERMISSION",
    "Calendar permission is not granted. Please ask the user to allow full calendar access "
      + "for this app in the system Settings and try again."
  )

  private func hasCalendarPermission() -> Bool {
    let status = EKEventStore.authorizationStatus(for: .event)
    if #available(iOS 17.0, *) {
      return status == .fullAccess
    }
    return status == .authorized
  }

  /// Used by the assistant settings toggle. Prompts when undetermined; opens
  /// Settings when previously denied/restricted/write-only.
  private func requestCalendarPermission(result: @escaping FlutterResult) {
    let finish: (Bool) -> Void = { granted in
      DispatchQueue.main.async { result(granted) }
    }
    let status = EKEventStore.authorizationStatus(for: .event)
    if #available(iOS 17.0, *) {
      switch status {
      case .fullAccess:
        finish(true)
      case .notDetermined:
        eventStore.requestFullAccessToEvents { granted, _ in finish(granted) }
      default:
        openAppSettings()
        finish(false)
      }
    } else {
      switch status {
      case .authorized:
        finish(true)
      case .notDetermined:
        eventStore.requestAccess(to: .event) { granted, _ in finish(granted) }
      default:
        openAppSettings()
        finish(false)
      }
    }
  }

  private func openAppSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }

  private func ensureCalendarAccess(completion: @escaping (Bool) -> Void) {
    let finish: (Bool) -> Void = { granted in
      DispatchQueue.main.async { completion(granted) }
    }
    let status = EKEventStore.authorizationStatus(for: .event)
    if #available(iOS 17.0, *) {
      switch status {
      case .fullAccess:
        finish(true)
      case .notDetermined:
        eventStore.requestFullAccessToEvents { granted, _ in finish(granted) }
      default:
        finish(false)
      }
    } else {
      switch status {
      case .authorized:
        finish(true)
      case .notDetermined:
        eventStore.requestAccess(to: .event) { granted, _ in finish(granted) }
      default:
        finish(false)
      }
    }
  }

  // MARK: - Calendar query

  private func queryCalendar(args: [String: Any]) -> String {
    let limit = min(max(Self.intArg(args["limit"]) ?? 20, 1), 100)
    let keyword = (args["query"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let rangePreset = (args["range"] as? String)?.lowercased() ?? "today"

    // ISO 8601 calendar so week presets start on Monday, matching Android.
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = .current
    let now = Date()
    let startOfToday = calendar.startOfDay(for: now)

    let startDate: Date
    let endDate: Date
    if let beginRaw = args["begin"] as? String, !beginRaw.isEmpty {
      guard let parsedStart = Self.parseTime(beginRaw, calendar: calendar) else {
        return Self.invalidTimePayload(beginRaw)
      }
      startDate = parsedStart
      if let endRaw = args["end"] as? String, !endRaw.isEmpty {
        guard let parsedEnd = Self.parseTime(endRaw, calendar: calendar) else {
          return Self.invalidTimePayload(endRaw)
        }
        endDate = parsedEnd
      } else {
        endDate = now
      }
    } else {
      switch rangePreset {
      case "week":
        let weekStart = calendar.date(
          from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        ) ?? startOfToday
        startDate = weekStart
        endDate = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? now
      case "month":
        let monthStart = calendar.date(
          from: calendar.dateComponents([.year, .month], from: now)
        ) ?? startOfToday
        startDate = monthStart
        endDate = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? now
      default:
        startDate = startOfToday
        endDate = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
      }
    }

    guard startDate < endDate else {
      return Self.errorPayload("INVALID_RANGE", "begin must be earlier than end.")
    }

    let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
    var events = eventStore.events(matching: predicate)
    if let keyword, !keyword.isEmpty {
      events = events.filter { ($0.title ?? "").lowercased().contains(keyword) }
    }
    events.sort { $0.startDate < $1.startDate }

    var items: [[String: Any]] = []
    for event in events.prefix(limit) {
      var item: [String: Any] = [
        "id": event.eventIdentifier ?? "",
        "title": event.title ?? "",
        "description": event.notes ?? "",
        "location": event.location ?? "",
        "all_day": event.isAllDay,
        "calendar": event.calendar?.title ?? "",
      ]
      if event.isAllDay {
        item["start"] = Self.formatDateOnly(event.startDate, calendar: calendar)
        // Report the exclusive end date (tool convention, matches Android);
        // EventKit stores all-day ends inside the last included day.
        item["end"] = event.endDate.map {
          Self.formatDateOnly(Self.exclusiveAllDayEnd($0, calendar: calendar), calendar: calendar)
        } ?? ""
      } else {
        item["start"] = Self.formatDateTime(event.startDate)
        item["end"] = event.endDate.map(Self.formatDateTime) ?? ""
      }
      items.append(item)
    }

    return Self.jsonString([
      "range_start": Self.formatDateTime(startDate),
      "range_end": Self.formatDateTime(endDate),
      "count": items.count,
      "events": items,
    ])
  }

  // MARK: - Calendar create

  private func createCalendarEvent(args: [String: Any]) -> String {
    let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let startRaw = (args["start"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !title.isEmpty, !startRaw.isEmpty else {
      return Self.errorPayload("MISSING_REQUIRED", "Both 'title' and 'start' are required.")
    }
    let allDay = Self.boolArg(args["all_day"]) ?? false

    let reminderMinutes = parseReminderMinutes(args)
    if reminderMinutes == Self.invalidReminderValue {
      return Self.errorPayload(
        "INVALID_REMINDER",
        "reminder_minutes must be a positive integer (minutes before start)."
      )
    }

    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = .current

    guard let startDate = Self.parseTime(startRaw, calendar: calendar) else {
      return Self.invalidTimePayload(startRaw)
    }
    let endDate: Date
    if let endRaw = args["end"] as? String, !endRaw.isEmpty {
      guard let parsedEnd = Self.parseTime(endRaw, calendar: calendar) else {
        return Self.invalidTimePayload(endRaw)
      }
      endDate = parsedEnd
    } else if allDay {
      let dayStart = calendar.startOfDay(for: startDate)
      endDate = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? startDate.addingTimeInterval(86400)
    } else {
      endDate = startDate.addingTimeInterval(3600)
    }
    guard startDate < endDate else {
      return Self.errorPayload("INVALID_RANGE", "end must be later than start.")
    }

    // For all-day events, normalize both ends to day boundaries first (like
    // Android's LocalDate comparison), so e.g. a 12:00-18:00 same-day range is
    // rejected instead of silently producing a degenerate event.
    let allDayStart = calendar.startOfDay(for: startDate)
    let allDayEndExclusive = calendar.startOfDay(for: endDate)
    if allDay, allDayStart >= allDayEndExclusive {
      return Self.errorPayload("INVALID_RANGE", "all-day event end date must be later than start date.")
    }

    guard let targetCalendar = eventStore.defaultCalendarForNewEvents else {
      return Self.errorPayload(
        "NO_CALENDAR",
        "No calendar account found on this device. Please add a calendar account first."
      )
    }

    let event = EKEvent(eventStore: eventStore)
    event.calendar = targetCalendar
    event.title = title
    if let notes = args["description"] as? String, !notes.isEmpty {
      event.notes = notes
    }
    if let location = args["location"] as? String, !location.isEmpty {
      event.location = location
    }
    if allDay {
      event.isAllDay = true
      event.startDate = allDayStart
      // The tool's 'end' is exclusive (next-day midnight); EventKit treats the
      // end date's day as included, so step back one second to avoid spilling
      // into an extra day. Payloads convert back to the exclusive date.
      event.endDate = allDayEndExclusive.addingTimeInterval(-1)
    } else {
      event.startDate = startDate
      event.endDate = endDate
    }
    if let reminderMinutes {
      // relativeOffset is seconds before start (negative = before).
      event.alarms = [EKAlarm(relativeOffset: TimeInterval(-reminderMinutes * 60))]
    }

    do {
      try eventStore.save(event, span: .thisEvent, commit: true)
    } catch {
      return Self.errorPayload("INSERT_FAILED", "Failed to save calendar event: \(error.localizedDescription)")
    }

    var payload: [String: Any] = [
      "success": true,
      "event_id": event.eventIdentifier ?? "",
      "title": title,
      "all_day": allDay,
      "location": event.location ?? "",
    ]
    if allDay {
      payload["start"] = Self.formatDateOnly(allDayStart, calendar: calendar)
      payload["end"] = Self.formatDateOnly(allDayEndExclusive, calendar: calendar)
    } else {
      payload["start"] = Self.formatDateTime(startDate)
      payload["end"] = Self.formatDateTime(endDate)
    }
    return Self.jsonString(payload)
  }

  /// Parses reminder_minutes; nil when omitted or JSON null, [invalidReminderValue] when invalid.
  private func parseReminderMinutes(_ args: [String: Any]) -> Int? {
    guard let raw = args["reminder_minutes"] else { return nil }
    if raw is NSNull { return nil }
    let minutes: Int?
    if let number = raw as? Int {
      minutes = number
    } else if let number = raw as? Double, number == number.rounded() {
      minutes = Int(number)
    } else if let text = raw as? String {
      minutes = Int(text.trimmingCharacters(in: .whitespaces))
    } else {
      minutes = nil
    }
    guard let minutes, minutes >= 1 else { return Self.invalidReminderValue }
    return minutes
  }

  // MARK: - Argument/JSON helpers

  private static func parseArgs(_ arguments: Any?) -> [String: Any] {
    guard
      let json = arguments as? String,
      let data = json.data(using: .utf8),
      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return [:]
    }
    return parsed
  }

  private static func intArg(_ value: Any?) -> Int? {
    if let number = value as? Int { return number }
    if let number = value as? Double { return Int(number) }
    if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
    return nil
  }

  private static func boolArg(_ value: Any?) -> Bool? {
    if let flag = value as? Bool { return flag }
    if let text = (value as? String)?.lowercased() {
      if text == "true" { return true }
      if text == "false" { return false }
    }
    return nil
  }

  private static let invalidReminderValue = Int.min

  private static func jsonString(_ payload: [String: Any]) -> String {
    guard
      let data = try? JSONSerialization.data(withJSONObject: payload),
      let text = String(data: data, encoding: .utf8)
    else {
      return "{\"error\":\"ENCODING_ERROR\",\"message\":\"Failed to encode tool result.\"}"
    }
    return text
  }

  private static func errorPayload(_ error: String, _ message: String) -> String {
    jsonString(["error": error, "message": message])
  }

  private static func invalidTimePayload(_ raw: String) -> String {
    errorPayload(
      "INVALID_TIME",
      "Invalid time format: '\(raw)'. Use ISO-8601 date/date-time or epoch milliseconds."
    )
  }

  // MARK: - Time parsing/formatting

  /// Parses epoch milliseconds, offset date-times, local date-times, and
  /// plain dates (interpreted at local midnight), mirroring the Android tool.
  private static func parseTime(_ raw: String, calendar: Calendar) -> Date? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty, text.allSatisfy({ $0.isNumber }), let millis = Double(text) {
      return Date(timeIntervalSince1970: millis / 1000.0)
    }

    let isoWithFraction = ISO8601DateFormatter()
    isoWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = isoWithFraction.date(from: text) { return date }

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: text) { return date }

    for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = calendar.timeZone
      formatter.dateFormat = format
      if let date = formatter.date(from: text) { return date }
    }
    return nil
  }

  private static func formatDateTime(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = .current
    return formatter.string(from: date)
  }

  private static func formatDateOnly(_ date: Date, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  /// Converts a stored all-day end date to the tool's exclusive end date.
  /// EventKit keeps the end inside the last included day (e.g. 23:59:59),
  /// while the tool reports the next-day midnight boundary. Ends already at
  /// an exact midnight are treated as exclusive and returned unchanged.
  private static func exclusiveAllDayEnd(_ end: Date, calendar: Calendar) -> Date {
    calendar.startOfDay(for: end.addingTimeInterval(1))
  }
}
