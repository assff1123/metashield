import AppKit

final class DropZoneView: NSView {
  var onFileURLs: (([URL]) -> Void)?
  var onImageData: ((Data) -> Void)?
  var onFilePromises: (([NSFilePromiseReceiver]) -> Void)?
  /// Invoked by click, Space, Return, or an accessibility press, so the zone is
  /// a real control for keyboard and VoiceOver users instead of a drag-only
  /// surface with a "use Command-O instead" workaround.
  var onActivate: (() -> Void)?
  var isEnabled = true

  private let label = NSTextField(
    labelWithString: "PNG · JPEG · HEIC · WebP 등\n드래그하거나 클릭해 선택")
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
    setAccessibilityRole(.button)
    setAccessibilityLabel("이미지 선택 및 드롭 영역")
    setAccessibilityHelp("이미지를 이 영역에 놓거나, 클릭 또는 Space 키로 파일 선택 창을 엽니다.")

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

    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(accessibilityDisplayOptionsDidChange),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil
    )
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }

  @objc private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
    needsDisplay = true
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
    // A 1pt dashed hairline all but disappears under Increase Contrast. Use a
    // thicker solid border there instead.
    let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    path.lineWidth = increaseContrast ? 3 : (highlighted ? 2 : 1)
    if !increaseContrast {
      path.setLineDash([7, 5], count: 2, phase: 0)
    }
    path.stroke()
  }

  override var acceptsFirstResponder: Bool { isEnabled }

  override func becomeFirstResponder() -> Bool {
    needsDisplay = true
    return super.becomeFirstResponder()
  }

  override func resignFirstResponder() -> Bool {
    needsDisplay = true
    return super.resignFirstResponder()
  }

  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 16, yRadius: 16).fill()
  }

  override var focusRingMaskBounds: NSRect { bounds }

  override func keyDown(with event: NSEvent) {
    let spaceKeyCode: UInt16 = 49
    let returnKeyCode: UInt16 = 36
    if isEnabled, event.keyCode == spaceKeyCode || event.keyCode == returnKeyCode {
      onActivate?()
    } else {
      super.keyDown(with: event)
    }
  }

  override func mouseUp(with event: NSEvent) {
    let location = convert(event.locationInWindow, from: nil)
    // Only the first click activates: a double-click's second mouseUp would
    // queue behind the modal open panel and reopen it as soon as it closes.
    if isEnabled, event.clickCount == 1, bounds.contains(location) {
      onActivate?()
    } else {
      super.mouseUp(with: event)
    }
  }

  override func accessibilityPerformPress() -> Bool {
    guard isEnabled else { return false }
    onActivate?()
    return true
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
