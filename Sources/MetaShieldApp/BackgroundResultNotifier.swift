import AppKit
import UserNotifications

/// Posts one local notification summarizing a finished headless run, so Finder
/// service, Dock, and file-open hand-offs can report their result without ever
/// showing the main window.
///
/// Off by default. The main window's checkbox is the only place that enables it
/// and the only interactive moment that may raise the notification permission
/// prompt; the headless path itself never prompts, mirroring the background
/// update banner.
@MainActor
enum BackgroundResultNotifier {
  private static let enabledKey = "kr.metashield.app.backgroundResultNotificationEnabled"
  static let resultNotificationCategory = "kr.metashield.app.result"

  static var isEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: enabledKey) }
    set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
  }

  /// Notification APIs require a real bundle. A plain `swift run` binary has none.
  private static var canUseNotifications: Bool {
    Bundle.main.bundleIdentifier != nil
  }

  /// The completion always runs, so the headless process can chain its exit
  /// after the notification request has actually been handed to the system.
  static func postIfNeeded(
    successCount: Int,
    failureCount: Int,
    firstFailureDescription: String?,
    completion: @escaping @MainActor @Sendable () -> Void
  ) {
    guard isEnabled, canUseNotifications, successCount + failureCount > 0 else {
      completion()
      return
    }
    fetchAuthorization { isAuthorized in
      guard isAuthorized else {
        completion()
        return
      }
      let content = UNMutableNotificationContent()
      if failureCount == 0 {
        content.title = "MetaShield 처리 완료"
        content.body = "이미지 \(successCount)개가 검증을 통과했습니다."
      } else {
        content.title = "MetaShield 처리 실패 \(failureCount)개 (완료 \(successCount)개)"
        content.body = firstFailureDescription ?? "일부 이미지를 처리하지 못했습니다."
      }
      content.categoryIdentifier = resultNotificationCategory
      let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil
      )
      UNUserNotificationCenter.current().add(request) { _ in
        Task { @MainActor in
          completion()
        }
      }
    }
  }

  nonisolated private static func fetchAuthorization(
    completion: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let isAuthorized = settings.authorizationStatus == .authorized
      Task { @MainActor in
        completion(isAuthorized)
      }
    }
  }
}
