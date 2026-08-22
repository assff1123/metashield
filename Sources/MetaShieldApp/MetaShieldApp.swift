import AppKit

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
