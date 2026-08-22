import AppKit
import MetaShieldCore
import Photos
import UniformTypeIdentifiers

@main
@MainActor
private enum MetaShieldApplication {
  static func main() {
    let application = NSApplication.shared
    let delegate = ApplicationDelegate()
    application.delegate = delegate
    // File-open, Services, and Photos hand-offs must remain completely
    // background-only. A normal app launch promotes itself when showing UI.
    application.setActivationPolicy(.accessory)
    application.run()
  }
}

@MainActor
private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
  private enum ExternalRequest {
    case files([URL])
    case imageData(Data, suggestedName: String)
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

    let controller = MainViewController()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.contentViewController = controller
    self.controller = controller
    self.window = window
    window.title = "MetaShield"
    window.minSize = NSSize(width: 540, height: 440)
    window.center()

    serviceProvider = ImageServiceProvider(applicationDelegate: self)
    NSApp.servicesProvider = serviceProvider
    NSUpdateDynamicServices()

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
    externalRequests.append(.files(urls))
    deliverNextExternalRequestIfNeeded()
    sender.reply(toOpenOrPrint: .success)
  }

  fileprivate func deliverServiceURLs(_ urls: [URL]) {
    hasExternalOpenRequest = true
    externalRequests.append(.files(urls))
    deliverNextExternalRequestIfNeeded()
  }

  fileprivate func deliverServiceImageData(_ data: Data) {
    hasExternalOpenRequest = true
    externalRequests.append(.imageData(data, suggestedName: "Cleaned Image.png"))
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
    case .files(let urls):
      controller.receiveFileURLs(urls, silently: true, completion: completion)
    case .imageData(let data, let suggestedName):
      controller.receiveImageData(
        data,
        suggestedName: suggestedName,
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
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      NSApp.terminate(nil)
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
    let urls =
      pasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]
      ) as? [URL] ?? []

    if !urls.isEmpty {
      applicationDelegate?.deliverServiceURLs(urls)
      return
    }
    if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
      applicationDelegate?.deliverServiceImageData(data)
      return
    }
    error.pointee = "선택한 앱이 파일 경로나 이미지 데이터를 제공하지 않았습니다." as NSString
  }
}

/// `NSFilePromiseReceiver` invokes its callback once per promised file, not once
/// per receiver. Track every callback explicitly so multi-file Photos drags cannot
/// unbalance a DispatchGroup or finish before all promised files arrive.
private final class FilePromiseReceptionCoordinator: @unchecked Sendable {
  private struct ReceiverState {
    var expectedCallbacks: Int?
    var callbackCount = 0
    var completed = false
  }

  private let lock = NSLock()
  private let destinationDirectory: URL
  private var states: [ReceiverState]
  private var receivedURLs: [URL] = []
  private var errors: [Error] = []
  private var finished = false
  private var completion: (@Sendable ([URL], [Error]) -> Void)?

  init(
    receiverCount: Int,
    destinationDirectory: URL,
    completion: @escaping @Sendable ([URL], [Error]) -> Void
  ) {
    states = Array(repeating: ReceiverState(), count: receiverCount)
    self.destinationDirectory = destinationDirectory.standardizedFileURL
    self.completion = completion
  }

  func setExpectedCallbackCount(_ count: Int, for receiverIndex: Int) {
    lock.lock()
    guard !finished, states.indices.contains(receiverIndex) else {
      lock.unlock()
      return
    }
    states[receiverIndex].expectedCallbacks = max(1, count)
    updateCompletionState(for: receiverIndex)
    lock.unlock()
    finishIfReady()
  }

  func record(url: URL, error: Error?, for receiverIndex: Int) {
    lock.lock()
    guard !finished, states.indices.contains(receiverIndex) else {
      lock.unlock()
      return
    }

    states[receiverIndex].callbackCount += 1
    if let error {
      errors.append(error)
    } else if let safeURL = validatedReceivedURL(url) {
      receivedURLs.append(safeURL)
    } else {
      errors.append(MetaShieldError.fileOperationFailed("안전한 임시 폴더 밖의 파일은 처리하지 않습니다."))
    }
    updateCompletionState(for: receiverIndex)
    lock.unlock()
    finishIfReady()
  }

  func timeout() {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    errors.append(MetaShieldError.fileOperationFailed("사진 앱이 60초 안에 모든 원본을 전달하지 않았습니다."))
    for index in states.indices {
      states[index].completed = true
    }
    lock.unlock()
    finishIfReady()
  }

  private func validatedReceivedURL(_ url: URL) -> URL? {
    let root = destinationDirectory.resolvingSymlinksInPath().path
    let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
    guard candidate.path.hasPrefix(root + "/"),
      FileManager.default.fileExists(atPath: candidate.path)
    else {
      return nil
    }
    return candidate
  }

  private func updateCompletionState(for receiverIndex: Int) {
    guard let expected = states[receiverIndex].expectedCallbacks,
      states[receiverIndex].callbackCount >= expected
    else { return }
    states[receiverIndex].completed = true
  }

  private func finishIfReady() {
    let result: ((@Sendable ([URL], [Error]) -> Void), [URL], [Error])?
    lock.lock()
    if !finished, states.allSatisfy(\.completed), let completion {
      finished = true
      self.completion = nil
      result = (completion, receivedURLs, errors)
    } else {
      result = nil
    }
    lock.unlock()
    if let result {
      result.0(result.1, result.2)
    }
  }
}

private struct ProcessingFailure: @unchecked Sendable {
  let url: URL
  let error: Error
}

private final class MainViewController: NSViewController, @unchecked Sendable {
  private let titleLabel = NSTextField(labelWithString: "이미지의 숨은 정보를 남김없이 비웁니다")
  private let subtitleLabel = NSTextField(
    wrappingLabelWithString:
      "PNG는 검증 후 원본을 영구 교체하며 투명도는 흰색으로 합성합니다. 다른 형식과 사진 앱·브라우저 이미지는 깨끗한 RGB PNG 사본으로 저장합니다.")
  private let dropZone = DropZoneView()
  private let statusLabel = NSTextField(wrappingLabelWithString: "이미지를 이곳에 놓거나 아래 버튼으로 선택하세요.")
  private let chooseButton = NSButton(title: "이미지 선택…", target: nil, action: nil)
  private let installQuickActionButton = NSButton(
    title: "Finder 빠른 동작 설치/복구", target: nil, action: nil)
  private let spinner = NSProgressIndicator()
  private let updateToggle = NSButton(
    checkboxWithTitle: "새 버전 확인 (GitHub)", target: nil, action: nil)
  private let updateStatusLabel = NSTextField(labelWithString: "")
  private let openReleaseButton = NSButton(title: "새 버전 받기…", target: nil, action: nil)
  private var isProcessing = false
  private var isSilentProcessing = false
  private var processingCompletion: ((Bool) -> Void)?
  private var temporaryInputDirectories: [URL] = []
  private var activePhotoImportToken: UUID?

  override func loadView() {
    view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false

    titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
    titleLabel.alignment = .center
    subtitleLabel.font = .systemFont(ofSize: 13)
    subtitleLabel.textColor = .secondaryLabelColor
    subtitleLabel.alignment = .center
    subtitleLabel.maximumNumberOfLines = 3
    statusLabel.alignment = .center
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.maximumNumberOfLines = 4
    statusLabel.setAccessibilityLabel("처리 상태")

    chooseButton.target = self
    chooseButton.action = #selector(chooseImages)
    chooseButton.bezelStyle = .rounded
    chooseButton.controlSize = .large
    chooseButton.keyEquivalent = "o"
    chooseButton.keyEquivalentModifierMask = [.command]
    chooseButton.setAccessibilityHelp("파일 선택 창을 열어 한 개 이상의 이미지를 선택합니다.")

    installQuickActionButton.target = self
    installQuickActionButton.action = #selector(installQuickAction)
    installQuickActionButton.bezelStyle = .rounded
    installQuickActionButton.controlSize = .large
    installQuickActionButton.setAccessibilityHelp(
      "Finder 이미지 우클릭 메뉴용 빠른 동작을 설치하거나 복구합니다. Finder가 다시 시작될 수 있습니다.")

    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false

    updateToggle.target = self
    updateToggle.action = #selector(toggleUpdateCheck)
    updateToggle.state = UpdateChecker.isEnabled ? .on : .off
    updateToggle.setAccessibilityHelp(
      "켜면 하루에 한 번 GitHub 릴리스에서 새 버전 번호만 확인합니다. 앱이 직접 내려받거나 설치하지 않습니다.")

    updateStatusLabel.font = .systemFont(ofSize: 11)
    updateStatusLabel.textColor = .tertiaryLabelColor
    updateStatusLabel.alignment = .center
    updateStatusLabel.setAccessibilityLabel("업데이트 확인 상태")

    openReleaseButton.target = self
    openReleaseButton.action = #selector(openReleasePage)
    openReleaseButton.bezelStyle = .rounded
    openReleaseButton.isHidden = true
    openReleaseButton.setAccessibilityHelp("기본 브라우저에서 MetaShield 릴리스 페이지를 엽니다.")

    dropZone.onFileURLs = { [weak self] urls in
      self?.receiveFileURLs(urls)
    }
    dropZone.onImageData = { [weak self] data in
      self?.receiveImageData(data, suggestedName: "Dropped Image.png")
    }
    dropZone.onFilePromises = { [weak self] promises in
      self?.receiveFilePromises(promises)
    }

    let statusRow = NSStackView(views: [spinner, statusLabel])
    statusRow.orientation = .horizontal
    statusRow.spacing = 8
    statusRow.alignment = .centerY

    let buttonRow = NSStackView(views: [chooseButton, installQuickActionButton])
    buttonRow.orientation = .horizontal
    buttonRow.spacing = 10
    buttonRow.alignment = .centerY

    let updateRow = NSStackView(views: [updateToggle, openReleaseButton])
    updateRow.orientation = .horizontal
    updateRow.spacing = 10
    updateRow.alignment = .centerY

    let stack = NSStackView(views: [
      titleLabel, subtitleLabel, dropZone, statusRow, buttonRow, updateRow, updateStatusLabel,
    ])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 14
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
      stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 30),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24),
      titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
      subtitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
      dropZone.widthAnchor.constraint(equalTo: stack.widthAnchor),
      dropZone.heightAnchor.constraint(equalToConstant: 190),
      statusRow.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
      statusLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -28),
      updateRow.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
      updateStatusLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
    ])
  }

  @objc private func chooseImages() {
    guard !isProcessing else { return }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = [.image]
    panel.message = "정리할 이미지를 선택하세요. PNG는 투명도·Finder 태그를 제거하고 원본을 덮어씁니다."
    if panel.runModal() == .OK {
      receiveFileURLs(panel.urls)
    }
  }

  @objc private func toggleUpdateCheck() {
    let isEnabled = updateToggle.state == .on
    UpdateChecker.isEnabled = isEnabled
    guard isEnabled else {
      updateStatusLabel.stringValue = ""
      openReleaseButton.isHidden = true
      return
    }
    updateStatusLabel.stringValue = "새 버전을 확인하는 중…"
    let didStart = UpdateChecker.checkIfDue { [weak self] outcome in
      self?.presentUpdateOutcome(outcome)
    }
    if !didStart {
      updateStatusLabel.stringValue = "오늘 이미 새 버전을 확인했습니다."
      updateStatusLabel.textColor = .tertiaryLabelColor
      openReleaseButton.isHidden = true
    }
  }

  @objc private func openReleasePage() {
    // The release page is compiled in. Nothing from the network can change it.
    NSWorkspace.shared.open(UpdateChecker.releasePageURL)
  }

  func checkForUpdatesIfDue() {
    UpdateChecker.checkIfDue { [weak self] outcome in
      self?.presentUpdateOutcome(outcome)
    }
  }

  private func presentUpdateOutcome(_ outcome: UpdateChecker.Outcome) {
    // Turning the option off cannot retract a request already sent, but a late
    // callback must not restore update UI after the user disabled the feature.
    guard updateToggle.state == .on, UpdateChecker.isEnabled else { return }
    switch outcome {
    case .updateAvailable(let latest):
      updateStatusLabel.stringValue = "새 버전 \(latest)이(가) 나왔습니다."
      updateStatusLabel.textColor = .controlAccentColor
      openReleaseButton.isHidden = false
    case .upToDate(let current):
      updateStatusLabel.stringValue = "최신 버전입니다 (\(current))."
      updateStatusLabel.textColor = .tertiaryLabelColor
      openReleaseButton.isHidden = true
    case .failed:
      updateStatusLabel.stringValue = "새 버전을 확인하지 못했습니다."
      updateStatusLabel.textColor = .tertiaryLabelColor
      openReleaseButton.isHidden = true
    }
    NSAccessibility.post(element: updateStatusLabel, notification: .valueChanged)
  }

  @objc private func installQuickAction() {
    guard let resources = Bundle.main.resourceURL else {
      showStatus("앱 리소스 폴더를 찾지 못했습니다.", isError: true)
      return
    }
    let bundledWorkflowName = "MetaShieldQuickAction.workflow"
    let installedWorkflowName = "MetaShield 메타데이터 완전 제거.workflow"
    let source = resources.appendingPathComponent(bundledWorkflowName, isDirectory: true)
    let services = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Services", isDirectory: true)
    let destination = services.appendingPathComponent(installedWorkflowName, isDirectory: true)
    let temporary = services.appendingPathComponent(
      ".MetaShield-\(UUID().uuidString).workflow", isDirectory: true)

    do {
      guard FileManager.default.fileExists(atPath: source.path) else {
        throw MetaShieldError.fileOperationFailed("Finder 빠른 동작 리소스가 없습니다.")
      }
      try FileManager.default.createDirectory(at: services, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: source, to: temporary)
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(
          destination,
          withItemAt: temporary,
          backupItemName: nil,
          options: [.usingNewMetadataOnly]
        )
      } else {
        try FileManager.default.moveItem(at: temporary, to: destination)
      }
      let refreshWarnings = refreshServicesDatabase()
      if refreshWarnings.isEmpty {
        showStatus("Finder 빠른 동작을 설치했고 Finder를 다시 시작했습니다. 이미지 우클릭 → 빠른 동작에서 사용하세요.", isError: false)
      } else {
        showStatus(
          "빠른 동작 파일은 설치됐지만 자동 등록에 실패했습니다. 시스템 설정 → 일반 → 로그인 항목 및 확장 프로그램에서 MetaShield를 켜세요.",
          isError: true)
      }
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      showStatus("빠른 동작 설치 실패: \(error.localizedDescription)", isError: true)
    }
  }

  private func refreshServicesDatabase() -> [String] {
    NSUpdateDynamicServices()
    let quickActionIdentifier = "kr.metashield.quick-action"
    var warnings: [String] = []

    // On macOS 26, copying a workflow to ~/Library/Services registers it with
    // pbs but does not necessarily enable it in Finder's Quick Actions menu.
    // Keep the user's existing entries and add MetaShield explicitly.
    if !runAndWait(
      executable: "/usr/bin/defaults",
      arguments: [
        "write", "pbs", "FinderActive", "-dict-add",
        quickActionIdentifier, "-bool", "true",
      ]
    ) {
      warnings.append("FinderActive")
    }
    if !runAndWait(
      executable: "/usr/bin/defaults",
      arguments: [
        "write", "pbs", "FinderOrdering", "-dict-add",
        quickActionIdentifier, "-int", "999",
      ]
    ) {
      warnings.append("FinderOrdering")
    }
    if !runAndWait(
      executable: "/System/Library/CoreServices/pbs",
      arguments: ["-flush", "ko", "en"]
    ) {
      warnings.append("pbs flush")
    }
    if !runAndWait(
      executable: "/System/Library/CoreServices/pbs",
      arguments: ["-update"]
    ) {
      warnings.append("pbs update")
    }
    if !runAndWait(executable: "/usr/bin/killall", arguments: ["Finder"]) {
      warnings.append("Finder restart")
    }
    return warnings
  }

  private func runAndWait(executable: String, arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      // Installation has already completed at this point. The status text
      // tells the user where to enable the item manually if refresh fails.
      return false
    }
  }

  func receiveFileURLs(
    _ urls: [URL],
    silently: Bool = false,
    completion: ((Bool) -> Void)? = nil
  ) {
    guard !isProcessing else {
      reportImmediateFailure("다른 이미지 작업이 끝난 뒤 다시 시도하세요.", silently: silently)
      completion?(false)
      return
    }
    let files = Self.deduplicatedFileURLs(urls)
    guard files.count <= 100 else {
      reportImmediateFailure("한 번에 최대 100개 이미지까지 처리할 수 있습니다.", silently: silently)
      completion?(false)
      return
    }
    guard !files.isEmpty else {
      reportImmediateFailure("처리할 파일을 찾지 못했습니다.", silently: silently)
      completion?(false)
      return
    }

    let managedFiles = files.filter { ImageInputLocationPolicy.shouldImportIntoPhotos($0) }
    let managedSet = Set(managedFiles)
    let pngFiles = files.filter {
      $0.pathExtension.lowercased() == "png"
        && !managedSet.contains($0)
        && ImageInputLocationPolicy.canReplaceInPlace($0)
    }
    let pngSet = Set(pngFiles)
    let copyFiles = files.filter { !managedSet.contains($0) && !pngSet.contains($0) }

    var managedOutputDirectory: URL?
    if !managedFiles.isEmpty {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MetaShieldImport-\(UUID().uuidString)", isDirectory: true)
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryInputDirectories.append(directory)
        managedOutputDirectory = directory
      } catch {
        reportImmediateFailure("사진 보관함 가져오기용 임시 폴더를 만들지 못했습니다.", silently: silently)
        completion?(false)
        return
      }
    }

    isSilentProcessing = silently
    processingCompletion = completion
    beginProcessing()
    let importDirectory = managedOutputDirectory
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      var successes: [URL] = []
      var failures: [ProcessingFailure] = []
      var photosOutputs: [URL] = []
      let sanitizer = ImageSanitizer()

      for url in pngFiles {
        do {
          let report = try sanitizer.sanitizePNGInPlace(at: url)
          successes.append(report.url)
        } catch {
          failures.append(ProcessingFailure(url: url, error: error))
        }
      }

      for url in copyFiles {
        do {
          let destinationDirectory = try Self.automaticOutputDirectory(for: url)
          let destination = Self.uniqueOutputURL(
            in: destinationDirectory,
            baseName: url.deletingPathExtension().lastPathComponent
          )
          let report = try sanitizer.writeCanonicalPNG(from: url, to: destination)
          successes.append(report.url)
        } catch {
          failures.append(ProcessingFailure(url: url, error: error))
        }
      }

      if let importDirectory {
        for url in managedFiles {
          do {
            let destination = Self.uniqueOutputURL(
              in: importDirectory,
              baseName: url.deletingPathExtension().lastPathComponent
            )
            let report = try sanitizer.writeCanonicalPNG(from: url, to: destination)
            photosOutputs.append(report.url)
          } catch {
            failures.append(ProcessingFailure(url: url, error: error))
          }
        }
      }

      if photosOutputs.isEmpty {
        let finalSuccesses = successes
        let finalFailures = failures
        Task { @MainActor in
          self.finishProcessing(successes: finalSuccesses, failures: finalFailures)
        }
      } else {
        let finalOutputs = photosOutputs
        let finalSuccesses = successes
        let finalFailures = failures
        let sourceForError = managedFiles[0]
        Task { @MainActor in
          self.importIntoPhotos(
            finalOutputs,
            successes: finalSuccesses,
            failures: finalFailures,
            sourceForError: sourceForError
          )
        }
      }
    }
  }

  func receiveImageData(
    _ data: Data,
    suggestedName: String,
    silently: Bool = false,
    completion: ((Bool) -> Void)? = nil
  ) {
    guard !isProcessing else {
      reportImmediateFailure("다른 이미지 작업이 끝난 뒤 다시 시도하세요.", silently: silently)
      completion?(false)
      return
    }
    let destination: URL
    do {
      let directory = try Self.defaultOutputDirectory()
      let baseName = URL(fileURLWithPath: suggestedName)
        .deletingPathExtension().lastPathComponent
      destination = Self.uniqueOutputURL(in: directory, baseName: baseName)
    } catch {
      reportImmediateFailure(
        "자동 저장 폴더를 준비하지 못했습니다: \(error.localizedDescription)", silently: silently)
      completion?(false)
      return
    }

    isSilentProcessing = silently
    processingCompletion = completion
    beginProcessing()
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      do {
        let report = try ImageSanitizer().writeCanonicalPNG(from: data, to: destination)
        Task { @MainActor in
          self.finishProcessing(successes: [report.url], failures: [])
        }
      } catch {
        let failure = ProcessingFailure(url: destination, error: error)
        Task { @MainActor in
          self.finishProcessing(successes: [], failures: [failure])
        }
      }
    }
  }

  private func importIntoPhotos(
    _ urls: [URL],
    successes: [URL],
    failures: [ProcessingFailure],
    sourceForError: URL
  ) {
    showStatus("정리된 이미지를 사진 보관함에 추가하는 중…", isError: false)
    let authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    let needsVisiblePermissionPrompt = isSilentProcessing && authorizationStatus == .notDetermined
    let token = UUID()
    activePhotoImportToken = token

    // TCC and Photos callbacks are system services. They normally respond
    // immediately but must not leave a headless file-open process alive
    // forever if either service stops replying.
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
      guard let self, self.activePhotoImportToken == token else { return }
      let error = NSError(
        domain: "kr.metashield.app.photos",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "사진 보관함이 60초 안에 응답하지 않았습니다."]
      )
      self.completePhotoImport(
        token: token,
        restoreAccessoryPolicy: needsVisiblePermissionPrompt,
        successes: successes,
        failures: failures + [ProcessingFailure(url: sourceForError, error: error)]
      )
    }

    switch authorizationStatus {
    case .authorized, .limited:
      performPhotoImport(
        urls,
        token: token,
        restoreAccessoryPolicy: false,
        successes: successes,
        failures: failures,
        sourceForError: sourceForError
      )
    case .notDetermined:
      requestPhotoAuthorization(
        urls,
        token: token,
        restoreAccessoryPolicy: needsVisiblePermissionPrompt,
        successes: successes,
        failures: failures,
        sourceForError: sourceForError
      )
    case .denied, .restricted:
      let error = NSError(
        domain: "kr.metashield.app.photos",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "사진 보관함 추가 권한이 필요합니다."]
      )
      completePhotoImport(
        token: token,
        restoreAccessoryPolicy: false,
        successes: successes,
        failures: failures + [ProcessingFailure(url: sourceForError, error: error)]
      )
    @unknown default:
      let error = NSError(
        domain: "kr.metashield.app.photos",
        code: 4,
        userInfo: [NSLocalizedDescriptionKey: "알 수 없는 사진 보관함 권한 상태입니다."]
      )
      completePhotoImport(
        token: token,
        restoreAccessoryPolicy: false,
        successes: successes,
        failures: failures + [ProcessingFailure(url: sourceForError, error: error)]
      )
    }
  }

  private func requestPhotoAuthorization(
    _ urls: [URL],
    token: UUID,
    restoreAccessoryPolicy: Bool,
    successes: [URL],
    failures: [ProcessingFailure],
    sourceForError: URL
  ) {
    if restoreAccessoryPolicy {
      // A first-run TCC prompt can otherwise remain behind the source app
      // while this process is an accessory. Only the system permission
      // prompt becomes visible; the MetaShield window stays closed.
      NSApp.setActivationPolicy(.regular)
      NSApp.activate(ignoringOtherApps: true)
    }
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { [self] status in
      Task { @MainActor in
        guard self.activePhotoImportToken == token else { return }
        guard status == .authorized || status == .limited else {
          let error = NSError(
            domain: "kr.metashield.app.photos",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "사진 보관함 추가 권한이 필요합니다."]
          )
          self.completePhotoImport(
            token: token,
            restoreAccessoryPolicy: restoreAccessoryPolicy,
            successes: successes,
            failures: failures + [ProcessingFailure(url: sourceForError, error: error)]
          )
          return
        }
        self.performPhotoImport(
          urls,
          token: token,
          restoreAccessoryPolicy: restoreAccessoryPolicy,
          successes: successes,
          failures: failures,
          sourceForError: sourceForError
        )
      }
    }
  }

  private func performPhotoImport(
    _ urls: [URL],
    token: UUID,
    restoreAccessoryPolicy: Bool,
    successes: [URL],
    failures: [ProcessingFailure],
    sourceForError: URL
  ) {
    PHPhotoLibrary.shared().performChanges {
      for url in urls {
        PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
      }
    } completionHandler: { [self] imported, error in
      Task { @MainActor in
        guard self.activePhotoImportToken == token else { return }
        if imported {
          self.completePhotoImport(
            token: token,
            restoreAccessoryPolicy: restoreAccessoryPolicy,
            successes: successes + urls,
            failures: failures
          )
        } else {
          let importError =
            error
            ?? NSError(
              domain: "kr.metashield.app.photos",
              code: 2,
              userInfo: [NSLocalizedDescriptionKey: "사진 보관함에 추가하지 못했습니다."]
            )
          self.completePhotoImport(
            token: token,
            restoreAccessoryPolicy: restoreAccessoryPolicy,
            successes: successes,
            failures: failures + [ProcessingFailure(url: sourceForError, error: importError)]
          )
        }
      }
    }
  }

  private func completePhotoImport(
    token: UUID,
    restoreAccessoryPolicy: Bool,
    successes: [URL],
    failures: [ProcessingFailure]
  ) {
    guard activePhotoImportToken == token else { return }
    activePhotoImportToken = nil
    if restoreAccessoryPolicy {
      NSApp.setActivationPolicy(.accessory)
    }
    finishProcessing(successes: successes, failures: failures)
  }

  func receiveFilePromises(_ promises: [NSFilePromiseReceiver]) {
    guard !isProcessing, !promises.isEmpty else { return }
    guard promises.count <= 100 else {
      showStatus("한 번에 최대 100개 이미지까지 처리할 수 있습니다.", isError: true)
      return
    }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MetaShieldDrop-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      showStatus("드래그한 이미지를 받을 임시 폴더를 만들지 못했습니다.", isError: true)
      return
    }

    temporaryInputDirectories.append(directory)
    beginProcessing()
    showStatus("사진 앱에서 원본 데이터를 받는 중…", isError: false)
    let queue = OperationQueue()
    queue.qualityOfService = .userInitiated
    let coordinator = FilePromiseReceptionCoordinator(
      receiverCount: promises.count,
      destinationDirectory: directory
    ) { [self] received, receiveErrors in
      queue.cancelAllOperations()
      Task { @MainActor in
        self.resetProcessingControls()
        if let firstError = receiveErrors.first {
          try? FileManager.default.removeItem(at: directory)
          self.temporaryInputDirectories.removeAll { $0 == directory }
          self.showStatus(
            "사진 앱에서 이미지 데이터를 받지 못했습니다: \(firstError.localizedDescription)", isError: true)
        } else if received.isEmpty {
          try? FileManager.default.removeItem(at: directory)
          self.temporaryInputDirectories.removeAll { $0 == directory }
          self.showStatus("사진 앱에서 이미지 데이터를 받지 못했습니다.", isError: true)
        } else if received.count > 100 {
          try? FileManager.default.removeItem(at: directory)
          self.temporaryInputDirectories.removeAll { $0 == directory }
          self.showStatus("한 번에 최대 100개 이미지까지 처리할 수 있습니다.", isError: true)
        } else {
          self.receiveFileURLs(received)
        }
      }
    }

    for (index, promise) in promises.enumerated() {
      promise.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: queue) {
        url, error in
        coordinator.record(url: url, error: error, for: index)
      }
      coordinator.setExpectedCallbackCount(promise.fileNames.count, for: index)
    }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) {
      coordinator.timeout()
    }
  }

  private func beginProcessing() {
    isProcessing = true
    chooseButton.isEnabled = false
    installQuickActionButton.isEnabled = false
    dropZone.isEnabled = false
    spinner.startAnimation(nil)
    showStatus("디코딩·정리·재검증 중…", isError: false)
  }

  private func finishProcessing(successes: [URL], failures: [ProcessingFailure]) {
    let wasSilent = isSilentProcessing
    let completion = processingCompletion
    isSilentProcessing = false
    processingCompletion = nil
    resetProcessingControls()

    if failures.isEmpty {
      showStatus("완료: \(successes.count)개 이미지가 검증을 통과했습니다.", isError: false)
      if !wasSilent { NSSound(named: "Glass")?.play() }
    } else {
      let first = failures[0]
      showStatus(
        "완료 \(successes.count)개, 실패 \(failures.count)개\n\(first.url.lastPathComponent): \(first.error.localizedDescription)",
        isError: true)
      if !wasSilent { NSSound.beep() }
    }

    for directory in temporaryInputDirectories {
      try? FileManager.default.removeItem(at: directory)
    }
    temporaryInputDirectories.removeAll()
    completion?(failures.isEmpty)
  }

  private func resetProcessingControls() {
    isProcessing = false
    chooseButton.isEnabled = true
    installQuickActionButton.isEnabled = true
    dropZone.isEnabled = true
    spinner.stopAnimation(nil)
  }

  private func showStatus(_ text: String, isError: Bool) {
    statusLabel.stringValue = text
    statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    NSAccessibility.post(element: statusLabel, notification: .valueChanged)
  }

  private func reportImmediateFailure(_ message: String, silently: Bool) {
    showStatus(message, isError: true)
    if !silently {
      NSSound.beep()
    }
  }

  nonisolated private static func uniqueOutputURL(in directory: URL, baseName: String) -> URL {
    let safeBase = baseName.isEmpty ? "Cleaned Image" : baseName
    var candidate = directory.appendingPathComponent("\(safeBase).clean.png")
    var index = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = directory.appendingPathComponent("\(safeBase).clean-\(index).png")
      index += 1
    }
    return candidate
  }

  nonisolated private static func automaticOutputDirectory(for source: URL) throws -> URL {
    let sourceDirectory = source.deletingLastPathComponent().standardizedFileURL
    if FileManager.default.isWritableFile(atPath: sourceDirectory.path) {
      return sourceDirectory
    }
    return try defaultOutputDirectory()
  }

  nonisolated private static func defaultOutputDirectory() throws -> URL {
    let fileManager = FileManager.default
    let directory =
      fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        "Downloads", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  nonisolated private static func deduplicatedFileURLs(_ urls: [URL]) -> [URL] {
    var seen: Set<String> = []
    return urls.filter { url in
      guard url.isFileURL else { return false }
      return seen.insert(url.standardizedFileURL.path).inserted
    }
  }
}

private final class DropZoneView: NSView {
  var onFileURLs: (([URL]) -> Void)?
  var onImageData: ((Data) -> Void)?
  var onFilePromises: (([NSFilePromiseReceiver]) -> Void)?
  var isEnabled = true

  private let label = NSTextField(labelWithString: "PNG · JPEG · HEIC · WebP 등\n여기로 드래그")
  private var highlighted = false {
    didSet { needsDisplay = true }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map {
      NSPasteboard.PasteboardType($0)
    }
    registerForDraggedTypes([.fileURL, .png, .tiff] + promiseTypes)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("이미지 드롭 영역")
    setAccessibilityHelp("이미지를 이 영역에 놓으세요. 키보드 사용자는 Command-O 또는 이미지 선택 버튼을 사용할 수 있습니다.")

    label.alignment = .center
    label.font = .systemFont(ofSize: 16, weight: .medium)
    label.textColor = .secondaryLabelColor
    label.maximumNumberOfLines = 2
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: centerXAnchor),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let bounds = self.bounds.insetBy(dx: 1, dy: 1)
    let path = NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16)
    (highlighted
      ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor)
      .setFill()
    path.fill()
    (highlighted ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
    path.lineWidth = highlighted ? 2 : 1
    path.setLineDash([7, 5], count: 2, phase: 0)
    path.stroke()
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard isEnabled, canRead(sender.draggingPasteboard) else { return [] }
    highlighted = true
    return .copy
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    highlighted = false
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    isEnabled && canRead(sender.draggingPasteboard)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    highlighted = false
    let pasteboard = sender.draggingPasteboard
    let urls =
      pasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]
      ) as? [URL] ?? []
    if !urls.isEmpty {
      onFileURLs?(urls)
      return true
    }
    let promises =
      pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]
      ?? []
    if !promises.isEmpty {
      onFilePromises?(promises)
      return true
    }
    if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
      onImageData?(data)
      return true
    }
    return false
  }

  private func canRead(_ pasteboard: NSPasteboard) -> Bool {
    pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
      || pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self])
      || pasteboard.availableType(from: [.png, .tiff]) != nil
  }
}

/// Receives the release response incrementally so the configured byte limit is
/// an actual transfer limit rather than a check performed after URLSession has
/// buffered the whole body. Redirects are rejected: the opt-in request is only
/// allowed to reach the exact HTTPS endpoint compiled into the app.
private final class BoundedUpdateSessionDelegate: NSObject, URLSessionDataDelegate,
  @unchecked Sendable
{
  typealias Completion = @Sendable (Data?, HTTPURLResponse?) -> Void

  private let expectedURL: URL
  private let maximumByteCount: Int
  private let completion: Completion
  private var receivedData = Data()
  private var acceptedResponse: HTTPURLResponse?
  private var failed = false

  init(expectedURL: URL, maximumByteCount: Int, completion: @escaping Completion) {
    self.expectedURL = expectedURL
    self.maximumByteCount = maximumByteCount
    self.completion = completion
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    failed = true
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let response = response as? HTTPURLResponse,
      response.statusCode == 200,
      response.url == expectedURL,
      response.expectedContentLength <= Int64(maximumByteCount)
        || response.expectedContentLength == NSURLSessionTransferSizeUnknown
    else {
      failed = true
      completionHandler(.cancel)
      return
    }

    acceptedResponse = response
    if response.expectedContentLength > 0 {
      receivedData.reserveCapacity(Int(response.expectedContentLength))
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard !failed,
      data.count <= maximumByteCount - receivedData.count
    else {
      failed = true
      dataTask.cancel()
      return
    }
    receivedData.append(data)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    let data = !failed && error == nil ? receivedData : nil
    let response = !failed && error == nil ? acceptedResponse : nil
    session.finishTasksAndInvalidate()
    completion(data, response)
  }
}

/// Opt-in release check.
///
/// Design constraints, in order of importance:
///
/// - The app never downloads or installs an update. MetaShield is ad-hoc signed,
///   so a downloaded bundle cannot be tied to a developer identity and replacing
///   the installed app from the network would be an unverifiable code path.
/// - Every URL is compiled in. The response is only read for `tag_name`, and even
///   that is rejected unless it is a plain `major.minor.patch` string.
/// - The check is off until the user turns it on, runs at most once a day, and
///   never runs for headless Finder, Services, or Photos requests.
@MainActor
private enum UpdateChecker {
  enum Outcome: Sendable {
    case upToDate(current: ReleaseVersion)
    case updateAvailable(latest: ReleaseVersion)
    case failed
  }

  static let releasePageURL = URL(
    string: "https://github.com/assff1123/metashield/releases/latest")!

  nonisolated private static let feedURL = URL(
    string: "https://api.github.com/repos/assff1123/metashield/releases/latest")!
  private static let enabledKey = "kr.metashield.app.updateCheckEnabled"
  private static let lastCheckKey = "kr.metashield.app.lastUpdateCheck"
  private static let checkInterval: TimeInterval = 24 * 60 * 60
  nonisolated private static let maximumResponseByteCount = 512 * 1_024

  static var isEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: enabledKey) }
    set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
  }

  static var currentVersion: ReleaseVersion? {
    guard
      let string = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    else { return nil }
    return ReleaseVersion(tag: string)
  }

  /// Runs a check only if the user enabled it and a day has passed.
  @discardableResult
  static func checkIfDue(completion: @escaping @MainActor @Sendable (Outcome) -> Void) -> Bool {
    guard isEnabled else { return false }
    let now = Date()
    let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
    if let last, now.timeIntervalSince(last) < checkInterval, now >= last {
      return false
    }
    performCheck(completion: completion)
    return true
  }

  private static func performCheck(
    completion: @escaping @MainActor @Sendable (Outcome) -> Void
  ) {
    guard let current = currentVersion else {
      completion(.failed)
      return
    }
    UserDefaults.standard.set(Date(), forKey: lastCheckKey)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 20
    configuration.httpAdditionalHeaders = [
      "Accept": "application/vnd.github+json",
      "User-Agent": "MetaShield/\(current) (update check)",
    ]
    var request = URLRequest(url: feedURL)
    request.httpMethod = "GET"
    let delegate = BoundedUpdateSessionDelegate(
      expectedURL: feedURL,
      maximumByteCount: maximumResponseByteCount
    ) { data, response in
      let latest = parseLatestVersion(data: data, response: response)
      Task { @MainActor in
        guard let latest else {
          completion(.failed)
          return
        }
        completion(
          latest > current ? .updateAvailable(latest: latest) : .upToDate(current: current))
      }
    }
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    session.dataTask(with: request).resume()
  }

  nonisolated private static func parseLatestVersion(data: Data?, response: URLResponse?)
    -> ReleaseVersion?
  {
    guard let httpResponse = response as? HTTPURLResponse,
      httpResponse.statusCode == 200,
      httpResponse.url == feedURL,
      let data,
      data.count <= maximumResponseByteCount,
      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tag = payload["tag_name"] as? String
    else {
      return nil
    }
    return ReleaseVersion(tag: tag)
  }
}
