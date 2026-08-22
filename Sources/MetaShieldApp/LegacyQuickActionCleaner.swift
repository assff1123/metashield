import AppKit

/// Releases through 0.3.7 copied an Automator workflow into
/// `~/Library/Services` and enabled it in Finder's `pbs` preferences. The app
/// now advertises a bundle-contained AppKit Service, so remove only the legacy
/// artifacts that MetaShield itself created. This migration is idempotent and
/// leaves every unrelated Service preference intact.
@MainActor
enum LegacyQuickActionCleaner {
  private static let identifier = "kr.metashield.quick-action"
  private static let installedWorkflowName = "MetaShield 메타데이터 완전 제거.workflow"

  static func run() {
    let fileManager = FileManager.default
    let servicesDirectory = fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Services", isDirectory: true)
    var changed = false

    let installedWorkflow = servicesDirectory.appendingPathComponent(
      installedWorkflowName, isDirectory: true)
    if fileManager.fileExists(atPath: installedWorkflow.path) {
      do {
        try fileManager.removeItem(at: installedWorkflow)
        changed = true
      } catch {
        // A failed best-effort migration must never prevent image processing.
      }
    }

    if let children = try? fileManager.contentsOfDirectory(
      at: servicesDirectory,
      includingPropertiesForKeys: nil,
      options: [.skipsSubdirectoryDescendants]
    ) {
      for child in children
      where child.lastPathComponent.hasPrefix(".MetaShield-")
        && child.pathExtension == "workflow"
      {
        if (try? fileManager.removeItem(at: child)) != nil {
          changed = true
        }
      }
    }

    if let preferences = UserDefaults(suiteName: "pbs") {
      for key in ["FinderActive", "FinderOrdering"] {
        guard var values = preferences.dictionary(forKey: key),
          values.removeValue(forKey: identifier) != nil
        else { continue }
        preferences.set(values, forKey: key)
        changed = true
      }
    }

    if changed {
      NSUpdateDynamicServices()
    }
  }
}
