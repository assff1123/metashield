import AppKit
import MetaShieldCore
import Photos
import UniformTypeIdentifiers

private struct ProcessingFailure: @unchecked Sendable {
  let url: URL
  let error: Error
}

final class MainViewController: NSViewController, NSSharingServiceDelegate,
  @preconcurrency NSSharingServicePickerDelegate, @unchecked Sendable
{
  private let titleLabel = NSTextField(labelWithString: "이미지의 숨은 정보를 남김없이 비웁니다")
  private let subtitleLabel = NSTextField(
    wrappingLabelWithString:
      "PNG는 검증 후 원본을 영구 교체하며 투명도는 흰색으로 합성합니다. 다른 형식과 사진 앱·브라우저 이미지는 깨끗한 RGB PNG 사본으로 저장합니다.")
  private let dropZone = DropZoneView()
  private let statusLabel = NSTextField(wrappingLabelWithString: "이미지를 이곳에 놓거나 아래 버튼으로 선택하세요.")
  private let chooseButton = NSButton(title: "이미지 선택…", target: nil, action: nil)
  private let photoPermissionButton = NSButton(
    title: "사진 앱 권한 연결…", target: nil, action: nil)
  private let spinner = NSProgressIndicator()
  private let updateToggle = NSButton(
    checkboxWithTitle: "새 버전 확인 (GitHub)", target: nil, action: nil)
  private let updateStatusLabel = NSTextField(labelWithString: "")
  private let downloadUpdateButton = NSButton(
    title: "검증된 DMG 받기…", target: nil, action: nil)
  private let openReleaseButton = NSButton(title: "릴리스 페이지", target: nil, action: nil)
  private var pendingUpdate: ReleaseVersion?
  private var downloadedUpdate: URL?
  private var isProcessing = false
  private var isSilentProcessing = false
  private var processingCompletion: ((Bool) -> Void)?
  private var temporaryInputDirectories: [URL] = []
  private var activePhotoImportToken: UUID?
  private var photoPermissionPicker: NSSharingServicePicker?
  private var photoPermissionProvider: NSItemProvider?

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

    photoPermissionButton.target = self
    photoPermissionButton.action = #selector(connectPhotosPermission)
    photoPermissionButton.bezelStyle = .rounded
    photoPermissionButton.controlSize = .large
    photoPermissionButton.setAccessibilityHelp(
      "사진 앱 공유 확장의 사진 추가 권한을 한 번 설정합니다. 시스템 공유 창에서 MetaShield를 선택하세요.")

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

    downloadUpdateButton.target = self
    downloadUpdateButton.action = #selector(downloadVerifiedUpdate)
    downloadUpdateButton.bezelStyle = .rounded
    downloadUpdateButton.isHidden = true
    downloadUpdateButton.setAccessibilityHelp(
      "서명과 체크섬을 검증한 새 버전 DMG를 다운로드 폴더에 저장합니다. 설치는 직접 하셔야 합니다.")

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

    let updateRow = NSStackView(views: [updateToggle, downloadUpdateButton, openReleaseButton])
    updateRow.orientation = .horizontal
    updateRow.spacing = 10
    updateRow.alignment = .centerY

    let actionRow = NSStackView(views: [chooseButton, photoPermissionButton])
    actionRow.orientation = .horizontal
    actionRow.spacing = 10
    actionRow.alignment = .centerY

    let stack = NSStackView(views: [
      titleLabel, subtitleLabel, dropZone, statusRow, actionRow, updateRow, updateStatusLabel,
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
      actionRow.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
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

  @objc private func connectPhotosPermission() {
    guard !isProcessing, photoPermissionPicker == nil else { return }

    let provider = NSItemProvider()
    provider.suggestedName = PhotoPermissionSetup.suggestedFileName
    provider.registerDataRepresentation(
      forTypeIdentifier: UTType.png.identifier,
      visibility: .all
    ) { completion in
      completion(PhotoPermissionSetup.previewPNGData, nil)
      return nil
    }
    provider.registerDataRepresentation(
      forTypeIdentifier: PhotoPermissionSetup.typeIdentifier,
      visibility: .all
    ) { completion in
      completion(PhotoPermissionSetup.markerData, nil)
      return nil
    }

    let picker = NSSharingServicePicker(items: [provider])
    picker.delegate = self
    photoPermissionProvider = provider
    photoPermissionPicker = picker
    showStatus("공유 창에서 MetaShield를 선택해 사진 앱 권한을 연결하세요.", isError: false)
    NSUpdateDynamicServices()
    picker.show(
      relativeTo: photoPermissionButton.bounds,
      of: photoPermissionButton,
      preferredEdge: .maxY
    )
  }

  func sharingServicePicker(
    _ sharingServicePicker: NSSharingServicePicker,
    sharingServicesForItems items: [Any],
    proposedSharingServices proposedServices: [NSSharingService]
  ) -> [NSSharingService] {
    let matchingServices = proposedServices.filter { $0.title == "MetaShield" }
    guard let service = matchingServices.first else { return [] }
    return [service]
  }

  func sharingServicePicker(
    _ sharingServicePicker: NSSharingServicePicker,
    delegateFor sharingService: NSSharingService
  ) -> (any NSSharingServiceDelegate)? {
    self
  }

  func sharingServicePicker(
    _ sharingServicePicker: NSSharingServicePicker,
    didChoose sharingService: NSSharingService?
  ) {
    guard sharingService == nil else { return }
    clearPhotoPermissionPicker()
    showStatus("사진 앱 권한 연결을 취소했습니다.", isError: false)
  }

  func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
    clearPhotoPermissionPicker()
    showStatus(
      "사진 앱 권한 연결 완료. 이제 사진 앱의 공유 메뉴에서 MetaShield를 바로 사용할 수 있습니다.",
      isError: false
    )
  }

  func sharingService(
    _ sharingService: NSSharingService,
    didFailToShareItems items: [Any],
    error: Error
  ) {
    clearPhotoPermissionPicker()
    showStatus("사진 앱 권한을 연결하지 못했습니다: \(error.localizedDescription)", isError: true)
  }

  private func clearPhotoPermissionPicker() {
    photoPermissionPicker = nil
    photoPermissionProvider = nil
  }

  @objc private func toggleUpdateCheck() {
    let isEnabled = updateToggle.state == .on
    UpdateChecker.isEnabled = isEnabled
    guard isEnabled else {
      updateStatusLabel.stringValue = ""
      downloadUpdateButton.isHidden = true
      openReleaseButton.isHidden = true
      pendingUpdate = nil
      return
    }
    // Only the interactive window may ask for notification permission.
    UpdateChecker.requestNotificationAuthorization()
    updateStatusLabel.stringValue = "새 버전을 확인하는 중…"
    // A check the user asked for is not rate limited. Only automatic ones are.
    UpdateChecker.checkNow { [weak self] outcome in
      self?.presentUpdateOutcome(outcome)
    }
  }

  @objc private func downloadVerifiedUpdate() {
    if let downloadedUpdate {
      NSWorkspace.shared.activateFileViewerSelecting([downloadedUpdate])
      return
    }
    guard let version = pendingUpdate else { return }
    downloadUpdateButton.isEnabled = false
    UpdateChecker.downloadVerifiedUpdate(version: version) { [weak self] message in
      self?.updateStatusLabel.stringValue = message
      self?.updateStatusLabel.textColor = .tertiaryLabelColor
    } completion: { [weak self] result in
      guard let self else { return }
      self.downloadUpdateButton.isEnabled = true
      switch result {
      case .success(let url):
        self.downloadedUpdate = url
        self.downloadUpdateButton.title = "Finder에서 보기"
        self.updateStatusLabel.stringValue =
          "서명·체크섬 검증 완료. 다운로드 폴더에 저장했습니다. 설치는 직접 하세요."
        self.updateStatusLabel.textColor = .systemGreen
      case .failure(let error):
        self.updateStatusLabel.stringValue = error.localizedDescription
        self.updateStatusLabel.textColor = .systemRed
      }
      NSAccessibility.post(element: self.updateStatusLabel, notification: .valueChanged)
    }
  }

  @objc private func openReleasePage() {
    // The release page is compiled in. Nothing from the network can change it.
    NSWorkspace.shared.open(UpdateChecker.releasePageURL)
  }

  func checkForUpdatesNow() {
    guard UpdateChecker.isEnabled else { return }
    updateStatusLabel.stringValue = "새 버전을 확인하는 중…"
    UpdateChecker.checkNow { [weak self] outcome in
      self?.presentUpdateOutcome(outcome)
    }
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
    guard downloadedUpdate == nil else { return }
    switch outcome {
    case .updateAvailable(let latest):
      updateStatusLabel.stringValue = "새 버전 \(latest)이(가) 나왔습니다."
      updateStatusLabel.textColor = .controlAccentColor
      pendingUpdate = latest
      downloadedUpdate = nil
      downloadUpdateButton.title = "검증된 DMG 받기…"
      downloadUpdateButton.isHidden = false
      openReleaseButton.isHidden = false
    case .upToDate(let current):
      updateStatusLabel.stringValue = "최신 버전입니다 (\(current))."
      updateStatusLabel.textColor = .tertiaryLabelColor
      pendingUpdate = nil
      downloadUpdateButton.isHidden = true
      openReleaseButton.isHidden = true
    case .failed:
      updateStatusLabel.stringValue = "새 버전을 확인하지 못했습니다."
      updateStatusLabel.textColor = .tertiaryLabelColor
      downloadUpdateButton.isHidden = true
      openReleaseButton.isHidden = true
    }
    NSAccessibility.post(element: updateStatusLabel, notification: .valueChanged)
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
          let destination = OutputNaming.uniqueCleanPNGURL(
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
            let destination = OutputNaming.uniqueCleanPNGURL(
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
      destination = OutputNaming.uniqueCleanPNGURL(in: directory, baseName: baseName)
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
    Self.requestPhotoAuthorization { [weak self] status in
      guard let self, self.activePhotoImportToken == token else { return }
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

  private func performPhotoImport(
    _ urls: [URL],
    token: UUID,
    restoreAccessoryPolicy: Bool,
    successes: [URL],
    failures: [ProcessingFailure],
    sourceForError: URL
  ) {
    Self.performPhotoLibraryChanges(urls) { [weak self] imported, error in
      guard let self, self.activePhotoImportToken == token else { return }
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

  /// Photos invokes both completion handlers on private queues. Construct the
  /// system-facing closures outside MainActor isolation, then hop explicitly
  /// before touching UI or controller state. This avoids Swift 6's runtime
  /// executor precondition trapping on `com.apple.PHPhotoLibrary.changes`.
  nonisolated private static func requestPhotoAuthorization(
    completion: @escaping @MainActor @Sendable (PHAuthorizationStatus) -> Void
  ) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      Task { @MainActor in
        completion(status)
      }
    }
  }

  nonisolated private static func performPhotoLibraryChanges(
    _ urls: [URL],
    completion: @escaping @MainActor @Sendable (Bool, Error?) -> Void
  ) {
    PHPhotoLibrary.shared().performChanges {
      for url in urls {
        PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
      }
    } completionHandler: { imported, error in
      Task { @MainActor in
        completion(imported, error)
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
    photoPermissionButton.isEnabled = false
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
    photoPermissionButton.isEnabled = true
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
