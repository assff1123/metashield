import Foundation

/// Names for sanitized copies. One implementation shared by the app, the share
/// extension, and the CLI so every surface produces the same "<base>.clean.png"
/// family of names.
public enum OutputNaming {
  public static func uniqueCleanPNGURL(in directory: URL, baseName: String) -> URL {
    let safeBase = baseName.isEmpty ? "Cleaned Image" : baseName
    var candidate = directory.appendingPathComponent("\(safeBase).clean.png")
    var index = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = directory.appendingPathComponent("\(safeBase).clean-\(index).png")
      index += 1
    }
    return candidate
  }
}
