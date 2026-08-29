import AppKit
import MetaShieldCore

/// Asks which command to run for images that arrive without one.
///
/// A Finder Services click already carries the user's intent: each menu item
/// names one operation. Photos' "Edit With", a Dock drop, and "Open With" carry
/// no such intent — they only say "this app, these images" — so the app used to
/// silently pick metadata scrubbing. With five commands available that guess is
/// wrong often enough to be worth asking about.
///
/// The scrub command stays the default button, so Return keeps the old one-step
/// flow for the common case.
@MainActor
enum OperationChooser {
  /// Returns nil when the user cancels.
  static func chooseOperation(for urls: [URL]) -> SanitizeOperation? {
    let choices = availableChoices()
    let alert = NSAlert()
    alert.messageText = "이 이미지로 무엇을 할까요?"
    alert.informativeText =
      urls.count == 1 ? urls[0].lastPathComponent : "이미지 \(urls.count)개"
    alert.alertStyle = .informational

    // Radio buttons rather than a pop-up: every option is visible at once, and
    // each carries the one line that matters — whether the original survives.
    let (accessory, buttons) = makeChoiceList(choices)
    alert.accessoryView = accessory
    alert.addButton(withTitle: "실행")
    alert.addButton(withTitle: "취소")

    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    guard let index = buttons.firstIndex(where: { $0.state == .on }),
      choices.indices.contains(index)
    else { return nil }
    return choices[index].operation
  }

  private static func makeChoiceList(_ choices: [Choice]) -> (NSView, [NSButton]) {
    let container = NSStackView()
    container.orientation = .vertical
    container.alignment = .leading
    container.spacing = 10
    container.translatesAutoresizingMaskIntoConstraints = false

    var buttons: [NSButton] = []
    for (index, choice) in choices.enumerated() {
      let row = NSStackView()
      row.orientation = .vertical
      row.alignment = .leading
      row.spacing = 1

      let button = NSButton(radioButtonWithTitle: choice.title, target: nil, action: nil)
      button.state = index == 0 ? .on : .off
      button.setAccessibilityHelp(choice.detail)
      buttons.append(button)
      row.addArrangedSubview(button)

      let detail = NSTextField(wrappingLabelWithString: choice.detail)
      detail.font = .preferredFont(forTextStyle: .caption1)
      detail.textColor = choice.isDestructive ? .systemRed : .secondaryLabelColor
      detail.setAccessibilityElement(false)
      // Indent to sit under the radio label rather than under the dot.
      let indent = NSStackView(views: [NSView(), detail])
      indent.orientation = .horizontal
      indent.spacing = 0
      indent.arrangedSubviews[0].widthAnchor.constraint(equalToConstant: 18).isActive = true
      detail.widthAnchor.constraint(equalToConstant: 380).isActive = true
      row.addArrangedSubview(indent)

      container.addArrangedSubview(row)
    }
    container.layoutSubtreeIfNeeded()
    let size = container.fittingSize
    container.frame = NSRect(x: 0, y: 0, width: max(400, size.width), height: size.height)
    return (container, buttons)
  }

  private struct Choice {
    let title: String
    /// What happens to the original — the only thing that cannot be undone.
    let detail: String
    let isDestructive: Bool
    let operation: SanitizeOperation
  }

  /// Mirrors the Finder menu, minus anything this system cannot do. Offering an
  /// AVIF command on a Mac whose ImageIO cannot encode AVIF would only produce
  /// a failure the user cannot act on.
  private static func availableChoices() -> [Choice] {
    var choices: [Choice] = [
      Choice(
        title: "메타데이터 완전 제거",
        detail: "정리된 PNG가 원본의 이름을 물려받고, 원본은 휴지통으로 갑니다. 되돌릴 수 있습니다.",
        isDestructive: false,
        operation: .scrubInPlace)
    ]
    guard AVIFInspector.isEncodingAvailable else { return choices }
    choices.append(
      Choice(
        title: "AVIF로 변환",
        detail: "원본을 그대로 두고 .clean.avif 사본만 만듭니다.",
        isDestructive: false,
        operation: .convertToAVIF(.high, retiresOriginal: false)))
    choices.append(
      Choice(
        title: "AVIF로 변환 및 압축",
        detail: "앱에서 설정한 품질로 더 작게 만듭니다. 원본은 그대로 둡니다.",
        isDestructive: false,
        operation: .convertToAVIF(AVIFSettings.compressedQuality, retiresOriginal: false)))
    choices.append(
      Choice(
        title: "AVIF로 변환 후 원본 휴지통으로",
        detail: "AVIF는 손실 압축이고 구형 환경에서 표시되지 않습니다. 원본이 필요하면 위를 고르세요.",
        isDestructive: true,
        operation: .convertToAVIF(.high, retiresOriginal: true)))
    choices.append(
      Choice(
        title: "AVIF로 변환·압축 후 원본 휴지통으로",
        detail: "압축률이 낮을수록 화질 손실이 큽니다. 원본이 필요하면 위를 고르세요.",
        isDestructive: true,
        operation: .convertToAVIF(AVIFSettings.compressedQuality, retiresOriginal: true)))
    return choices
  }
}
