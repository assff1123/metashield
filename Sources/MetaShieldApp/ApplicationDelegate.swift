import AppKit
import UserNotifications

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate,
  UNUserNotificationCenterDelegate
{
  private enum ExternalRequest {
    case files([URL], operation: SanitizeOperation)
    case imageData(Data, suggestedName: String, operation: SanitizeOperation)
  }

  private var window: NSWindow?
  private var controller: MainViewController?
  private var serviceProvider: ImageServiceProvider?
  private var externalRequests: [ExternalRequest] = []
  private var isDeliveringExternalRequest = false
  private var hasExternalOpenRequest = false
  private var interactiveWindowShown = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    let isDefaultLaunch =
      (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? NSNumber)?.boolValue
      ?? false

    LegacyQuickActionCleaner.run()
    // Must run before the services are registered below, so a fresh install
    // shows only the scrubbing command in Finder.
    ServiceMenuSetup.seedDefaultsIfFirstLaunch()

    let controller = MainViewController()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.contentViewController = controller
    self.controller = controller
    self.window = window
    window.title = "MetaShield"
    window.minSize = NSSize(width: 540, height: 470)
    window.center()

    serviceProvider = ImageServiceProvider(applicationDelegate: self)
    NSApp.servicesProvider = serviceProvider
    NSUpdateDynamicServices()

    UpdateChecker.becomeNotificationDelegate(self)

    DispatchQueue.main.async { [weak self] in
      self?.deliverNextExternalRequestIfNeeded()
    }

    // AppKit explicitly tells us whether this was a normal user launch. It is
    // false for file-open and Services launches, so those requests never race
    // a timer that could flash the MetaShield window over Photos or Finder.
    if isDefaultLaunch {
      showInteractiveWindow()
    } else {
      // A malformed external launch that never delivers its request should
      // not leave an invisible background process running indefinitely.
      DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
        guard let self, !self.hasExternalOpenRequest, !self.interactiveWindowShown else { return }
        NSApp.terminate(nil)
      }
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    // Launch Services can report `open -a`, a Dock click, or a Finder app
    // launch as a reopen event even when the process has only just started.
    // Treat that explicit app activation as interactive, while preserving
    // the windowless path for file-open and Services requests.
    guard !hasExternalOpenRequest, externalRequests.isEmpty else { return false }
    showInteractiveWindow()
    return true
  }

  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    hasExternalOpenRequest = true
    let urls = filenames.map { URL(fileURLWithPath: $0) }
    // A plain file-open (Dock drag, Open With) is always the scrub command.
    externalRequests.append(.files(urls, operation: .scrubInPlace))
    deliverNextExternalRequestIfNeeded()
    sender.reply(toOpenOrPrint: .success)
  }

  fileprivate func deliverServiceURLs(_ urls: [URL], operation: SanitizeOperation) {
    hasExternalOpenRequest = true
    externalRequests.append(.files(urls, operation: operation))
    deliverNextExternalRequestIfNeeded()
  }

  fileprivate func deliverServiceImageData(_ data: Data, operation: SanitizeOperation) {
    hasExternalOpenRequest = true
    let name = operation.isConversion ? "Converted Image.png" : "Cleaned Image.png"
    externalRequests.append(.imageData(data, suggestedName: name, operation: operation))
    deliverNextExternalRequestIfNeeded()
  }

  private func deliverNextExternalRequestIfNeeded() {
    guard let controller,
      !isDeliveringExternalRequest,
      !externalRequests.isEmpty
    else { return }

    isDeliveringExternalRequest = true
    let request = externalRequests.removeFirst()
    let completion: (Bool) -> Void = { [weak self] _ in
      guard let self else { return }
      self.isDeliveringExternalRequest = false
      if self.externalRequests.isEmpty {
        self.finishSilentRequest()
      } else {
        self.deliverNextExternalRequestIfNeeded()
      }
    }

    switch request {
    case .files(let urls, let operation):
      controller.receiveFileURLs(
        urls, operation: operation, silently: true, completion: completion)
    case .imageData(let data, let suggestedName, let operation):
      controller.receiveImageData(
        data,
        suggestedName: suggestedName,
        operation: operation,
        silently: true,
        completion: completion
      )
    }
  }

  private func showInteractiveWindow() {
    interactiveWindowShown = true
    NSApp.setActivationPolicy(.regular)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    // Headless Finder, Services, and Photos requests never reach this path, so
    // they never touch the network.
    controller?.checkForUpdatesIfDue()
  }

  private func finishSilentRequest() {
    guard !interactiveWindowShown else { return }
    // A headless run may post a result summary and a "new version" banner, but
    // it never prompts for notification permission and never stays alive
    // waiting for the network. The exit chains after both posts so the local
    // notification request reaches the system before the process terminates.
    let result = controller?.consumePendingSilentResult()
    BackgroundResultNotifier.postIfNeeded(
      successCount: result?.successCount ?? 0,
      failureCount: result?.failureCount ?? 0,
      firstFailureDescription: result?.firstFailureDescription
    ) {
      UpdateChecker.notifyIfUpdateAvailableInBackground {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          NSApp.terminate(nil)
        }
      }
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let category = response.notification.request.content.categoryIdentifier
    completionHandler()
    Task { @MainActor in
      self.handleNotificationActivation(category: category)
    }
  }

  private func handleNotificationActivation(category: String) {
    switch category {
    case UpdateChecker.updateNotificationCategory:
      // Bring up the window instead of the browser: the verified download lives
      // there, and a browser download would skip signature and checksum checks.
      showInteractiveWindow()
      controller?.checkForUpdatesNow()
    case BackgroundResultNotifier.resultNotificationCategory:
      showInteractiveWindow()
    default:
      break
    }
  }
}

@MainActor
private final class ImageServiceProvider: NSObject {
  weak var applicationDelegate: ApplicationDelegate?

  init(applicationDelegate: ApplicationDelegate) {
    self.applicationDelegate = applicationDelegate
  }

  @objc func sanitizeSelection(
    _ pasteboard: NSPasteboard,
    userData: String?,
    error: AutoreleasingUnsafeMutablePointer<NSString?>
  ) {
    deliver(pasteboard, operation: .scrubInPlace, error: error)
  }

  @objc func convertToAVIF(
    _ pasteboard: NSPasteboard,
    userData: String?,
    error: AutoreleasingUnsafeMutablePointer<NSString?>
  ) {
    deliver(pasteboard, operation: .convertToAVIF(.high), error: error)
  }

  @objc func convertToAVIFCompressed(
    _ pasteboard: NSPasteboard,
    userData: String?,
    error: AutoreleasingUnsafeMutablePointer<NSString?>
  ) {
    deliver(pasteboard, operation: .convertToAVIF(AVIFSettings.compressedQuality), error: error)
  }

  private func deliver(
    _ pasteboard: NSPasteboard,
    operation: SanitizeOperation,
    error: AutoreleasingUnsafeMutablePointer<NSString?>
  ) {
    let urls =
      pasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]
      ) as? [URL] ?? []

    if !urls.isEmpty {
      applicationDelegate?.deliverServiceURLs(urls, operation: operation)
      return
    }
    if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
      applicationDelegate?.deliverServiceImageData(data, operation: operation)
      return
    }
    error.pointee = "선택한 앱이 파일 경로나 이미지 데이터를 제공하지 않았습니다." as NSString
  }
}
