import Foundation

/// The contract between the app and the isolated decoder.
///
/// MetaShield's job is to open images from untrusted sources, and the decoders
/// that do that live in Apple's ImageIO. A memory-safety bug there would
/// otherwise run with the user's full privileges. Everything that touches
/// attacker-controlled bytes therefore happens in a sandboxed XPC service with
/// no file, network, or device access; the app keeps the file handling.
@objc public protocol ImageDecodingServiceProtocol {
  /// Decodes the bytes behind `handle`, rebuilds them as a clean opaque image,
  /// encodes the result, and returns the encoded bytes.
  ///
  /// The reply carries an error message instead of an `Error` so nothing has to
  /// be decoded from the service into a rich type.
  func sanitizeImage(
    handle: FileHandle,
    request: ImageDecodingRequest,
    withReply reply: @escaping (ImageDecodingResponse?, String?) -> Void
  )

  /// Checks that an already-encoded file is a clean MetaShield result.
  ///
  /// This also decodes, so it runs here rather than in the app for the same
  /// reason: `--verify` is pointed at arbitrary files the user did not
  /// necessarily produce.
  func verifyImage(
    handle: FileHandle,
    request: ImageDecodingRequest,
    withReply reply: @escaping (ImageDecodingResponse?, String?) -> Void
  )
}

/// What the app asks the isolated decoder to produce.
@objc(MetaShieldImageDecodingRequest)
public final class ImageDecodingRequest: NSObject, NSSecureCoding {
  public static var supportsSecureCoding: Bool { true }

  @objc public let outputFormat: String
  @objc public let maximumPixelCount: Int
  @objc public let maximumInputByteCount: Int
  @objc public let compressionQuality: Double

  public static let pngFormat = "png"
  public static let avifFormat = "avif"

  public init(
    outputFormat: String,
    maximumPixelCount: Int,
    maximumInputByteCount: Int,
    compressionQuality: Double
  ) {
    self.outputFormat = outputFormat
    self.maximumPixelCount = maximumPixelCount
    self.maximumInputByteCount = maximumInputByteCount
    self.compressionQuality = compressionQuality
  }

  public required init?(coder: NSCoder) {
    guard let format = coder.decodeObject(of: NSString.self, forKey: "outputFormat") as String?
    else { return nil }
    outputFormat = format
    maximumPixelCount = coder.decodeInteger(forKey: "maximumPixelCount")
    maximumInputByteCount = coder.decodeInteger(forKey: "maximumInputByteCount")
    compressionQuality = coder.decodeDouble(forKey: "compressionQuality")
  }

  public func encode(with coder: NSCoder) {
    coder.encode(outputFormat as NSString, forKey: "outputFormat")
    coder.encode(maximumPixelCount, forKey: "maximumPixelCount")
    coder.encode(maximumInputByteCount, forKey: "maximumInputByteCount")
    coder.encode(compressionQuality, forKey: "compressionQuality")
  }
}

/// What comes back. The service fully verifies encoded bytes before replying;
/// the app repeats bounds-checked container and byte-for-byte write checks.
@objc(MetaShieldImageDecodingResponse)
public final class ImageDecodingResponse: NSObject, NSSecureCoding {
  public static var supportsSecureCoding: Bool { true }

  @objc public let encoded: Data
  @objc public let width: Int
  @objc public let height: Int

  public init(encoded: Data, width: Int, height: Int) {
    self.encoded = encoded
    self.width = width
    self.height = height
  }

  public required init?(coder: NSCoder) {
    guard let data = coder.decodeObject(of: NSData.self, forKey: "encoded") as Data? else {
      return nil
    }
    encoded = data
    width = coder.decodeInteger(forKey: "width")
    height = coder.decodeInteger(forKey: "height")
  }

  public func encode(with coder: NSCoder) {
    coder.encode(encoded as NSData, forKey: "encoded")
    coder.encode(width, forKey: "width")
    coder.encode(height, forKey: "height")
  }
}

public enum ImageDecodingServiceIdentity {
  public static let bundleIdentifier = "kr.metashield.app.decode"
}
