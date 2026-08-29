import AppKit

/// Chooses which Finder Services are visible the first time MetaShield runs, and
/// opens Apple's own settings pane for changing that afterwards.
///
/// macOS enables every service an app declares, and `Info.plist` has no way to
/// declare one as off by default. The only lever is `pbs`'s `NSServicesStatus`
/// preference — the same store System Settings writes — so the seed below uses
/// it exactly once, at first launch.
///
/// Two properties keep that acceptable. It runs once and never again, so a
/// choice the user later makes in System Settings is never overridden. And if
/// the undocumented format ever changes, the write simply does nothing: the
/// menu items stay visible, which is the behaviour of every earlier release and
/// still removable from System Settings. There is no state for the app to show
/// incorrectly, because the app owns no checkbox for it.
@MainActor
enum ServiceMenuSetup {
  private static let didSeedKey = "kr.metashield.app.didSeedServiceMenuDefaults"

  /// Titles must match `packaging/Info.plist` exactly; `pbs` keys services by
  /// their menu title.
  private static let hiddenByDefaultServices: [(title: String, message: String)] = [
    ("AVIF로 변환 (메타데이터 제거)", "convertToAVIF"),
    ("AVIF로 변환 및 압축 (메타데이터 제거)", "convertToAVIFCompressed"),
    ("AVIF로 변환 후 원본 휴지통으로", "convertToAVIFReplacing"),
    ("AVIF로 변환·압축 후 원본 휴지통으로", "convertToAVIFCompressedReplacing"),
  ]

  /// Starts a fresh install with only the metadata-scrubbing command in the
  /// Finder menu. The AVIF commands are opt-in because they are a different job
  /// from what most people install MetaShield for, and because AVIF writing
  /// needs macOS 26 anyway.
  static func seedDefaultsIfFirstLaunch() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: didSeedKey) else { return }
    // Record the attempt before touching pbs. A failure must not turn this into
    // a write that repeats on every launch and fights the user's own choice.
    defaults.set(true, forKey: didSeedKey)

    guard let preferences = UserDefaults(suiteName: "pbs") else { return }
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "kr.metashield.app"
    var status = preferences.dictionary(forKey: "NSServicesStatus") ?? [:]
    var changed = false
    for service in hiddenByDefaultServices {
      let key = "\(bundleIdentifier) - \(service.title) - \(service.message)"
      // Never overwrite an entry that already exists: it is the user's choice.
      guard status[key] == nil else { continue }
      status[key] = [
        "enabled_context_menu": false,
        "enabled_services_menu": false,
      ]
      changed = true
    }
    guard changed else { return }
    preferences.set(status, forKey: "NSServicesStatus")
    NSUpdateDynamicServices()
  }

  /// Opens the Services list in System Settings, where every MetaShield command
  /// can be shown or hidden with Apple's own checkboxes.
  static func openSystemServicesSettings() {
    let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts")
    guard let url else { return }
    NSWorkspace.shared.open(url)
  }
}
