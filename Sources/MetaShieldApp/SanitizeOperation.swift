import Foundation
import MetaShieldCore

/// Which command the user picked.
///
/// The operation is carried explicitly from the menu item all the way to the
/// worker, never inferred from a stored setting. Only `scrubInPlace` is
/// irreversible, and its menu item says exactly that; the AVIF operations always
/// write a new file beside the source.
enum SanitizeOperation: Sendable {
  case scrubInPlace
  /// `retiresOriginal` is part of the command the user picked, not a setting.
  /// Conversion is lossy and AVIF is not readable everywhere, so retiring the
  /// source is a separate, explicitly named menu item rather than a mode the
  /// existing one can silently acquire.
  case convertToAVIF(AVIFQuality, retiresOriginal: Bool)

  var isConversion: Bool {
    if case .convertToAVIF = self { return true }
    return false
  }

  /// Whether a successful result means the source has served its purpose.
  var retiresOriginal: Bool {
    switch self {
    case .scrubInPlace:
      return true
    case .convertToAVIF(_, let retires):
      return retires
    }
  }

  var progressDescription: String {
    switch self {
    case .scrubInPlace: return "디코딩·정리·재검증 중…"
    case .convertToAVIF: return "디코딩·정리·AVIF 변환 중…"
    }
  }
}

/// The compression level used by the "변환 및 압축" command.
///
/// This is a parameter of an explicitly named command, not a hidden mode switch:
/// it changes how small the new file is, never whether a file is replaced.
@MainActor
enum AVIFSettings {
  private static let qualityKey = "kr.metashield.app.avifCompressionQuality"

  static var compressionQuality: Double {
    get {
      let stored = UserDefaults.standard.object(forKey: qualityKey) as? Double
      guard let stored else { return AVIFQuality.defaultCompressionValue }
      return min(
        AVIFQuality.maximumCompressionValue,
        max(AVIFQuality.minimumCompressionValue, stored))
    }
    set {
      UserDefaults.standard.set(
        min(
          AVIFQuality.maximumCompressionValue,
          max(AVIFQuality.minimumCompressionValue, newValue)),
        forKey: qualityKey)
    }
  }

  static var compressedQuality: AVIFQuality { .compressed(compressionQuality) }
}
