import Foundation
import MetaShieldCore

/// Builds the sanitizer the app uses.
///
/// Decoding untrusted images is the app's whole job and also its largest attack
/// surface, so it happens in the sandboxed XPC service rather than here. The app
/// keeps the file handling: opening originals safely, verifying results, and
/// replacing them atomically.
///
/// There is deliberately no silent fallback to in-process decoding. If the
/// service cannot be reached the request fails, because quietly dropping the
/// isolation would remove the protection exactly when something is already
/// wrong.
enum SanitizerFactory {
  static func makeSanitizer(
    maximumPixelCount: Int = 40_000_000,
    maximumInputByteCount: Int = 256 * 1_024 * 1_024
  ) -> ImageSanitizer {
    let client = DecodingServiceClient()
    client.maximumPixelCount = maximumPixelCount
    client.maximumInputByteCount = maximumInputByteCount
    return ImageSanitizer(
      maximumPixelCount: maximumPixelCount,
      maximumInputByteCount: maximumInputByteCount,
      isolatedEncoder: client
    )
  }
}
