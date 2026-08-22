import Foundation

public enum ImageInputLocationPolicy {
  public static func isTemporary(_ url: URL) -> Bool {
    let inputPath = normalizedPath(url)
    // Photos' "Edit With" hand-off can use a sibling .../0/<UUID>/
    // directory instead of the process-specific .../T/ directory. Treat
    // every /var/folders entry as a managed, short-lived input.
    if inputPath == "/private/var/folders"
      || inputPath.hasPrefix("/private/var/folders/")
      || inputPath == "/var/folders"
      || inputPath.hasPrefix("/var/folders/")
    {
      return true
    }

    let temporaryRoots = [
      FileManager.default.temporaryDirectory,
      URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
      URL(fileURLWithPath: "/tmp", isDirectory: true),
      URL(fileURLWithPath: "/private/tmp", isDirectory: true),
    ]

    return temporaryRoots.contains { root in
      let rootPath = normalizedPath(root)
      return inputPath == rootPath || inputPath.hasPrefix(rootPath + "/")
    }
  }

  public static func isPhotosManaged(_ url: URL) -> Bool {
    let components = normalizedPath(url)
      .lowercased()
      .split(separator: "/")
    return components.contains { $0.hasSuffix(".photoslibrary") }
  }

  public static func shouldImportIntoPhotos(_ url: URL) -> Bool {
    isTemporary(url) || isPhotosManaged(url)
  }

  public static func canReplaceInPlace(_ url: URL) -> Bool {
    guard !shouldImportIntoPhotos(url) else { return false }
    if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let referenceCount = attributes[.referenceCount] as? NSNumber,
      referenceCount.intValue > 1
    {
      return false
    }
    return FileManager.default.isWritableFile(
      atPath: url.deletingLastPathComponent().standardizedFileURL.path
    )
  }

  private static func normalizedPath(_ url: URL) -> String {
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    guard path.count > 1 else { return path }
    return path.hasSuffix("/") ? String(path.dropLast()) : path
  }
}
