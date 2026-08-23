import CoreGraphics
import Foundation
import ImageIO

/// How aggressively an AVIF copy is compressed.
///
/// ImageIO has no lossless AVIF mode — a quality of 1.0 makes the encoder fail
/// outright — so both levels are lossy and the distinction is how much detail
/// is traded for size. The level is part of the menu command the user picks,
/// never a hidden setting that changes what a command does.
public enum AVIFQuality: Sendable, Equatable {
  /// Near-transparent conversion. Still far smaller than the source PNG.
  case high
  /// The user's configured compression level.
  case compressed(Double)

  /// ImageIO rejects 1.0, so the usable range stops just short of it.
  public static let maximumCompressionValue = 0.95
  public static let minimumCompressionValue = 0.3
  public static let defaultCompressionValue = 0.7

  public var compressionValue: Double {
    switch self {
    case .high:
      return 0.9
    case .compressed(let value):
      return min(
        Self.maximumCompressionValue, max(Self.minimumCompressionValue, value))
    }
  }
}

/// What a sanitized AVIF is allowed to contain.
///
/// AVIF has no equivalent of the PNG path's chunk-level canonicalization, so the
/// guarantee is stated in terms of what the re-decoded file reports: one opaque
/// image at the expected size with no descriptive metadata containers. Apple's
/// encoder writes only structural entries (orientation, tile geometry), which is
/// why a bare `{TIFF}` dictionary is tolerated while EXIF, GPS, IPTC and maker
/// notes are rejected.
public struct AVIFInspection: Equatable, Sendable {
  public let width: Int
  public let height: Int
  public let byteCount: Int
}

public enum AVIFInspector {
  public static let typeIdentifier = "public.avif"

  /// Metadata containers that must never appear in a sanitized copy. Stored as
  /// plain strings because `CFString` constants are not `Sendable`.
  private static let forbiddenPropertyNames: Set<String> = [
    "{Exif}", "{ExifAux}", "{GPS}", "{IPTC}", "{MakerApple}", "{MakerCanon}",
    "{MakerNikon}", "{PNG}", "{JFIF}", "{8BIM}", "{DNG}", "{OpenEXR}",
  ]

  /// Structural keys Apple's AVIF encoder legitimately writes into `{TIFF}`.
  /// Anything else there came from the source and must fail verification.
  private static let allowedTIFFKeys: Set<String> = [
    "Orientation", "TileLength", "TileWidth", "XResolution", "YResolution",
    "ResolutionUnit", "Compression", "PhotometricInterpretation",
  ]

  @discardableResult
  public static func verify(
    _ data: Data,
    expectedWidth: Int,
    expectedHeight: Int
  ) throws -> AVIFInspection {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      throw MetaShieldError.verificationFailed("AVIF 결과를 다시 열지 못했습니다.")
    }
    guard CGImageSourceGetCount(source) == 1 else {
      throw MetaShieldError.verificationFailed("AVIF 결과에 이미지가 하나가 아닙니다.")
    }
    guard
      let image = CGImageSourceCreateImageAtIndex(
        source, 0,
        [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
      image.width == expectedWidth,
      image.height == expectedHeight
    else {
      throw MetaShieldError.verificationFailed("AVIF 결과 디코딩 또는 크기 검사에 실패했습니다.")
    }
    guard
      image.alphaInfo == .none || image.alphaInfo == .noneSkipFirst
        || image.alphaInfo == .noneSkipLast
    else {
      throw MetaShieldError.verificationFailed("AVIF 결과에 알파 채널이 남아 있습니다.")
    }

    let properties =
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    for key in properties.keys where forbiddenPropertyNames.contains(key as String) {
      throw MetaShieldError.verificationFailed(
        "AVIF 결과에 \(key as String) 메타데이터가 남아 있습니다.")
    }
    if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
      for key in tiff.keys where !allowedTIFFKeys.contains(key as String) {
        throw MetaShieldError.verificationFailed(
          "AVIF 결과에 예상하지 않은 TIFF 항목이 있습니다: \(key as String)")
      }
    }
    return AVIFInspection(width: expectedWidth, height: expectedHeight, byteCount: data.count)
  }
}
