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
      "PNG는 검증 후 원본을 영구 교체합니다. 다른 형식은 정리된 PNG를 만든 뒤 원본을 휴지통으로 "
      + "옮깁니다. 투명도는 흰색으로 합성합니다. Finder 우클릭의 AVIF 변환은 원본을 그대로 둡니다.")
  private let dropZone = DropZoneView()
  private let statusLabel = NSTextField(wrappingLabelWithString: "이미지를 이곳에 놓거나 아래 버튼으로 선택하세요.")
  private let chooseButton = NSButton(title: "이미지 선택…", target: nil, action: nil)
  private let photoPermissionButton = NSButton(
    title: "사진 권한 미리 연결… (선택)", target: nil, action: nil)
  private let spinner = NSProgressIndicator()
  private let updateToggle = NSButton(
    checkboxWithTitle: "새 버전 확인 (GitHub)", target: nil, action: nil)
  private let notifyToggle = NSButton(
    checkboxWithTitle: "백그라운드 처리 완료 알림", target: nil, action: nil)
  private let updateStatusLabel = NSTextField(labelWithString: "")
  private let downloadUpdateButton = NSButton(
    title: "검증된 DMG 받기…", target: nil, action: nil)
  private let openReleaseButton = NSButton(title: "릴리스 페이지", target: nil, action: nil)
  private let serviceSettingsButton = NSButton(
    title: "Finder 메뉴 설정 열기…", target: nil, action: nil)
  private let qualityLabel = NSTextField(labelWithString: "")
  private let qualitySlider = NSSlider()
  private var pendingUpdate: ReleaseVersion?
  private var downloadedUpdate: URL?
  private var isProcessing = false
  private var isSilentProcessing = false
  private var processingCompletion: ((Bool) -> Void)?
  private var temporaryInputDirectories: [URL] = []
  private var activePhotoImportToken: UUID?
  /// Set once PhotoKit owns the transaction, after which no timer may declare
  /// failure: the import can still succeed and reporting otherwise invites a
  /// duplicate.
  private var hasStartedPhotoCommit = false
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
      "선택 사항: 사진 앱 공유 확장의 사진 추가 권한을 미리 허용해 둡니다. 연결하지 않아도 "
        + "사진 앱에서 처음 공유할 때 같은 권한 창이 나타납니다. 시스템 공유 창에서 MetaShield를 선택하세요.")

    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false

    updateToggle.target = self
    updateToggle.action = #selector(toggleUpdateCheck)
    updateToggle.state = UpdateChecker.isEnabled ? .on : .off
    updateToggle.setAccessibilityHelp(
      "켜면 하루에 한 번 GitHub 릴리스에서 새 버전 번호만 확인합니다. 앱이 직접 내려받거나 설치하지 않습니다.")

    notifyToggle.target = self
    notifyToggle.action = #selector(toggleBackgroundNotifications)
    notifyToggle.state = BackgroundResultNotifier.isEnabled ? .on : .off
    notifyToggle.setAccessibilityHelp(
      "켜면 Finder 우클릭·Dock 드래그처럼 창 없이 처리한 결과를 macOS 알림으로 알려줍니다. "
        + "알림 권한이 필요합니다.")

    updateStatusLabel.font = .preferredFont(forTextStyle: .callout)
    updateStatusLabel.textColor = .secondaryLabelColor
    updateStatusLabel.alignment = .center
    updateStatusLabel.setAccessibilityLabel("업데이트 확인 상태")
    // "새 버전이 나왔습니다" reads like something to click, so make it one. The
    // address is the compiled-in release page, the same one the button opens;
    // nothing from the network can redirect it.
    updateStatusLabel.addGestureRecognizer(
      NSClickGestureRecognizer(target: self, action: #selector(openReleasePage)))

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

    serviceSettingsButton.target = self
    serviceSettingsButton.action = #selector(openServiceSettings)
    serviceSettingsButton.bezelStyle = .rounded
    serviceSettingsButton.setAccessibilityHelp(
      "시스템 설정의 서비스 목록을 엽니다. 거기서 MetaShield의 Finder 우클릭 메뉴를 항목별로 "
        + "켜고 끌 수 있습니다. AVIF 메뉴는 처음에 꺼져 있습니다.")

    // The compression level for the "AVIF로 변환 및 압축" command. It changes how
    // small the new file is; it never changes whether a file is replaced.
    qualitySlider.target = self
    qualitySlider.action = #selector(changeAVIFQuality)
    qualitySlider.minValue = AVIFQuality.minimumCompressionValue
    qualitySlider.maxValue = AVIFQuality.maximumCompressionValue
    qualitySlider.doubleValue = AVIFSettings.compressionQuality
    qualitySlider.isContinuous = true
    qualitySlider.setAccessibilityLabel("AVIF 압축 품질")
    qualitySlider.setAccessibilityHelp(
      "Finder 우클릭의 'AVIF로 변환 및 압축'이 사용할 품질입니다. 낮출수록 파일이 작아지고 화질이 떨어집니다. "
        + "원본은 어느 경우에도 교체되지 않습니다.")
    qualityLabel.font = .preferredFont(forTextStyle: .callout)
    qualityLabel.textColor = .secondaryLabelColor
    updateQualityLabel()

    dropZone.onFileURLs = { [weak self] urls in
      self?.receiveFileURLs(urls)
    }
    dropZone.onImageData = { [weak self] data in
      self?.receiveImageData(data, suggestedName: "Dropped Image.png")
    }
    dropZone.onFilePromises = { [weak self] promises in
      self?.receiveFilePromises(promises)
    }
    dropZone.onActivate = { [weak self] in
      self?.chooseImages()
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

    let qualityRow = NSStackView(views: [qualityLabel, qualitySlider, serviceSettingsButton])
    qualityRow.orientation = .horizontal
    qualityRow.spacing = 10
    qualityRow.alignment = .centerY

    let stack = NSStackView(views: [
      titleLabel, subtitleLabel, dropZone, statusRow, actionRow, qualityRow, notifyToggle,
      updateRow, updateStatusLabel,
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
      qualityRow.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
      qualitySlider.widthAnchor.constraint(equalToConstant: 190),
      notifyToggle.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
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

  @objc private func openServiceSettings() {
    ServiceMenuSetup.openSystemServicesSettings()
    showStatus(
      "시스템 설정의 서비스 목록에서 MetaShield 항목을 켜고 끌 수 있습니다.", isError: false)
  }

  @objc private func changeAVIFQuality() {
    AVIFSettings.compressionQuality = qualitySlider.doubleValue
    updateQualityLabel()
  }

  private func updateQualityLabel() {
    let percent = Int((AVIFSettings.compressionQuality * 100).rounded())
    qualityLabel.stringValue = "AVIF 압축 품질 \(percent)%"
    NSAccessibility.post(element: qualityLabel, notification: .valueChanged)
  }

  @objc private func toggleBackgroundNotifications() {
    let isEnabled = notifyToggle.state == .on
    BackgroundResultNotifier.isEnabled = isEnabled
    // Only this interactive toggle may raise the notification permission
    // prompt. Headless runs check the granted state and never prompt.
    if isEnabled {
      UpdateChecker.requestNotificationAuthorization()
    }
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
      self?.updateStatusLabel.textColor = .secondaryLabelColor
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
      self.announce(self.updateStatusLabel.stringValue)
    }
  }

  /// Makes the status line look and behave like the link it now is, and stops
  /// it pretending to be one when there is nowhere useful to go.
  private func setUpdateStatus(_ text: String, color: NSColor, actionable: Bool) {
    if actionable {
      updateStatusLabel.attributedStringValue = NSAttributedString(
        string: text,
        attributes: [
          .foregroundColor: color,
          .font: NSFont.preferredFont(forTextStyle: .callout),
          .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
      )
      updateStatusLabel.setAccessibilityHelp("눌러서 릴리스 페이지를 엽니다.")
    } else {
      updateStatusLabel.stringValue = text
      updateStatusLabel.textColor = color
      updateStatusLabel.setAccessibilityHelp(nil)
    }
    updateStatusLabel.isEnabled = true
    NSAccessibility.post(element: updateStatusLabel, notification: .valueChanged)
    announce(text)
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
      setUpdateStatus(
        "새 버전 \(latest)이(가) 나왔습니다. 릴리스 페이지 열기",
        color: .controlAccentColor,
        actionable: true)
      pendingUpdate = latest
      downloadedUpdate = nil
      downloadUpdateButton.title = "검증된 DMG 받기…"
      downloadUpdateButton.isHidden = false
      openReleaseButton.isHidden = false
    case .upToDate(let current):
      setUpdateStatus("최신 버전입니다 (\(current)).", color: .secondaryLabelColor, actionable: false)
      pendingUpdate = nil
      downloadUpdateButton.isHidden = true
      openReleaseButton.isHidden = true
    case .regressionSuspected(let highestSeen, let reported):
      // Never offer a download here. This is what hiding a security fix would
      // look like from the app's side, so say so and let the user check.
      setUpdateStatus(
        "주의: 이전에 \(highestSeen) 버전을 확인했는데 지금은 \(reported)이(가) 최신이라고 합니다. "
          + "눌러서 릴리스 페이지에서 직접 확인하세요.",
        color: .systemRed,
        actionable: true)
      pendingUpdate = nil
      downloadUpdateButton.isHidden = true
      openReleaseButton.isHidden = false
    case .failed:
      setUpdateStatus("새 버전을 확인하지 못했습니다.", color: .secondaryLabelColor, actionable: false)
      downloadUpdateButton.isHidden = true
      openReleaseButton.isHidden = true
    }
  }

  func receiveFileURLs(
    _ urls: [URL],
    operation: SanitizeOperation = .scrubInPlace,
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
        try FileManager.default.createDirectory(
          at: directory,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700]
        )
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
    beginProcessing(operation)
    let importDirectory = managedOutputDirectory
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      var successes: [URL] = []
      var failures: [ProcessingFailure] = []
      var photosOutputs: [URL] = []
      let sanitizer = SanitizerFactory.makeSanitizer()

      if case .convertToAVIF(let quality, _) = operation {
        // Conversion never replaces a source: every input becomes a new file.
        for url in pngFiles + copyFiles {
          do {
            let destinationDirectory = try Self.automaticOutputDirectory(for: url)
            let destination = OutputNaming.uniqueCleanAVIFURL(
              in: destinationDirectory,
              baseName: url.deletingPathExtension().lastPathComponent
            )
            let report = try sanitizer.writeCanonicalAVIF(
              from: url, to: destination, quality: quality)
            successes.append(report.url)
            if let failure = Self.retireOriginalIfRequested(
              operation, source: url, sanitizedCopy: report.url)
            {
              failures.append(failure)
            }
          } catch {
            failures.append(ProcessingFailure(url: url, error: error))
          }
        }
      } else {
        for url in pngFiles {
          do {
            let report = try sanitizer.sanitizePNGInPlace(at: url)
            successes.append(report.url)
          } catch MetaShieldError.inPlaceReplacementUnavailable {
            // Replacing this original could not be made crash-safe. Leave it
            // alone and write a verified copy instead of weakening the promise.
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
            if let failure = Self.retireOriginalIfRequested(
              operation, source: url, sanitizedCopy: report.url)
            {
              failures.append(failure)
            }
          } catch {
            failures.append(ProcessingFailure(url: url, error: error))
          }
        }
      }

      if let importDirectory {
        for url in managedFiles {
          do {
            let baseName = url.deletingPathExtension().lastPathComponent
            let report: SanitizationReport
            if case .convertToAVIF(let quality, _) = operation {
              report = try sanitizer.writeCanonicalAVIF(
                from: url,
                to: OutputNaming.uniqueCleanAVIFURL(in: importDirectory, baseName: baseName),
                quality: quality)
            } else {
              report = try sanitizer.writeCanonicalPNG(
                from: url,
                to: OutputNaming.uniqueCleanPNGURL(in: importDirectory, baseName: baseName))
            }
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
    operation: SanitizeOperation = .scrubInPlace,
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
      destination =
        operation.isConversion
        ? OutputNaming.uniqueCleanAVIFURL(in: directory, baseName: baseName)
        : OutputNaming.uniqueCleanPNGURL(in: directory, baseName: baseName)
    } catch {
      reportImmediateFailure(
        "자동 저장 폴더를 준비하지 못했습니다: \(error.localizedDescription)", silently: silently)
      completion?(false)
      return
    }

    isSilentProcessing = silently
    processingCompletion = completion
    beginProcessing(operation)
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      do {
        let sanitizer = SanitizerFactory.makeSanitizer()
        let report: SanitizationReport
        if case .convertToAVIF(let quality, _) = operation {
          report = try sanitizer.writeCanonicalAVIF(
            from: data, to: destination, quality: quality)
        } else {
          report = try sanitizer.writeCanonicalPNG(from: data, to: destination)
        }
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

    // The permission prompt can sit unanswered indefinitely, so that phase is
    // bounded. The import itself is not: once `performChanges` has started,
    // PhotoKit cannot be cancelled, and declaring failure early would report a
    // failure for a photo that still lands — leading the user to retry and
    // create a duplicate. The commit therefore waits for its real callback.
    if authorizationStatus == .notDetermined {
      DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
        guard let self, self.activePhotoImportToken == token, !self.hasStartedPhotoCommit else {
          return
        }
        let error = NSError(
          domain: "kr.metashield.app.photos",
          code: 3,
          userInfo: [NSLocalizedDescriptionKey: "사진 권한 요청이 60초 안에 응답하지 않았습니다."]
        )
        self.completePhotoImport(
          token: token,
          restoreAccessoryPolicy: needsVisiblePermissionPrompt,
          successes: successes,
          failures: failures + [ProcessingFailure(url: sourceForError, error: error)]
        )
      }
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
    hasStartedPhotoCommit = true
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
    hasStartedPhotoCommit = false
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
      // Images in flight pass through here, so do not rely on the enclosing
      // temporary directory's permissions to keep them private.
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      showStatus("드래그한 이미지를 받을 임시 폴더를 만들지 못했습니다.", isError: true)
      return
    }

    temporaryInputDirectories.append(directory)
    beginProcessing()
    showStatus("사진 앱에서 원본 데이터를 받는 중…", isError: false)
    let queue = OperationQueue()
    queue.qualityOfService = .userInitiated
    // A provider can materialize a full-resolution original per operation.
    // Receiving serially bounds the batch's live memory and disk-write burst
    // without changing which promised files are accepted.
    queue.maxConcurrentOperationCount = 1
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
    coordinator.startResourceMonitor {
      queue.cancelAllOperations()
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

  private func beginProcessing(_ operation: SanitizeOperation = .scrubInPlace) {
    isProcessing = true
    chooseButton.isEnabled = false
    photoPermissionButton.isEnabled = false
    dropZone.isEnabled = false
    // The status text already says work is in progress; the spinner is purely
    // animated decoration, so Reduce Motion simply leaves it hidden.
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      spinner.startAnimation(nil)
    }
    showStatus(operation.progressDescription, isError: false)
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

    if wasSilent {
      // The notification body can surface on the lock screen, in Notification
      // Center history, and in screen shares. Carry only the failure reason —
      // file names stay in the in-window status, where the user is present.
      let previous = pendingSilentResult
      pendingSilentResult = SilentRunResult(
        successCount: (previous?.successCount ?? 0) + successes.count,
        failureCount: (previous?.failureCount ?? 0) + failures.count,
        firstFailureDescription: previous?.firstFailureDescription
          ?? failures.first.map(\.error.localizedDescription)
      )
    }
    completion?(failures.isEmpty)
  }

  struct SilentRunResult {
    let successCount: Int
    let failureCount: Int
    let firstFailureDescription: String?
  }

  private var pendingSilentResult: SilentRunResult?

  /// Read once by the delegate when a headless batch finishes, so the optional
  /// background notification can summarize every request in the batch.
  func consumePendingSilentResult() -> SilentRunResult? {
    defer { pendingSilentResult = nil }
    return pendingSilentResult
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
    announce(text)
  }

  /// `.valueChanged` is only spoken when the VoiceOver cursor already sits on
  /// the label. An announcement is spoken wherever the cursor is, which is what
  /// a user waiting on a drop actually needs to hear.
  private func announce(_ text: String) {
    NSAccessibility.post(
      element: view.window ?? NSApp as Any,
      notification: .announcementRequested,
      userInfo: [
        .announcement: text,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ]
    )
  }

  private func reportImmediateFailure(_ message: String, silently: Bool) {
    showStatus(message, isError: true)
    if !silently {
      NSSound.beep()
    }
  }

  /// Retires a source whose verified copy has been written, when the command
  /// the user picked asks for that. Failing to retire it is not a failed
  /// sanitization — the clean copy exists either way — but the user is told,
  /// because they would otherwise believe the original is gone.
  nonisolated private static func retireOriginalIfRequested(
    _ operation: SanitizeOperation,
    source: URL,
    sanitizedCopy: URL
  ) -> ProcessingFailure? {
    guard operation.retiresOriginal,
      case .moveToTrash = OriginalDisposal.decide(source: source, sanitizedCopy: sanitizedCopy)
    else { return nil }
    do {
      try FileManager.default.trashItem(at: source, resultingItemURL: nil)
      return nil
    } catch {
      return ProcessingFailure(
        url: source,
        error: MetaShieldError.fileOperationFailed(
          "정리본은 만들었지만 원본을 휴지통으로 옮기지 못했습니다: " + error.localizedDescription))
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
