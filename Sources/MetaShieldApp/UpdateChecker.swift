import Foundation
import MetaShieldCore
import UserNotifications

/// Runs a completion exactly once, whichever of the network result or the
/// background deadline arrives first.
@MainActor
private final class CompletionGate {
  private var completion: (@MainActor () -> Void)?

  init(_ completion: @escaping @MainActor () -> Void) {
    self.completion = completion
  }

  func fire() {
    guard let completion else { return }
    self.completion = nil
    completion()
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
enum UpdateChecker {
  enum Outcome: Sendable {
    case upToDate(current: ReleaseVersion)
    case updateAvailable(latest: ReleaseVersion)
    /// The release host named a version older than one already seen. Shown as a
    /// warning rather than silently accepted, because that is what hiding a
    /// security fix would look like from here.
    case regressionSuspected(highestSeen: ReleaseVersion, reported: ReleaseVersion)
    case failed
  }

  static let releasePageURL = URL(
    string: "https://github.com/assff1123/metashield/releases/latest")!

  nonisolated private static let feedURL = URL(
    string: "https://api.github.com/repos/assff1123/metashield/releases/latest")!
  private static let enabledKey = "kr.metashield.app.updateCheckEnabled"
  private static let lastCheckKey = "kr.metashield.app.lastUpdateCheck"
  private static let highestSeenVersionKey = "kr.metashield.app.highestSeenVersion"
  private static let checkInterval: TimeInterval = 24 * 60 * 60
  private static let backgroundDeadline: TimeInterval = 8
  nonisolated private static let maximumResponseByteCount = 512 * 1_024

  static var isEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: enabledKey) }
    set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
  }

  /// The newest version this copy has ever been told about. Never lowered, so a
  /// single poisoned answer cannot erase the evidence that detects the next one.
  private static var highestSeenVersion: ReleaseVersion? {
    get {
      guard let text = UserDefaults.standard.string(forKey: highestSeenVersionKey) else {
        return nil
      }
      return ReleaseVersion(tag: text)
    }
    set {
      guard let newValue else { return }
      UserDefaults.standard.set(String(describing: newValue), forKey: highestSeenVersionKey)
    }
  }

  static var currentVersion: ReleaseVersion? {
    guard
      let string = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    else { return nil }
    return ReleaseVersion(tag: string)
  }

  static let updateNotificationCategory = "kr.metashield.app.update"

  enum DownloadFailure: LocalizedError {
    case network
    case signature
    case manifest
    case contents
    case storage(String)

    var errorDescription: String? {
      switch self {
      case .network: return "업데이트 파일을 받지 못했습니다."
      case .signature: return "서명 검증에 실패했습니다. 이 파일은 설치하지 마세요."
      case .manifest: return "업데이트 정보가 올바르지 않습니다."
      case .contents: return "받은 파일의 체크섬이 서명된 값과 다릅니다. 설치하지 마세요."
      case .storage(let reason): return "다운로드 폴더에 저장하지 못했습니다: \(reason)"
      }
    }
  }

  /// Ed25519 keys that may sign a release manifest. The private half never
  /// touches this machine outside a release, and never touches GitHub. A second
  /// key can be added here ahead of a rotation so older copies keep verifying.
  nonisolated private static let manifestPublicKeys: [Data] = [
    "qZVZ0St3YMtN6eL5kZroDGtJ6NpUXC23ge5REIG/n6s="
  ].compactMap { Data(base64Encoded: $0) }

  nonisolated private static let releaseAssetRoot =
    "https://github.com/assff1123/metashield/releases/download"

  /// Every asset address is derived from the version the app already validated.
  /// Nothing in a downloaded file can influence which address is contacted.
  nonisolated private static func assetURL(version: ReleaseVersion, name: String) -> URL? {
    URL(string: "\(releaseAssetRoot)/v\(version)/\(name)")
  }

  /// Fetches the signed manifest, verifies it, downloads the disk image, and
  /// only then hands the user a file. The app never installs it.
  static func downloadVerifiedUpdate(
    version: ReleaseVersion,
    progress: @escaping @MainActor (String) -> Void,
    completion: @escaping @MainActor (Result<URL, Error>) -> Void
  ) {
    guard let manifestURL = assetURL(version: version, name: "metashield-update.json"),
      let signatureURL = assetURL(version: version, name: "metashield-update.json.sig")
    else {
      completion(.failure(DownloadFailure.manifest))
      return
    }

    progress("업데이트 정보를 확인하는 중…")
    fetchAsset(from: manifestURL, maximumByteCount: UpdateManifest.maximumManifestByteCount) {
      manifestData in
      Task { @MainActor in
        guard let manifestData else {
          completion(.failure(DownloadFailure.network))
          return
        }
        fetchAsset(
          from: signatureURL, maximumByteCount: UpdateManifest.maximumSignatureByteCount
        ) { signatureData in
          Task { @MainActor in
            guard let signatureData,
              let signatureText = String(data: signatureData, encoding: .utf8),
              let signature = Data(
                base64Encoded: signatureText.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
              completion(.failure(DownloadFailure.network))
              return
            }
            // Verify before parsing: untrusted bytes never reach the JSON reader.
            guard
              UpdateSignature.isValid(
                signature, of: manifestData, publicKeys: manifestPublicKeys)
            else {
              completion(.failure(DownloadFailure.signature))
              return
            }
            guard let manifest = UpdateManifest(json: manifestData, expectedVersion: version)
            else {
              completion(.failure(DownloadFailure.manifest))
              return
            }
            downloadDiskImage(manifest: manifest, progress: progress, completion: completion)
          }
        }
      }
    }
  }

  private static func downloadDiskImage(
    manifest: UpdateManifest,
    progress: @escaping @MainActor (String) -> Void,
    completion: @escaping @MainActor (Result<URL, Error>) -> Void
  ) {
    guard let assetURL = assetURL(version: manifest.version, name: manifest.diskImageName) else {
      completion(.failure(DownloadFailure.manifest))
      return
    }
    let temporaryURL: URL
    let handle: FileHandle
    do {
      (temporaryURL, handle) = try makeDownloadFile(for: manifest)
    } catch {
      completion(.failure(DownloadFailure.storage(error.localizedDescription)))
      return
    }

    progress("검증된 DMG를 받는 중… (\(manifest.byteCount / 1_048_576) MB)")
    fetchAsset(from: assetURL, maximumByteCount: manifest.byteCount, sink: handle) { received in
      Task { @MainActor in
        try? handle.close()
        // A transfer the delegate aborted is a network failure. Reporting it as
        // a checksum mismatch would wrongly suggest a tampered release.
        guard received != nil else {
          try? FileManager.default.removeItem(at: temporaryURL)
          completion(.failure(DownloadFailure.network))
          return
        }
        do {
          let finalURL = try finishDownload(temporaryURL: temporaryURL, manifest: manifest)
          completion(.success(finalURL))
        } catch {
          try? FileManager.default.removeItem(at: temporaryURL)
          completion(.failure(error))
        }
      }
    }
  }

  private static func makeDownloadFile(for manifest: UpdateManifest) throws -> (URL, FileHandle) {
    let directory =
      FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporaryURL = directory.appendingPathComponent(
      ".\(manifest.diskImageName).\(UUID().uuidString).part")
    let descriptor = temporaryURL.path.withCString {
      open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o644)
    }
    guard descriptor >= 0 else {
      throw DownloadFailure.storage(String(cString: strerror(errno)))
    }
    return (temporaryURL, FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
  }

  private static func finishDownload(temporaryURL: URL, manifest: UpdateManifest) throws -> URL {
    let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
    guard (attributes[.size] as? NSNumber)?.intValue == manifest.byteCount else {
      throw DownloadFailure.contents
    }
    let digest = try FileDigest.sha256(ofFileAt: temporaryURL)
    guard FileDigest.matches(digest, manifest.sha256) else {
      throw DownloadFailure.contents
    }

    let directory = temporaryURL.deletingLastPathComponent()
    var destination = directory.appendingPathComponent(manifest.diskImageName)
    var index = 2
    while FileManager.default.fileExists(atPath: destination.path) {
      destination = directory.appendingPathComponent(
        "MetaShield-\(manifest.version)-direct-\(index).dmg")
      index += 1
    }
    try FileManager.default.moveItem(at: temporaryURL, to: destination)
    do {
      try markAsDownloaded(destination)
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
    return destination
  }

  /// Keeps the same first-run experience as a browser download. Without this the
  /// app would hand the user a file that skips Gatekeeper's first-launch check,
  /// so a failure here is a failure of the download: handing over an unmarked
  /// disk image would quietly remove a check the user is entitled to.
  private static func markAsDownloaded(_ url: URL) throws {
    let value = "0083;\(String(format: "%08x", UInt32(Date().timeIntervalSince1970)));MetaShield;"
    let result = value.withCString { bytes in
      url.path.withCString { path in
        setxattr(path, "com.apple.quarantine", bytes, strlen(bytes), 0, 0)
      }
    }
    guard result == 0 else {
      throw DownloadFailure.storage(
        "격리 속성을 설정하지 못했습니다: \(String(cString: strerror(errno)))")
    }
    // Read it back: a filesystem that silently drops extended attributes would
    // otherwise look like success.
    let size = url.path.withCString { path in
      getxattr(path, "com.apple.quarantine", nil, 0, 0, 0)
    }
    guard size > 0 else {
      throw DownloadFailure.storage("격리 속성이 저장되지 않는 파일시스템입니다.")
    }
  }

  nonisolated private static func fetchAsset(
    from url: URL,
    maximumByteCount: Int,
    sink: FileHandle? = nil,
    completion: @escaping @Sendable (Data?) -> Void
  ) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 300
    configuration.httpAdditionalHeaders = ["User-Agent": "MetaShield (verified update download)"]
    let delegate = BoundedAssetDelegate(
      maximumByteCount: maximumByteCount, sink: sink, completion: completion)
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    session.dataTask(with: URLRequest(url: url)).resume()
  }

  /// Notification APIs require a real bundle. A plain `swift run` binary has none.
  private static var canUseNotifications: Bool {
    Bundle.main.bundleIdentifier != nil
  }

  static func becomeNotificationDelegate(_ delegate: UNUserNotificationCenterDelegate) {
    guard canUseNotifications else { return }
    UNUserNotificationCenter.current().delegate = delegate
  }

  static func requestNotificationAuthorization() {
    guard canUseNotifications else { return }
    requestNotificationAuthorizationOffActor()
  }

  /// UserNotifications completes on framework-owned queues. Construct its
  /// callbacks outside MainActor so Swift does not attach a main-executor
  /// precondition to a closure the framework invokes on a private queue.
  nonisolated private static func requestNotificationAuthorizationOffActor() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
  }

  nonisolated private static func fetchNotificationAuthorization(
    completion: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let isAuthorized = settings.authorizationStatus == .authorized
      Task { @MainActor in
        completion(isAuthorized)
      }
    }
  }

  /// Used by headless Finder, Services, and Photos runs. It posts a banner only
  /// when the user already enabled the check and already granted notifications:
  /// a background run must never raise a permission prompt. The completion always
  /// runs, at the latest after `backgroundDeadline`, so the process still exits
  /// promptly when the network hangs.
  static func notifyIfUpdateAvailableInBackground(completion: @escaping @MainActor () -> Void) {
    guard isEnabled, canUseNotifications else {
      completion()
      return
    }
    let gate = CompletionGate(completion)
    fetchNotificationAuthorization { isAuthorized in
      guard isAuthorized else {
        gate.fire()
        return
      }
      let didStart = checkIfDue { outcome in
        if case .updateAvailable(let latest) = outcome {
          postUpdateNotification(latest: latest)
        }
        gate.fire()
      }
      if !didStart { gate.fire() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + backgroundDeadline) {
      gate.fire()
    }
  }

  private static func postUpdateNotification(latest: ReleaseVersion) {
    let content = UNMutableNotificationContent()
    content.title = "MetaShield 새 버전 \(latest)"
    content.body = "눌러서 릴리스 페이지를 엽니다. 앱이 직접 내려받거나 설치하지 않습니다."
    content.categoryIdentifier = updateNotificationCategory
    // One pending banner per version, so repeated runs cannot stack notifications.
    let request = UNNotificationRequest(
      identifier: "\(updateNotificationCategory).\(latest)",
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().add(request)
  }

  /// A check the user explicitly asked for. Not rate limited, still opt-in.
  static func checkNow(completion: @escaping @MainActor @Sendable (Outcome) -> Void) {
    guard isEnabled else { return }
    performCheck(completion: completion)
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
        let seen = highestSeenVersion
        highestSeenVersion = UpdateFeedPolicy.updatedHighestSeen(
          reported: latest, current: current, highestSeen: seen)
        switch UpdateFeedPolicy.judge(reported: latest, current: current, highestSeen: seen) {
        case .updateAvailable(let version):
          completion(.updateAvailable(latest: version))
        case .upToDate(let version):
          completion(.upToDate(current: version))
        case .regressionSuspected(let highest, let reported):
          completion(.regressionSuspected(highestSeen: highest, reported: reported))
        }
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
