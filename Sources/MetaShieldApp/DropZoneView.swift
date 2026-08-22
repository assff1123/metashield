import AppKit

final class DropZoneView: NSView {
  var onFileURLs: (([URL]) -> Void)?
  var onImageData: ((Data) -> Void)?
  var onFilePromises: (([NSFilePromiseReceiver]) -> Void)?
  var isEnabled = true

  private let label = NSTextField(labelWithString: "PNG · JPEG · HEIC · WebP 등\n여기로 드래그")
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
    setAccessibilityRole(.group)
    setAccessibilityLabel("이미지 드롭 영역")
    setAccessibilityHelp("이미지를 이 영역에 놓으세요. 키보드 사용자는 Command-O 또는 이미지 선택 버튼을 사용할 수 있습니다.")

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
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
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
    path.lineWidth = highlighted ? 2 : 1
    path.setLineDash([7, 5], count: 2, phase: 0)
    path.stroke()
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
