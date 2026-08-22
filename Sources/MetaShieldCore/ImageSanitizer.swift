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

  public init(
    maximumPixelCount: Int = 40_000_000,
    maximumInputByteCount: Int = 256 * 1_024 * 1_024
  ) {
    precondition(maximumPixelCount > 0)
    precondition(maximumInputByteCount > 0)
    self.maximumPixelCount = maximumPixelCount
    self.maximumInputByteCount = maximumInputByteCount
  }

  public func makeCanonicalPNG(from sourceData: Data) throws -> Data {
    try validateInputByteCount(sourceData.count)
    guard
      let source = CGImageSourceCreateWithData(
        sourceData as CFData,
        [
          kCGImageSourceShouldCache: false
        ] as CFDictionary)
    else {
      throw MetaShieldError.unsupportedOrCorruptImage
    }
    return try makeCanonicalPNG(from: source)
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

    let directory = standardizedURL.deletingLastPathComponent()
    let tempURL = directory.appendingPathComponent(".metashield-\(UUID().uuidString).png")

    do {
      try writeTemporaryDataSecurely(canonical, to: tempURL, permissions: 0o600)
      try synchronizeFile(at: tempURL)
      let reread = try Data(contentsOf: tempURL, options: [.mappedIfSafe])
      let finalInspection = try PNGInspector.verifyCanonical(reread)
      guard finalInspection == inspection else {
        throw MetaShieldError.verificationFailed("저장 전후 구조가 달라졌습니다.")
      }
      try verifyImageDecodes(
        reread, expectedWidth: inspection.width, expectedHeight: inspection.height)
      try verifyUnchanged(originalFileState, at: standardizedURL)
      try applySecurityAttributes(
        from: standardizedURL,
        originalState: originalFileState,
        to: tempURL
      )
      try verifyUnchanged(originalFileState, at: standardizedURL)
      try atomicReplace(source: tempURL, destination: standardizedURL)

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

  public func verifyCanonicalPNG(at url: URL) throws -> PNGInspection {
    let data = try mappedInputData(at: url.standardizedFileURL)
    let inspection = try PNGInspector.verifyCanonical(data)
    try verifyImageDecodes(data, expectedWidth: inspection.width, expectedHeight: inspection.height)
    return inspection
  }

  private func makeCanonicalPNG(from source: CGImageSource) throws -> Data {
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

    let mutableData = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        mutableData,
        "public.png" as CFString,
        1,
        nil
      )
    else {
      throw MetaShieldError.imageEncodingFailed
    }
    CGImageDestinationAddImage(destination, cleanImage, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw MetaShieldError.imageEncodingFailed
    }

    return try PNGInspector.canonicalData(from: mutableData as Data)
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
      guard finalInspection == inspection else {
        throw MetaShieldError.verificationFailed("저장 전후 구조가 달라졌습니다.")
      }
      try verifyImageDecodes(
        reread, expectedWidth: inspection.width, expectedHeight: inspection.height)

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
