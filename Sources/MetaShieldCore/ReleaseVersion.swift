import Foundation

/// A strictly parsed `major.minor.patch` release tag.
///
/// The update check only ever consumes a version string from the network, so
/// parsing rejects anything that is not three plain numbers. Nothing else from
/// a release feed is used: download and page URLs are compiled into the app.
public struct ReleaseVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
  public let major: Int
  public let minor: Int
  public let patch: Int

  public init(major: Int, minor: Int, patch: Int) {
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  public init?(tag: String) {
    var text = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count <= 24 else { return nil }
    if text.hasPrefix("v") || text.hasPrefix("V") {
      text.removeFirst()
    }

    let fields = text.split(separator: ".", omittingEmptySubsequences: false)
    guard fields.count == 3 else { return nil }

    var numbers: [Int] = []
    for field in fields {
      guard (1...4).contains(field.count),
        field.allSatisfy(\.isASCII),
        field.allSatisfy(\.isNumber),
        field == "0" || !field.hasPrefix("0"),
        let value = Int(field)
      else {
        return nil
      }
      numbers.append(value)
    }

    self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
  }

  public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }

  public var description: String {
    "\(major).\(minor).\(patch)"
  }
}
