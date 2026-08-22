import AppKit
import Foundation
import MetaShieldCore
import Photos
import UniformTypeIdentifiers

@_silgen_name("NSExtensionMain")
private func metaShieldExtensionMain(
  _ argc: Int32,
  _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

private let shareProviderLoadTimeout: DispatchTimeInterval = .seconds(60)
private let photoPermissionSetupTimeout: DispatchTimeInterval = .seconds(60)
private let shareMaximumProviderByteCount = 128 * 1_024 * 1_024
private let shareMaximumItemCount = 20

private func shareCancellationError() -> NSError {
  NSError(
    domain: "kr.metashield.app.share",
    code: NSUserCancelledError,
    userInfo: [NSLocalizedDescriptionKey: "사용자가 취소했습니다."]
  )
}

private final class ShareCancellationState: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
}

private final class ProviderLoadResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var storedResult: Result<URL, Error>?

  func complete(_ result: Result<URL, Error>) {
    lock.lock()
    guard storedResult == nil else {
      lock.unlock()
      return
    }
    storedResult = result
    lock.unlock()
    semaphore.signal()
  }

  func wait(timeout: DispatchTime) throws -> URL {
    guard semaphore.wait(timeout: timeout) == .success else {
      throw MetaShieldError.fileOperationFailed("이미지 제공 앱이 60초 안에 데이터를 전달하지 않았습니다.")
    }
    lock.lock()
    let result = storedResult
    lock.unlock()
    return try (result ?? .failure(MetaShieldError.unsupportedOrCorruptImage)).get()
  }
}

private final class ItemProviderCollection: @unchecked Sendable {
  let providers: [NSItemProvider]

  init(_ providers: [NSItemProvider]) {
    self.providers = providers
  }
}

@objc(MetaShieldShareViewController)
final class MetaShieldShareViewController: NSViewController, @unchecked Sendable {
  private let titleLabel = NSTextField(labelWithString: "MetaShield로 완전 제거")
  private let detailLabel = NSTextField(
    wrappingLabelWithString: "선택한 이미지를 자동으로 정리해 사진 보관함에 새 사진으로 추가합니다.")
  private let statusLabel = NSTextField(wrappingLabelWithString: "이미지를 확인하는 중…")
  private let cancelButton = NSButton(title: "취소", target: nil, action: nil)
  private let spinner = NSProgressIndicator()
  nonisolated private let cancellationState = ShareCancellationState()
  private var providers: [NSItemProvider] = []
  private var isProcessing = false
  private var activePhotoPermissionSetupToken: UUID?
  private var setupMarkerLoadProgress: Progress?
  private var activePhotoImportToken: UUID?
  private var activePhotoImportDirectory: URL?

  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 260))

    titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
    titleLabel.alignment = .center
    detailLabel.font = .systemFont(ofSize: 13)
    detailLabel.textColor = .secondaryLabelColor
    detailLabel.alignment = .center
    detailLabel.maximumNumberOfLines = 3
    statusLabel.alignment = .center
    statusLabel.maximumNumberOfLines = 3
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.setAccessibilityLabel("처리 상태")

    cancelButton.target = self
    cancelButton.action = #selector(cancel)
    cancelButton.keyEquivalent = "\u{1b}"
    cancelButton.setAccessibilityHelp("처리를 취소하고 공유 창을 닫습니다.")

    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false

    let statusRow = NSStackView(views: [spinner, statusLabel])
    statusRow.orientation = .horizontal
    statusRow.alignment = .centerY
    statusRow.spacing = 8

    let buttonRow = NSStackView(views: [cancelButton])
    buttonRow.orientation = .horizontal
    buttonRow.alignment = .centerY
    buttonRow.spacing = 10

    let stack = NSStackView(views: [titleLabel, detailLabel, statusRow, buttonRow])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 18
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
      stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
      detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
      statusLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -30),
    ])
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    providers = imageProviders()
    if providers.count == 1,
      PhotoPermissionSetup.hasSetupType(
        registeredTypeIdentifiers: providers[0].registeredTypeIdentifiers)
    {
      validatePhotoPermissionSetupRequest(from: providers[0])
    } else if providers.isEmpty {
      showStatus("사진 앱에서 이미지 데이터를 받지 못했습니다.", color: .systemRed)
      cancelButton.title = "닫기"
    } else if providers.count > shareMaximumItemCount {
      showStatus("한 번에 최대 \(shareMaximumItemCount)개 이미지까지 처리할 수 있습니다.", color: .systemRed)
      cancelButton.title = "닫기"
    } else {
      showStatus("선택된 이미지 \(providers.count)개를 자동 처리합니다…")
      DispatchQueue.main.async { [weak self] in
        self?.processSelection()
      }
    }
  }

  private func validatePhotoPermissionSetupRequest(from provider: NSItemProvider) {
    guard !isProcessing else { return }
    isProcessing = true
    let token = UUID()
    activePhotoPermissionSetupToken = token
    titleLabel.stringValue = "사진 앱 권한 연결"
    detailLabel.stringValue =
      "사진 앱 공유 기능에 필요한 사진 추가 권한만 확인합니다. 설정 이미지는 보관함에 추가하지 않습니다."
    startSpinner()
    showStatus("권한 설정 요청을 확인하는 중…")

    DispatchQueue.main.asyncAfter(deadline: .now() + photoPermissionSetupTimeout) { [weak self] in
      guard let self, self.activePhotoPermissionSetupToken == token else { return }
      self.setupMarkerLoadProgress?.cancel()
      self.setupMarkerLoadProgress = nil
      self.activePhotoPermissionSetupToken = nil
      self.finishWithError(Self.photoLibraryError("권한 설정 요청이 60초 안에 응답하지 않았습니다."))
    }

    let registeredTypeIdentifiers = provider.registeredTypeIdentifiers
    setupMarkerLoadProgress = provider.loadDataRepresentation(
      forTypeIdentifier: PhotoPermissionSetup.typeIdentifier
    ) { [weak self] data, _ in
      Task { @MainActor in
        guard let self, self.activePhotoPermissionSetupToken == token,
          !self.cancellationState.isCancelled
        else { return }
        self.setupMarkerLoadProgress = nil
        if PhotoPermissionSetup.isSetupRequest(
          registeredTypeIdentifiers: registeredTypeIdentifiers,
          markerData: data
        ) {
          self.beginPhotoPermissionSetup(token: token)
        } else {
          self.activePhotoPermissionSetupToken = nil
          self.isProcessing = false
          self.titleLabel.stringValue = "MetaShield로 완전 제거"
          self.detailLabel.stringValue =
            "선택한 이미지를 자동으로 정리해 사진 보관함에 새 사진으로 추가합니다."
          self.processSelection()
        }
      }
    }
  }

  private func beginPhotoPermissionSetup(token: UUID) {
    guard activePhotoPermissionSetupToken == token, !cancellationState.isCancelled else { return }
    let authorizationToken = UUID()
    activePhotoPermissionSetupToken = authorizationToken
    showStatus("사진 추가 권한을 확인하는 중…")

    DispatchQueue.main.asyncAfter(deadline: .now() + photoPermissionSetupTimeout) { [weak self] in
      guard let self, self.activePhotoPermissionSetupToken == authorizationToken else { return }
      self.activePhotoPermissionSetupToken = nil
      self.finishWithError(Self.photoLibraryError("사진 권한 요청이 60초 안에 응답하지 않았습니다."))
    }

    switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
    case .authorized, .limited:
      finishPhotoPermissionSetup(token: authorizationToken)
    case .notDetermined:
      Self.requestPhotoAuthorization { [weak self] status in
        guard let self, self.activePhotoPermissionSetupToken == authorizationToken,
          !self.cancellationState.isCancelled
        else { return }
        if status == .authorized || status == .limited {
          self.finishPhotoPermissionSetup(token: authorizationToken)
        } else {
          self.activePhotoPermissionSetupToken = nil
          self.finishWithError(
            Self.photoLibraryError(
              "사진 추가 권한이 필요합니다. 시스템 설정의 개인정보 보호 및 보안 > 사진에서 허용하세요."))
        }
      }
    case .denied, .restricted:
      activePhotoPermissionSetupToken = nil
      finishWithError(
        Self.photoLibraryError(
          "사진 추가 권한이 꺼져 있습니다. 시스템 설정의 개인정보 보호 및 보안 > 사진에서 허용하세요."))
    @unknown default:
      activePhotoPermissionSetupToken = nil
      finishWithError(Self.photoLibraryError("알 수 없는 사진 보관함 권한 상태입니다."))
    }
  }

  private func finishPhotoPermissionSetup(token: UUID) {
    guard activePhotoPermissionSetupToken == token, !cancellationState.isCancelled else { return }
    activePhotoPermissionSetupToken = nil
    cancelButton.isEnabled = false
    spinner.stopAnimation(nil)
    showStatus("연결 완료: 설정 이미지는 사진 보관함에 추가되지 않았습니다.", color: .systemGreen)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      self?.extensionContext?.completeRequest(returningItems: nil)
    }
  }

  @objc private func processSelection() {
    guard !isProcessing, !providers.isEmpty else { return }
    isProcessing = true
    startSpinner()
    showStatus("원본 데이터를 받아 정리·검증하는 중…")

    let targetProviders = ItemProviderCollection(providers)
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      self.loadAndSave(targetProviders.providers)
    }
  }

  @objc private func cancel() {
    cancellationState.cancel()
    activePhotoPermissionSetupToken = nil
    setupMarkerLoadProgress?.cancel()
    setupMarkerLoadProgress = nil
    activePhotoImportToken = nil
    if let directory = activePhotoImportDirectory {
      try? FileManager.default.removeItem(at: directory)
      activePhotoImportDirectory = nil
    }
    cancelButton.isEnabled = false
    spinner.stopAnimation(nil)
    showStatus("취소 중…")
    let error = NSError(
      domain: "kr.metashield.app.share",
      code: NSUserCancelledError,
      userInfo: [NSLocalizedDescriptionKey: "사용자가 취소했습니다."]
    )
    extensionContext?.cancelRequest(withError: error)
  }

  private func imageProviders() -> [NSItemProvider] {
    guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return [] }
    return
      items
      .flatMap { $0.attachments ?? [] }
      .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
  }

  nonisolated private func loadAndSave(_ providers: [NSItemProvider]) {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MetaShieldShare-\(UUID().uuidString)", isDirectory: true)

    do {
      try FileManager.default.createDirectory(
        at: temporaryDirectory, withIntermediateDirectories: true)
      // Share extensions have a much smaller memory budget than the host app.
      // File-backed provider input plus an 8 MP cap avoids loading the source
      // and decoded image into memory at the same time.
      let sanitizer = ImageSanitizer(
        maximumPixelCount: 8_000_000,
        maximumInputByteCount: shareMaximumProviderByteCount
      )
      var saved: [URL] = []

      for (index, provider) in providers.enumerated() {
        try throwIfCancelled()
        let item = try loadImageFile(
          from: provider,
          fallbackIndex: index + 1,
          destinationDirectory: temporaryDirectory
        )
        let baseName = URL(fileURLWithPath: item.name).deletingPathExtension().lastPathComponent
        let destination = OutputNaming.uniqueCleanPNGURL(in: temporaryDirectory, baseName: baseName)
        let report = try sanitizer.writeCanonicalPNG(from: item.url, to: destination)
        try? FileManager.default.removeItem(at: item.url)
        try throwIfCancelled()
        saved.append(report.url)
      }
      try throwIfCancelled()
      let finalSaved = saved
      Task { @MainActor [self] in
        self.importIntoPhotos(finalSaved, temporaryDirectory: temporaryDirectory)
      }
    } catch {
      try? FileManager.default.removeItem(at: temporaryDirectory)
      if !cancellationState.isCancelled {
        let finalError = error
        Task { @MainActor [self] in
          self.finishWithError(finalError)
        }
      }
    }
  }

  nonisolated private func loadImageFile(
    from provider: NSItemProvider,
    fallbackIndex: Int,
    destinationDirectory: URL
  ) throws -> (name: String, url: URL) {
    let resultBox = ProviderLoadResultBox()
    let receivingURL =
      destinationDirectory
      .appendingPathComponent(".provider-\(UUID().uuidString).image")
    let cancellationState = self.cancellationState
    let progress = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) {
      url, error in
      guard !cancellationState.isCancelled else {
        resultBox.complete(.failure(shareCancellationError()))
        return
      }
      guard let url else {
        resultBox.complete(.failure(error ?? MetaShieldError.unsupportedOrCorruptImage))
        return
      }
      do {
        try self.copyProviderFileSecurely(from: url, to: receivingURL)
        guard !cancellationState.isCancelled else {
          try? FileManager.default.removeItem(at: receivingURL)
          throw shareCancellationError()
        }
        resultBox.complete(.success(receivingURL))
      } catch {
        resultBox.complete(.failure(error))
      }
    }
    do {
      let url = try resultBox.wait(timeout: .now() + shareProviderLoadTimeout)
      try throwIfCancelled()
      let suggested = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
      let name = suggested?.isEmpty == false ? suggested! : "Photo \(fallbackIndex)"
      return (name, url)
    } catch {
      progress.cancel()
      try? FileManager.default.removeItem(at: receivingURL)
      throw error
    }
  }

  nonisolated private func copyProviderFileSecurely(from source: URL, to destination: URL) throws {
    let input = source.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
    guard input >= 0 else {
      if errno == ELOOP { throw MetaShieldError.symbolicLinkNotAllowed }
      throw MetaShieldError.fileOperationFailed(String(cString: strerror(errno)))
    }
    defer { close(input) }

    var sourceState = stat()
    guard fstat(input, &sourceState) == 0 else {
      throw MetaShieldError.fileOperationFailed(String(cString: strerror(errno)))
    }
    guard sourceState.st_mode & S_IFMT == S_IFREG else {
      throw MetaShieldError.notARegularFile
    }
    guard sourceState.st_size >= 0,
      UInt64(sourceState.st_size) <= UInt64(shareMaximumProviderByteCount)
    else {
      let reportedSize = sourceState.st_size < 0 ? Int.max : Int(sourceState.st_size)
      throw MetaShieldError.inputFileTooLarge(
        byteCount: reportedSize,
        limit: shareMaximumProviderByteCount
      )
    }

    let output = destination.path.withCString {
      open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    }
    guard output >= 0 else {
      throw MetaShieldError.fileOperationFailed(String(cString: strerror(errno)))
    }
    defer { close(output) }

    var copied = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let readCount = buffer.withUnsafeMutableBytes { rawBuffer in
        read(input, rawBuffer.baseAddress, rawBuffer.count)
      }
      if readCount == 0 { break }
      if readCount < 0 {
        if errno == EINTR { continue }
        throw MetaShieldError.fileOperationFailed(String(cString: strerror(errno)))
      }
      guard copied <= shareMaximumProviderByteCount - readCount else {
        throw MetaShieldError.inputFileTooLarge(
          byteCount: copied + readCount,
          limit: shareMaximumProviderByteCount
        )
      }

      var offset = 0
      while offset < readCount {
        let writeCount = buffer.withUnsafeBytes { rawBuffer in
          write(output, rawBuffer.baseAddress?.advanced(by: offset), readCount - offset)
        }
        if writeCount < 0 {
          if errno == EINTR { continue }
          throw MetaShieldError.fileOperationFailed(String(cString: strerror(errno)))
        }
        guard writeCount > 0 else {
          throw MetaShieldError.fileOperationFailed("이미지 제공 파일을 복사하지 못했습니다.")
        }
        offset += writeCount
      }
      copied += readCount
    }
    guard copied == Int(sourceState.st_size) else {
      throw MetaShieldError.sourceChangedDuringProcessing
    }
    guard fsync(output) == 0 else {
      throw MetaShieldError.fileOperationFailed(String(cString: strerror(errno)))
    }
  }

  private func importIntoPhotos(_ urls: [URL], temporaryDirectory: URL) {
    guard !cancellationState.isCancelled else {
      try? FileManager.default.removeItem(at: temporaryDirectory)
      return
    }

    let token = UUID()
    activePhotoImportToken = token
    activePhotoImportDirectory = temporaryDirectory
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
      guard let self, self.activePhotoImportToken == token else { return }
      self.completePhotoImport(
        token: token,
        temporaryDirectory: temporaryDirectory,
        result: .failure(Self.photoLibraryError("사진 보관함이 60초 안에 응답하지 않았습니다.")),
        count: urls.count
      )
    }

    switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
    case .authorized, .limited:
      performPhotoImport(urls, token: token, temporaryDirectory: temporaryDirectory)
    case .notDetermined:
      Self.requestPhotoAuthorization { [weak self] status in
        guard let self, self.activePhotoImportToken == token,
          !self.cancellationState.isCancelled
        else { return }
        guard status == .authorized || status == .limited else {
          self.completePhotoImport(
            token: token,
            temporaryDirectory: temporaryDirectory,
            result: .failure(Self.photoLibraryError("사진 추가 권한이 필요합니다.")),
            count: urls.count
          )
          return
        }
        self.performPhotoImport(urls, token: token, temporaryDirectory: temporaryDirectory)
      }
    case .denied, .restricted:
      completePhotoImport(
        token: token,
        temporaryDirectory: temporaryDirectory,
        result: .failure(Self.photoLibraryError("사진 추가 권한이 필요합니다.")),
        count: urls.count
      )
    @unknown default:
      completePhotoImport(
        token: token,
        temporaryDirectory: temporaryDirectory,
        result: .failure(Self.photoLibraryError("알 수 없는 사진 보관함 권한 상태입니다.")),
        count: urls.count
      )
    }
  }

  private func performPhotoImport(_ urls: [URL], token: UUID, temporaryDirectory: URL) {
    guard activePhotoImportToken == token, !cancellationState.isCancelled else { return }
    // From here Photos owns the transaction and it cannot be safely cancelled.
    // Prevent a misleading cancel click during commit.
    cancelButton.isEnabled = false
    showStatus("정리된 이미지를 사진 보관함에 추가하는 중…")
    Self.performPhotoLibraryChanges(urls) { [weak self] success, error in
      guard let self, self.activePhotoImportToken == token else { return }
      let result: Result<Void, Error>
      if success {
        result = .success(())
      } else {
        result = .failure(
          error ?? Self.photoLibraryError("정리된 이미지를 사진 보관함에 추가하지 못했습니다."))
      }
      self.completePhotoImport(
        token: token,
        temporaryDirectory: temporaryDirectory,
        result: result,
        count: urls.count
      )
    }
  }

  /// PhotoKit completes on private queues. Keep those system callbacks
  /// nonisolated and enter MainActor only before accessing extension UI/state.
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
    } completionHandler: { success, error in
      Task { @MainActor in
        completion(success, error)
      }
    }
  }

  private func completePhotoImport(
    token: UUID,
    temporaryDirectory: URL,
    result: Result<Void, Error>,
    count: Int
  ) {
    guard activePhotoImportToken == token else { return }
    activePhotoImportToken = nil
    activePhotoImportDirectory = nil
    try? FileManager.default.removeItem(at: temporaryDirectory)
    guard !cancellationState.isCancelled else { return }
    switch result {
    case .success:
      finishSuccessfully(count: count)
    case .failure(let error):
      finishWithError(error)
    }
  }

  private static func photoLibraryError(_ message: String) -> NSError {
    NSError(
      domain: "kr.metashield.app.share",
      code: 2,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }

  nonisolated private func throwIfCancelled() throws {
    if cancellationState.isCancelled {
      throw shareCancellationError()
    }
  }

  private func finishSuccessfully(count: Int) {
    spinner.stopAnimation(nil)
    showStatus("완료: 사진 보관함에 새 이미지 \(count)개 추가됨", color: .systemGreen)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
      self?.extensionContext?.completeRequest(returningItems: nil)
    }
  }

  private func finishWithError(_ error: Error) {
    activePhotoPermissionSetupToken = nil
    setupMarkerLoadProgress?.cancel()
    setupMarkerLoadProgress = nil
    isProcessing = false
    spinner.stopAnimation(nil)
    showStatus("실패: \(error.localizedDescription)", color: .systemRed)
    cancelButton.title = "닫기"
    cancelButton.isEnabled = true
  }

  private func showStatus(_ text: String, color: NSColor = .secondaryLabelColor) {
    statusLabel.stringValue = text
    statusLabel.textColor = color
    NSAccessibility.post(element: statusLabel, notification: .valueChanged)
    // `.valueChanged` is only spoken when the VoiceOver cursor already sits on
    // the label; an announcement reaches the user wherever the cursor is.
    NSAccessibility.post(
      element: view.window ?? NSApp as Any,
      notification: .announcementRequested,
      userInfo: [
        .announcement: text,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ]
    )
  }

  /// The status text already reports progress; the spinner is animated
  /// decoration, so Reduce Motion leaves it hidden.
  private func startSpinner() {
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      spinner.startAnimation(nil)
    }
  }
}

exit(metaShieldExtensionMain(CommandLine.argc, CommandLine.unsafeArgv))
