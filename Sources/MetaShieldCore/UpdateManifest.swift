import CryptoKit
import Foundation

/// A signed statement about one release.
///
/// The manifest never carries a URL. Every address the app contacts is built
/// from compiled-in constants, so a manifest cannot redirect a download. The
/// only fields that cross the trust boundary are a version, a file name that
/// must match the name derived from that version, a SHA-256, and a byte count.
public struct UpdateManifest: Equatable, Sendable {
  public static let schemaVersion = 1
  public static let maximumManifestByteCount = 8 * 1_024
  public static let maximumSignatureByteCount = 256
  public static let maximumDiskImageByteCount = 256 * 1_024 * 1_024

  public let version: ReleaseVersion
  public let diskImageName: String
  public let sha256: Data
  public let byteCount: Int

  public static func diskImageName(for version: ReleaseVersion) -> String {
    "MetaShield-\(version)-direct.dmg"
  }

  /// Parses a manifest that has *already* had its signature verified.
  ///
  /// `expectedVersion` is the tag the app resolved before fetching, so a signed
  /// manifest for one release cannot be replayed under another release's tag.
  public init?(json data: Data, expectedVersion: ReleaseVersion) {
    guard data.count <= Self.maximumManifestByteCount,
      let object = try? JSONSerialization.jsonObject(with: data),
      let payload = object as? [String: Any],
      let schema = payload["schema"] as? Int,
      schema == Self.schemaVersion,
      let versionText = payload["version"] as? String,
      let version = ReleaseVersion(tag: versionText),
      version == expectedVersion,
      let name = payload["dmgName"] as? String,
      name == Self.diskImageName(for: version),
      let digestText = payload["sha256"] as? String,
      let digest = Self.hexDigest(digestText),
      let byteCount = payload["size"] as? Int,
      byteCount > 0,
      byteCount <= Self.maximumDiskImageByteCount
    else {
      return nil
    }
    self.version = version
    self.diskImageName = name
    self.sha256 = digest
    self.byteCount = byteCount
  }

  /// Lowercase hex only. Uppercase or shortened digests are rejected rather than
  /// normalized so a manifest has exactly one valid spelling.
  private static func hexDigest(_ text: String) -> Data? {
    guard text.count == 64 else { return nil }
    var bytes = Data()
    bytes.reserveCapacity(32)
    var index = text.startIndex
    while index < text.endIndex {
      let next = text.index(index, offsetBy: 2)
      guard let value = UInt8(text[index..<next], radix: 16),
        text[index..<next].allSatisfy({ $0.isNumber || ("a"..."f").contains($0) })
      else {
        return nil
      }
      bytes.append(value)
      index = next
    }
    return bytes
  }
}

public enum UpdateSignature {
  /// Detached Ed25519 verification against a compiled-in key set. More than one
  /// key is accepted so a future key rotation does not strand installed copies.
  public static func isValid(_ signature: Data, of payload: Data, publicKeys: [Data]) -> Bool {
    guard signature.count == 64, !publicKeys.isEmpty else { return false }
    for keyBytes in publicKeys {
      guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else {
        continue
      }
      if key.isValidSignature(signature, for: payload) {
        return true
      }
    }
    return false
  }
}

public enum FileDigest {
  /// Streams the file so a large disk image is never fully resident.
  public static func sha256(ofFileAt url: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let chunk = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
      if chunk.isEmpty { break }
      hasher.update(data: chunk)
    }
    return Data(hasher.finalize())
  }

  /// Constant-time comparison so a digest check cannot be probed by timing.
  public static func matches(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for (left, right) in zip(lhs, rhs) {
      difference |= left ^ right
    }
    return difference == 0
  }
}
