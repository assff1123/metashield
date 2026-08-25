import Accelerate
import CoreGraphics
import Foundation
import ImageIO

public struct SanitizationReport: Sendable {
  public let url: URL
  public let width: Int
  public let height: Int
  public let originalByteCount: Int
  public let sanitizedByteCount: Int
  public let chunkTypes: [String]
}

public final class ImageSanitizer: Sendable {
  public static let shared = ImageSanitizer()

  /// Prevent a maliciously large image from exhausting memory while processing a service request.
  public let maximumPixelCount: Int
  public let maximumInputByteCount: Int

  /// Where decoding happens.
  ///
  /// `nil` means this process does it, which is what the command-line tool and
  /// the self tests use. The app passes an isolated decoder so that the code
  /// reading untrusted image bytes runs in a sandbox instead of with the user's
  /// full privileges. File handling and verification stay here either way.
  private let isolatedEncoder: CanonicalImageEncoding?

  public init(
    maximumPixelCount: Int = 40_000_000,
    maximumInputByteCount: Int = 256 * 1_024 * 1_024,
    isolatedEncoder: CanonicalImageEncoding? = nil
  ) {
    precondition(maximumPixelCount > 0)
    precondition(maximumInputByteCount > 0)
    self.maximumPixelCount = maximumPixelCount
    self.maximumInputByteCount = maximumInputByteCount
    self.isolatedEncoder = isolatedEncoder
  }

  public func makeCanonicalPNG(from sourceData: Data) throws -> Data {
    try validateInputByteCount(sourceData.count)
    if let isolatedEncoder {
      return try isolatedEncoder.encodedSanitizedPNG(from: sourceData).0
    }
    return try encodedSanitizedPNG(from: sourceData).0
  }

  public func makeCanonicalPNG(from sourceURL: URL) throws -> Data {
    let inputURL = sourceURL.standardizedFileURL
    let sourceData = try mappedInputData(at: inputURL)
    return try makeCanonicalPNG(from: sourceData)
  }

  public func sanitizePNGInPlace(at url: URL) throws -> SanitizationReport {
    let standardizedURL = url.standardizedFileURL
    let originalFileState = try inPlaceFileState(at: standardizedURL)
    guard standardizedURL.pathExtension.lowercased() == "png" else {
      throw MetaShieldError.unsupportedInPlaceFormat(standardizedURL.pathExtension.lowercased())
    }

    guard originalFileState.size >= 0,
      UInt64(originalFileState.size) <= UInt64(Int.max)
    else {
      throw MetaShieldError.inputFileTooLarge(byteCount: Int.max, limit: maximumInputByteCount)
    }
    let originalSize = Int(originalFileState.size)
    try validateInputByteCount(originalSize)
    let canonical = try makeCanonicalPNG(from: standardizedURL)
    let inspection = try PNGInspector.verifyCanonical(canonical)

    let staged = try stageReplacement(besideOriginalAt: standardizedURL, pathExtension: "png")
    let tempURL = staged.url

    do {
      try writeTemporaryDataSecurely(canonical, to: tempURL, permissions: 0o600)
      try synchronizeFile(at: tempURL)
      let reread = try Data(contentsOf: tempURL, options: [.mappedIfSafe])
      let finalInspection = try PNGInspector.verifyCanonical(reread)
      guard finalInspection == inspection, reread == canonical else {
        throw MetaShieldError.verificationFailed("저장 전후 내용이 달라졌습니다.")
      }
      try verifyUnchanged(originalFileState, at: standardizedURL)
      try applySecurityAttributes(
        from: standardizedURL,
        originalState: originalFileState,
        to: tempURL
      )
      try verifyUnchanged(originalFileState, at: standardizedURL)
      try commitReplacement(staged, destination: standardizedURL)

      return SanitizationReport(
        url: standardizedURL,
        width: inspection.width,
        height: inspection.height,
        originalByteCount: originalSize,
        sanitizedByteCount: canonical.count,
        chunkTypes: inspection.chunkTypes
      )
    } catch {
      try? FileManager.default.removeItem(at: tempURL)
      if let stagingDirectory = staged.stagingDirectory {
        try? FileManager.default.removeItem(at: stagingDirectory)
      }
      throw error
    }
  }

  public func writeCanonicalPNG(from sourceURL: URL, to destinationURL: URL) throws
    -> SanitizationReport
  {
    let inputURL = sourceURL.standardizedFileURL
    let outputURL = destinationURL.standardizedFileURL
    let sourceData = try mappedInputData(at: inputURL)
    let originalSize = sourceData.count
    let canonical = try makeCanonicalPNG(from: sourceData)
    let inspection = try PNGInspector.verifyCanonical(canonical)
    try writeVerifiedCanonicalPNG(
      canonical, inspection: inspection, to: outputURL, replaceExisting: false)
    return SanitizationReport(
      url: outputURL,
      width: inspection.width,
      height: inspection.height,
      originalByteCount: originalSize,
      sanitizedByteCount: canonical.count,
      chunkTypes: inspection.chunkTypes
    )
  }

  public func writeCanonicalPNG(from sourceData: Data, to destinationURL: URL) throws
    -> SanitizationReport
  {
    let outputURL = destinationURL.standardizedFileURL
    try validateInputByteCount(sourceData.count)
    let canonical = try makeCanonicalPNG(from: sourceData)
    let inspection = try PNGInspector.verifyCanonical(canonical)
    try writeVerifiedCanonicalPNG(
      canonical, inspection: inspection, to: outputURL, replaceExisting: false)
    return SanitizationReport(
      url: outputURL,
      width: inspection.width,
      height: inspection.height,
      originalByteCount: sourceData.count,
      sanitizedByteCount: canonical.count,
      chunkTypes: inspection.chunkTypes
    )
  }

  /// Decodes and re-encodes without touching the file system.
  ///
  /// These are what the isolated decoder runs. Keeping them here means the
  /// sanitizing pipeline has exactly one implementation, whether it is invoked
  /// in the service or directly by the command-line tool.
  public func encodedSanitizedPNG(from sourceData: Data) throws -> (Data, (width: Int, height: Int))
  {
    try validateInputByteCount(sourceData.count)
    guard
      let source = CGImageSourceCreateWithData(
        sourceData as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    else {
      throw MetaShieldError.unsupportedOrCorruptImage
    }
    let image = try makeSanitizedImage(from: source)
    let encoded = try PNGInspector.canonicalData(
      from: try encode(image, as: "public.png", options: nil))
    // Verification decodes, so it belongs wherever decoding belongs. When this
    // runs in the isolated service the app never has to open these bytes with
    // ImageIO, which would hand a compromised decoder a way back out.
    try verifyImageDecodes(encoded, expectedWidth: image.width, expectedHeight: image.height)
    return (encoded, (image.width, image.height))
  }

  public func encodedSanitizedAVIF(
    from sourceData: Data,
    quality: AVIFQuality
  ) throws -> (Data, (width: Int, height: Int)) {
    try validateInputByteCount(sourceData.count)
    guard
      let source = CGImageSourceCreateWithData(
        sourceData as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    else {
      throw MetaShieldError.unsupportedOrCorruptImage
    }
    guard AVIFInspector.isEncodingAvailable else {
      throw MetaShieldError.avifEncodingUnavailable
    }
    let image = try makeSanitizedImage(from: source)
    let encoded = try encode(
      image,
      as: AVIFInspector.typeIdentifier,
      options: [kCGImageDestinationLossyCompressionQuality: quality.compressionValue]
        as CFDictionary
    )
    try AVIFInspector.verify(
      encoded, expectedWidth: image.width, expectedHeight: image.height)
    return (encoded, (image.width, image.height))
  }

  /// Confirms an encoded file is a clean result. Decoding happens in the
  /// isolated service when one is configured, because `--verify` is pointed at
  /// files this app did not necessarily produce.
  public func verifiedImageSize(
    of sourceData: Data,
    format: String
  ) throws -> (width: Int, height: Int) {
    if format == ImageDecodingRequest.avifFormat {
      let inspection = try inProcessAVIFSize(of: sourceData)
      return (inspection.width, inspection.height)
    }
    let inspection = try PNGInspector.verifyCanonical(sourceData)
    try verifyImageDecodes(
      sourceData, expectedWidth: inspection.width, expectedHeight: inspection.height)
    return (inspection.width, inspection.height)
  }

  private func inProcessAVIFSize(of data: Data) throws -> AVIFInspection {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else {
      throw MetaShieldError.verificationFailed("AVIF 파일을 읽지 못했습니다.")
    }
    return try AVIFInspector.verify(data, expectedWidth: width, expectedHeight: height)
  }

  public func verifyCanonicalPNG(at url: URL) throws -> PNGInspection {
    let data = try mappedInputData(at: url.standardizedFileURL)
    // The structural parse is pure Swift and always runs here; only the decode
    // is delegated, so a hostile file never reaches ImageIO in this process.
    let inspection = try PNGInspector.verifyCanonical(data)
    if let isolatedEncoder {
      let size = try isolatedEncoder.verifiedImageSize(
        of: data, format: ImageDecodingRequest.pngFormat)
      guard size.width == inspection.width, size.height == inspection.height else {
        throw MetaShieldError.verificationFailed("검증된 크기가 구조와 다릅니다.")
      }
    } else {
      try verifyImageDecodes(
        data, expectedWidth: inspection.width, expectedHeight: inspection.height)
    }
    return inspection
  }

  /// Writes a sanitized AVIF copy beside or into the chosen directory.
  ///
  /// AVIF is always a lossy copy and therefore never replaces the source: the
  /// original stays untouched, which keeps the one irreversible operation in
  /// MetaShield the explicitly named in-place PNG command.
  public func writeCanonicalAVIF(
    from sourceURL: URL,
    to destinationURL: URL,
    quality: AVIFQuality
  ) throws -> SanitizationReport {
    let inputURL = sourceURL.standardizedFileURL
    let outputURL = destinationURL.standardizedFileURL
    let sourceData = try mappedInputData(at: inputURL)
    return try writeCanonicalAVIF(
      from: sourceData, originalByteCount: sourceData.count, to: outputURL, quality: quality)
  }

  public func writeCanonicalAVIF(
    from sourceData: Data,
    to destinationURL: URL,
    quality: AVIFQuality
  ) throws -> SanitizationReport {
    try validateInputByteCount(sourceData.count)
    return try writeCanonicalAVIF(
      from: sourceData,
      originalByteCount: sourceData.count,
      to: destinationURL.standardizedFileURL,
      quality: quality
    )
  }

  public func verifyCanonicalAVIF(at url: URL) throws -> AVIFInspection {
    let data = try mappedInputData(at: url.standardizedFileURL)
    if let isolatedEncoder {
      let size = try isolatedEncoder.verifiedImageSize(
        of: data, format: ImageDecodingRequest.avifFormat)
      return AVIFInspection(width: size.width, height: size.height, byteCount: data.count)
    }
    return try inProcessAVIFSize(of: data)
  }

  private func writeCanonicalAVIF(
    from sourceData: Data,
    originalByteCount: Int,
    to outputURL: URL,
    quality: AVIFQuality
  ) throws -> SanitizationReport {
    try validateInputByteCount(sourceData.count)
    let encoded: Data
    let size: (width: Int, height: Int)
    if let isolatedEncoder {
      (encoded, size) = try isolatedEncoder.encodedSanitizedAVIF(from: sourceData, quality: quality)
    } else {
      (encoded, size) = try encodedSanitizedAVIF(from: sourceData, quality: quality)
    }
    // When the isolated decoder produced these bytes it already verified them
    // there. Re-opening them with ImageIO here is exactly the re-entry the
    // isolation exists to prevent.
    let inspection =
      isolatedEncoder != nil
      ? AVIFInspection(width: size.width, height: size.height, byteCount: encoded.count)
      : try AVIFInspector.verify(
        encoded, expectedWidth: size.width, expectedHeight: size.height)
    try writeVerifiedAVIF(
      encoded, width: inspection.width, height: inspection.height, to: outputURL)
    return SanitizationReport(
      url: outputURL,
      width: inspection.width,
      height: inspection.height,
      originalByteCount: originalByteCount,
      sanitizedByteCount: encoded.count,
      chunkTypes: []
    )
  }

  /// Decodes one frame and rebuilds it as a fresh, fully opaque 8-bit sRGB image
  /// carrying no source metadata. Both the PNG and the AVIF encoders start here,
  /// so the scrubbing guarantees do not depend on the output format.
  private func makeSanitizedImage(from source: CGImageSource) throws -> CGImage {
    let frameCount = CGImageSourceGetCount(source)
    guard frameCount > 0 else {
      throw MetaShieldError.unsupportedOrCorruptImage
    }
    guard frameCount == 1 else {
      throw MetaShieldError.animatedImageNotAllowed
    }

    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let rawWidth = properties[kCGImagePropertyPixelWidth] as? Int,
      let rawHeight = properties[kCGImagePropertyPixelHeight] as? Int,
      rawWidth > 0,
      rawHeight > 0
    else {
      throw MetaShieldError.invalidDimensions
    }

    guard rawWidth <= Int.max / rawHeight,
      rawWidth * rawHeight <= maximumPixelCount
    else {
      throw MetaShieldError.imageTooLarge(width: rawWidth, height: rawHeight)
    }

    let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1

    // Decode the stored samples instead of a premultiplied bitmap. Recovering a
    // straight color from premultiplied samples leaves the source alpha's low
    // bits as +/-1 noise in the output, which keeps an alpha-LSB payload
    // readable in the final RGB image.
    guard
      let decodedImage = CGImageSourceCreateImageAtIndex(
        source, 0,
        [
          kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    else {
      throw MetaShieldError.unsupportedOrCorruptImage
    }

    let width = decodedImage.width
    let height = decodedImage.height
    guard width > 0, height > 0,
      width <= Int.max / height,
      width * height <= maximumPixelCount,
      width <= Int.max / 4,
      height <= Int.max / (width * 4)
    else {
      throw MetaShieldError.imageTooLarge(width: width, height: height)
    }

    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
      throw MetaShieldError.bitmapAllocationFailed
    }
    var rgba = try straightRGBAData(
      from: decodedImage, width: width, height: height, colorSpace: colorSpace)

    guard width <= Int.max / 3,
      height <= Int.max / (width * 3)
    else {
      throw MetaShieldError.imageTooLarge(width: width, height: height)
    }
    let pixelCount = width * height
    let rgbByteCount = pixelCount * 3
    rgba.withUnsafeMutableBytes { bytes in
      let pixels = bytes.bindMemory(to: UInt8.self)
      for pixel in 0..<pixelCount {
        let sourceIndex = pixel * 4
        let destinationIndex = pixel * 3
        let sanitizedAlpha = quantizedAlpha(Int(pixels[sourceIndex + 3]))
        for channel in 0..<3 {
          let straight = Int(pixels[sourceIndex + channel])
          let composited = (straight * sanitizedAlpha + 255 * (255 - sanitizedAlpha) + 127) / 255
          pixels[destinationIndex + channel] = UInt8(clamping: composited)
        }
      }
    }
    rgba.removeSubrange(rgbByteCount..<rgba.count)

    // The composited image is fully opaque, so reorienting it here only moves
    // whole pixels and cannot reintroduce alpha-dependent rounding.
    let (rgb, orientedWidth, orientedHeight) = applyingOrientation(
      rgba, width: width, height: height, orientation: orientation)

    guard let provider = CGDataProvider(data: rgb as CFData),
      let cleanImage = CGImage(
        width: orientedWidth,
        height: orientedHeight,
        bitsPerComponent: 8,
        bitsPerPixel: 24,
        bytesPerRow: orientedWidth * 3,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .relativeColorimetric
      )
    else {
      throw MetaShieldError.imageEncodingFailed
    }

    return cleanImage
  }

  private func makeCanonicalPNG(from source: CGImageSource) throws -> Data {
    let cleanImage = try makeSanitizedImage(from: source)
    let encoded = try encode(cleanImage, as: "public.png", options: nil)
    return try PNGInspector.canonicalData(from: encoded)
  }

  private func encode(
    _ image: CGImage,
    as typeIdentifier: String,
    options: CFDictionary?
  ) throws -> Data {
    let mutableData = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        mutableData,
        typeIdentifier as CFString,
        1,
        nil
      )
    else {
      throw MetaShieldError.imageEncodingFailed
    }
    CGImageDestinationAddImage(destination, image, options)
    guard CGImageDestinationFinalize(destination) else {
      throw MetaShieldError.imageEncodingFailed
    }
    return mutableData as Data
  }

  /// Reads unpremultiplied 8-bit sRGB samples. vImage converts the decoded
  /// image directly into straight alpha, so the source alpha never divides the
  /// color channels. The bitmap-context path is only a fallback for source
  /// formats vImage cannot convert.
  private func straightRGBAData(
    from image: CGImage,
    width: Int,
    height: Int,
    colorSpace: CGColorSpace
  ) throws -> Data {
    let bytesPerRow = width * 4
    if let data = vImageStraightRGBAData(
      from: image, width: width, height: height, bytesPerRow: bytesPerRow, colorSpace: colorSpace)
    {
      return data
    }
    return try unpremultipliedRGBAData(
      from: image, width: width, height: height, bytesPerRow: bytesPerRow, colorSpace: colorSpace)
  }

  private func vImageStraightRGBAData(
    from image: CGImage,
    width: Int,
    height: Int,
    bytesPerRow: Int,
    colorSpace: CGColorSpace
  ) -> Data? {
    var format = vImage_CGImageFormat(
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      colorSpace: Unmanaged.passUnretained(colorSpace),
      bitmapInfo: CGBitmapInfo(
        rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.last.rawValue),
      version: 0,
      decode: nil,
      renderingIntent: .relativeColorimetric
    )
    var buffer = vImage_Buffer()
    guard
      vImageBuffer_InitWithCGImage(&buffer, &format, nil, image, vImage_Flags(kvImageNoFlags))
        == kvImageNoError,
      let sourceBase = buffer.data
    else {
      return nil
    }
    defer { free(buffer.data) }
    guard Int(buffer.width) == width,
      Int(buffer.height) == height,
      buffer.rowBytes >= bytesPerRow
    else {
      return nil
    }

    var data = Data(count: bytesPerRow * height)
    let sourceRowBytes = buffer.rowBytes
    data.withUnsafeMutableBytes { destination in
      guard let destinationBase = destination.baseAddress else { return }
      for row in 0..<height {
        memcpy(
          destinationBase.advanced(by: row * bytesPerRow),
          sourceBase.advanced(by: row * sourceRowBytes),
          bytesPerRow
        )
      }
    }
    return data
  }

  private func unpremultipliedRGBAData(
    from image: CGImage,
    width: Int,
    height: Int,
    bytesPerRow: Int,
    colorSpace: CGColorSpace
  ) throws -> Data {
    var rgba = Data(count: bytesPerRow * height)
    let bitmapInfo =
      CGBitmapInfo.byteOrder32Big.rawValue
      | CGImageAlphaInfo.premultipliedLast.rawValue
    let rendered = rgba.withUnsafeMutableBytes { rawBuffer -> Bool in
      guard let baseAddress = rawBuffer.baseAddress,
        let context = CGContext(
          data: baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: colorSpace,
          bitmapInfo: bitmapInfo
        )
      else {
        return false
      }
      context.setBlendMode(.copy)
      context.interpolationQuality = .none
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard rendered else {
      throw MetaShieldError.bitmapAllocationFailed
    }

    rgba.withUnsafeMutableBytes { bytes in
      let pixels = bytes.bindMemory(to: UInt8.self)
      for pixel in 0..<(width * height) {
        let index = pixel * 4
        let alpha = Int(pixels[index + 3])
        for channel in 0..<3 {
          let premultiplied = Int(pixels[index + channel])
          let straight =
            alpha == 0 ? 255 : min(255, (premultiplied * 255 + alpha / 2) / alpha)
          pixels[index + channel] = UInt8(clamping: straight)
        }
      }
    }
    return rgba
  }

  /// Applies the stored EXIF orientation by moving whole pixels of the finished
  /// opaque image.
  private func applyingOrientation(
    _ rgb: Data,
    width: Int,
    height: Int,
    orientation: Int
  ) -> (Data, Int, Int) {
    guard (2...8).contains(orientation) else { return (rgb, width, height) }
    let isTransposed = orientation >= 5
    let orientedWidth = isTransposed ? height : width
    let orientedHeight = isTransposed ? width : height
    var oriented = Data(count: width * height * 3)
    rgb.withUnsafeBytes { source in
      oriented.withUnsafeMutableBytes { destination in
        guard let sourcePixels = source.baseAddress?.assumingMemoryBound(to: UInt8.self),
          let destinationPixels = destination.baseAddress?.assumingMemoryBound(to: UInt8.self)
        else { return }
        for y in 0..<orientedHeight {
          for x in 0..<orientedWidth {
            let sourceX: Int
            let sourceY: Int
            switch orientation {
            case 2:
              sourceX = width - 1 - x
              sourceY = y
            case 3:
              sourceX = width - 1 - x
              sourceY = height - 1 - y
            case 4:
              sourceX = x
              sourceY = height - 1 - y
            case 5:
              sourceX = y
              sourceY = x
            case 6:
              sourceX = y
              sourceY = height - 1 - x
            case 7:
              sourceX = width - 1 - y
              sourceY = height - 1 - x
            default:
              sourceX = width - 1 - y
              sourceY = x
            }
            let sourceIndex = (sourceY * width + sourceX) * 3
            let destinationIndex = (y * orientedWidth + x) * 3
            destinationPixels[destinationIndex] = sourcePixels[sourceIndex]
            destinationPixels[destinationIndex + 1] = sourcePixels[sourceIndex + 1]
            destinationPixels[destinationIndex + 2] = sourcePixels[sourceIndex + 2]
          }
        }
      }
    }
    return (oriented, orientedWidth, orientedHeight)
  }

  /// Removes low-bit alpha payloads before compositing. 254/255 become fully opaque;
  /// other transparency is rounded to 16-level boundaries before the alpha channel is removed.
  private func quantizedAlpha(_ alpha: Int) -> Int {
    if alpha <= 7 { return 0 }
    if alpha >= 248 { return 255 }
    return min(240, ((alpha + 8) / 16) * 16)
  }

  private struct InPlaceFileState: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let linkCount: nlink_t
    let mode: mode_t
    let owner: uid_t
    let group: gid_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
  }

  /// Where a verified replacement waits before it takes the original's place.
  ///
  /// The preferred home is the original's own directory, because a `rename`
  /// within one directory is atomic: a crash leaves either the old file or the
  /// new one, never a partial file. A sandboxed app is granted the *file* the
  /// user opened, not its directory, so that write can be refused. In that case
  /// the replacement is staged in a private directory and committed with
  /// `replaceItemAt`, which is only equivalent while both live on one volume.
  private struct StagedReplacement {
    let url: URL
    let isBesideOriginal: Bool
    /// Non-nil only for private staging, so the directory can be removed.
    let stagingDirectory: URL?
  }

  private func stageReplacement(
    besideOriginalAt original: URL,
    pathExtension: String
  ) throws -> StagedReplacement {
    let directory = original.deletingLastPathComponent()
    let besideURL = directory.appendingPathComponent(
      ".metashield-\(UUID().uuidString).\(pathExtension)")

    // Probe the preferred location by creating the file the write will use.
    let descriptor = besideURL.path.withCString {
      open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    }
    if descriptor >= 0 {
      close(descriptor)
      // writeTemporaryDataSecurely re-creates it with O_EXCL, so clear the probe.
      try? FileManager.default.removeItem(at: besideURL)
      return StagedReplacement(url: besideURL, isBesideOriginal: true, stagingDirectory: nil)
    }
    let probeErrno = errno
    guard probeErrno == EACCES || probeErrno == EPERM || probeErrno == EROFS else {
      throw MetaShieldError.fileOperationFailed(String(cString: strerror(probeErrno)))
    }

    // The directory is closed to us. Stage privately and commit with
    // replaceItemAt, but only if that still replaces within one volume.
    let stagingDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MetaShieldStaging-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: stagingDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    do {
      guard try deviceIdentifier(of: stagingDirectory) == deviceIdentifier(of: directory) else {
        // A cross-volume replaceItemAt degrades to copy-and-delete, which can
        // lose the original on a crash. Refuse rather than weaken the promise;
        // the caller falls back to writing a separate clean copy.
        throw MetaShieldError.inPlaceReplacementUnavailable
      }
      return StagedReplacement(
        url: stagingDirectory.appendingPathComponent("replacement.\(pathExtension)"),
        isBesideOriginal: false,
        stagingDirectory: stagingDirectory
      )
    } catch {
      try? FileManager.default.removeItem(at: stagingDirectory)
      throw error
    }
  }

  private func commitReplacement(_ staged: StagedReplacement, destination: URL) throws {
    defer {
      if let stagingDirectory = staged.stagingDirectory {
        try? FileManager.default.removeItem(at: stagingDirectory)
      }
    }
    if staged.isBesideOriginal {
      try atomicReplace(source: staged.url, destination: destination)
      return
    }
    // Keep the attributes already applied to the staged file rather than letting
    // the original's metadata win, because those were copied from the original
    // deliberately and verified.
    _ = try FileManager.default.replaceItemAt(
      destination,
      withItemAt: staged.url,
      backupItemName: nil,
      options: [.usingNewMetadataOnly]
    )
    // Note for a future sandbox attempt: macOS quarantines a sandboxed
    // process's output and refuses to let it remove that marker, so a sandboxed
    // build leaves `com.apple.quarantine` on the replaced file. Measured, not
    // assumed — removing it here was tried and had no effect.
  }

  private func deviceIdentifier(of url: URL) throws -> dev_t {
    var value = stat()
    guard url.path.withCString({ stat($0, &value) }) == 0 else {
      throw MetaShieldError.fileOperationFailed(String(cString: strerror(errno)))
    }
    return value.st_dev
  }

  private func inPlaceFileState(at url: URL) throws -> InPlaceFileState {
    var value = stat()
    let result = url.path.withCString { lstat($0, &value) }
    guard result == 0 else {
      throw MetaShieldError.fileOperationFailed(String(cString: strerror(errno)))
    }
    let fileType = value.st_mode & S_IFMT
    if fileType == S_IFLNK { throw MetaShieldError.symbolicLinkNotAllowed }
    guard fileType == S_IFREG else { throw MetaShieldError.notARegularFile }
    guard value.st_nlink == 1 else { throw MetaShieldError.hardLinkedFileNotAllowed }
    return InPlaceFileState(
      device: value.st_dev,
      inode: value.st_ino,
      size: value.st_size,
      linkCount: value.st_nlink,
      mode: value.st_mode & 0o7777,
      owner: value.st_uid,
      group: value.st_gid,
      modifiedSeconds: value.st_mtimespec.tv_sec,
      modifiedNanoseconds: value.st_mtimespec.tv_nsec,
      changedSeconds: value.st_ctimespec.tv_sec,
      changedNanoseconds: value.st_ctimespec.tv_nsec
    )
  }

  private func verifyUnchanged(_ expected: InPlaceFileState, at url: URL) throws {
    guard try inPlaceFileState(at: url) == expected else {
      throw MetaShieldError.sourceChangedDuringProcessing
    }
  }

  private func applySecurityAttributes(
    from source: URL,
    originalState: InPlaceFileState,
    to destination: URL
  ) throws {
    let ownershipResult = destination.path.withCString {
      chown($0, originalState.owner, originalState.group)
    }
    guard ownershipResult == 0 else {
      throw MetaShieldError.fileOperationFailed(
        "파일 소유권을 보존하지 못했습니다: \(String(cString: strerror(errno)))")
    }
    let permissionResult = destination.path.withCString { chmod($0, originalState.mode) }
    guard permissionResult == 0 else {
      throw MetaShieldError.fileOperationFailed(
        "파일 접근 권한을 보존하지 못했습니다: \(String(cString: strerror(errno)))")
    }

    // `copyfile(..., COPYFILE_ACL)` also carries unrelated metadata xattrs on
    // some macOS releases (for example screenshot-origin attributes). Copy
    // only the POSIX extended ACL so image metadata cannot hitch a ride.
    errno = 0
    let sourceACL = source.path.withCString { acl_get_file($0, ACL_TYPE_EXTENDED) }
    guard let sourceACL else {
      if errno == ENOENT { return }
      throw MetaShieldError.fileOperationFailed(
        "파일 접근 제어 목록을 읽지 못했습니다: \(String(cString: strerror(errno)))")
    }
    defer { acl_free(UnsafeMutableRawPointer(sourceACL)) }

    let aclResult = destination.path.withCString {
      acl_set_file($0, ACL_TYPE_EXTENDED, sourceACL)
    }
    guard aclResult == 0 else {
      throw MetaShieldError.fileOperationFailed(
        "파일 접근 제어 목록을 보존하지 못했습니다: \(String(cString: strerror(errno)))")
    }
  }

  private func validateInputByteCount(_ byteCount: Int) throws {
    guard byteCount <= maximumInputByteCount else {
      throw MetaShieldError.inputFileTooLarge(
        byteCount: byteCount,
        limit: maximumInputByteCount
      )
    }
  }

  /// Open once with O_NOFOLLOW and decode the exact inode represented by that
  /// descriptor. This closes the validate-then-open symlink race without eagerly
  /// copying an input of up to hundreds of megabytes into heap memory.
  private func mappedInputData(at url: URL) throws -> Data {
    let descriptor = url.path.withCString {
      open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      if errno == ELOOP { throw MetaShieldError.symbolicLinkNotAllowed }
      throw MetaShieldError.fileOperationFailed(String(cString: strerror(errno)))
    }
    defer { close(descriptor) }

    var state = stat()
    guard fstat(descriptor, &state) == 0 else {
      throw MetaShieldError.fileOperationFailed(String(cString: strerror(errno)))
    }
    guard state.st_mode & S_IFMT == S_IFREG else {
      throw MetaShieldError.notARegularFile
    }
    guard state.st_size >= 0, UInt64(state.st_size) <= UInt64(Int.max) else {
      throw MetaShieldError.inputFileTooLarge(byteCount: Int.max, limit: maximumInputByteCount)
    }
    let byteCount = Int(state.st_size)
    try validateInputByteCount(byteCount)
    guard byteCount > 0 else { return Data() }

    let address = mmap(nil, byteCount, PROT_READ, MAP_PRIVATE, descriptor, 0)
    guard address != MAP_FAILED, let address else {
      throw MetaShieldError.fileOperationFailed(
        "입력 파일을 안전하게 매핑하지 못했습니다: \(String(cString: strerror(errno)))")
    }
    return Data(
      bytesNoCopy: address, count: byteCount,
      deallocator: .custom { pointer, count in
        munmap(pointer, count)
      })
  }

  private func synchronizeFile(at url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    try handle.synchronize()
    try handle.close()
  }

  private func writeTemporaryDataSecurely(
    _ data: Data,
    to url: URL,
    permissions: mode_t
  ) throws {
    let descriptor = url.path.withCString {
      open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, permissions)
    }
    guard descriptor >= 0 else {
      throw MetaShieldError.fileOperationFailed(String(cString: strerror(errno)))
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
  }

  private func writeVerifiedCanonicalPNG(
    _ data: Data,
    inspection: PNGInspection,
    to url: URL,
    replaceExisting: Bool
  ) throws {
    let directory = url.deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: directory.path) else {
      throw MetaShieldError.fileOperationFailed("대상 폴더가 없습니다.")
    }
    if !replaceExisting, FileManager.default.fileExists(atPath: url.path) {
      throw MetaShieldError.fileOperationFailed("같은 이름의 파일이 이미 있습니다.")
    }

    let tempURL = directory.appendingPathComponent(".metashield-\(UUID().uuidString).png")
    do {
      try writeTemporaryDataSecurely(data, to: tempURL, permissions: 0o644)
      try synchronizeFile(at: tempURL)
      let reread = try Data(contentsOf: tempURL, options: [.mappedIfSafe])
      let finalInspection = try PNGInspector.verifyCanonical(reread)
      guard finalInspection == inspection, reread == data else {
        throw MetaShieldError.verificationFailed("저장 전후 내용이 달라졌습니다.")
      }

      if replaceExisting {
        try atomicReplace(source: tempURL, destination: url)
      } else {
        let result = tempURL.path.withCString { sourcePath in
          url.path.withCString { destinationPath in
            link(sourcePath, destinationPath)
          }
        }
        guard result == 0 else {
          throw MetaShieldError.fileOperationFailed(String(cString: strerror(errno)))
        }
        try FileManager.default.removeItem(at: tempURL)
      }
    } catch {
      try? FileManager.default.removeItem(at: tempURL)
      throw error
    }
  }

  /// Writes a sanitized AVIF copy, re-reading and re-verifying the bytes that
  /// actually reached disk. AVIF never replaces an original: a lossy copy must
  /// not be able to destroy the source, so the destination must not already
  /// exist.
  private func writeVerifiedAVIF(
    _ data: Data,
    width: Int,
    height: Int,
    to url: URL
  ) throws {
    let directory = url.deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: directory.path) else {
      throw MetaShieldError.fileOperationFailed("대상 폴더가 없습니다.")
    }
    guard !FileManager.default.fileExists(atPath: url.path) else {
      throw MetaShieldError.fileOperationFailed("같은 이름의 파일이 이미 있습니다.")
    }

    let tempURL = directory.appendingPathComponent(".metashield-\(UUID().uuidString).avif")
    do {
      try writeTemporaryDataSecurely(data, to: tempURL, permissions: 0o644)
      try synchronizeFile(at: tempURL)
      // Byte equality, not a decode: opening these bytes with ImageIO here
      // would undo the point of decoding them in the isolated service.
      let reread = try Data(contentsOf: tempURL, options: [.mappedIfSafe])
      guard reread == data else {
        throw MetaShieldError.verificationFailed("저장 전후 내용이 달라졌습니다.")
      }

      let result = tempURL.path.withCString { sourcePath in
        url.path.withCString { destinationPath in
          link(sourcePath, destinationPath)
        }
      }
      guard result == 0 else {
        throw MetaShieldError.fileOperationFailed(String(cString: strerror(errno)))
      }
      try FileManager.default.removeItem(at: tempURL)
    } catch {
      try? FileManager.default.removeItem(at: tempURL)
      throw error
    }
  }

  private func verifyImageDecodes(_ data: Data, expectedWidth: Int, expectedHeight: Int) throws {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) == 1,
      let image = CGImageSourceCreateImageAtIndex(
        source, 0,
        [
          kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary),
      image.width == expectedWidth,
      image.height == expectedHeight,
      image.alphaInfo == .none || image.alphaInfo == .noneSkipFirst
        || image.alphaInfo == .noneSkipLast
    else {
      throw MetaShieldError.verificationFailed("결과 이미지 디코딩 또는 RGB 검사에 실패했습니다.")
    }
  }

  private func atomicReplace(source: URL, destination: URL) throws {
    let result = source.path.withCString { sourcePath in
      destination.path.withCString { destinationPath in
        rename(sourcePath, destinationPath)
      }
    }
    guard result == 0 else {
      let reason = String(cString: strerror(errno))
      throw MetaShieldError.fileOperationFailed(reason)
    }
  }
}
