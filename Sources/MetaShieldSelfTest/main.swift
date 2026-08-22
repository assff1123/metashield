import CoreGraphics
import Foundation
import ImageIO
import MetaShieldCore

private enum SelfTestError: LocalizedError {
  case assertion(String)

  var errorDescription: String? {
    switch self {
    case .assertion(let message): return message
    }
  }
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  guard try condition() else { throw SelfTestError.assertion(message) }
}

private func makeTemporaryDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("MetaShieldTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

private func makeRGBAImage() throws -> CGImage {
  // Premultiplied RGBA. Alpha 254/255 deliberately simulates an alpha-LSB payload.
  let pixels = Data([
    254, 0, 0, 254, 0, 255, 0, 255,
    0, 0, 254, 254, 255, 255, 0, 255,
  ])
  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  let provider = CGDataProvider(data: pixels as CFData)!
  guard
    let image = CGImage(
      width: 2,
      height: 2,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: 8,
      space: space,
      bitmapInfo: CGBitmapInfo(
        rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
      ),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  else {
    throw MetaShieldError.bitmapAllocationFailed
  }
  return image
}

private func makeImageData(type: CFString, count: Int = 1, metadata: Bool) throws -> Data {
  let image = try makeRGBAImage()
  let output = NSMutableData()
  guard let destination = CGImageDestinationCreateWithData(output, type, count, nil) else {
    throw MetaShieldError.imageEncodingFailed
  }
  var properties: CFDictionary?
  if metadata {
    properties =
      [
        kCGImagePropertyPNGDictionary: [
          kCGImagePropertyPNGTitle: "NovelAI secret",
          kCGImagePropertyPNGDescription: "prompt, seed, sampler",
        ],
        kCGImagePropertyExifDictionary: [
          kCGImagePropertyExifUserComment: "private generation settings"
        ],
        kCGImageDestinationLossyCompressionQuality: 0.9,
      ] as CFDictionary
  }
  for _ in 0..<count {
    CGImageDestinationAddImage(destination, image, properties)
  }
  guard CGImageDestinationFinalize(destination) else {
    throw MetaShieldError.imageEncodingFailed
  }
  return output as Data
}

private func runProcess(_ executable: String, arguments: [String], captureOutput: Bool = false)
  throws -> (Int32, Data)
{
  let process = Process()
  let pipe = Pipe()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  if captureOutput { process.standardOutput = pipe }
  try process.run()
  process.waitUntilExit()
  let output = captureOutput ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
  return (process.terminationStatus, output)
}

private func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
  data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

private func uint32BE(_ value: UInt32) -> Data {
  Data([
    UInt8(truncatingIfNeeded: value >> 24),
    UInt8(truncatingIfNeeded: value >> 16),
    UInt8(truncatingIfNeeded: value >> 8),
    UInt8(truncatingIfNeeded: value),
  ])
}

private func testCRC32(_ data: Data) -> UInt32 {
  var crc: UInt32 = 0xFFFF_FFFF
  for byte in data {
    crc ^= UInt32(byte)
    for _ in 0..<8 {
      crc = (crc & 1) == 1 ? (0xEDB8_8320 ^ (crc >> 1)) : (crc >> 1)
    }
  }
  return crc ^ 0xFFFF_FFFF
}

private func appendingPayload(_ extra: Data, toChunk target: String, in png: Data) throws -> Data {
  var offset = 8
  while offset + 12 <= png.count {
    let length = Int(readUInt32BE(png, at: offset))
    let typeRange = (offset + 4)..<(offset + 8)
    let payloadRange = (offset + 8)..<(offset + 8 + length)
    let chunkEnd = offset + 12 + length
    guard chunkEnd <= png.count else { break }
    let type = String(data: png[typeRange], encoding: .ascii)
    if type == target {
      let typeData = Data(png[typeRange])
      var payload = Data(png[payloadRange])
      payload.append(extra)
      var altered = Data(png[..<offset])
      altered.append(uint32BE(UInt32(payload.count)))
      altered.append(typeData)
      altered.append(payload)
      var crcInput = typeData
      crcInput.append(payload)
      altered.append(uint32BE(testCRC32(crcInput)))
      altered.append(png[chunkEnd...])
      return altered
    }
    offset = chunkEnd
  }
  throw SelfTestError.assertion("\(target) 테스트 청크를 찾지 못했습니다.")
}

private func payload(ofChunk target: String, in png: Data) throws -> Data {
  var offset = 8
  while offset + 12 <= png.count {
    let length = Int(readUInt32BE(png, at: offset))
    let typeRange = (offset + 4)..<(offset + 8)
    let payloadRange = (offset + 8)..<(offset + 8 + length)
    let chunkEnd = offset + 12 + length
    guard chunkEnd <= png.count else { break }
    if String(data: png[typeRange], encoding: .ascii) == target {
      return Data(png[payloadRange])
    }
    offset = chunkEnd
  }
  throw SelfTestError.assertion("\(target) 테스트 청크를 찾지 못했습니다.")
}

private func testAggressiveSanitization() throws {
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = directory.appendingPathComponent("novelai-secret.png")
  let original = try makeImageData(type: "public.png" as CFString, metadata: true)
  try original.write(to: file)

  let before = try PNGInspector.inspect(original)
  try expect(before.hasAlpha, "입력 PNG에 알파가 생성되지 않았습니다.")
  try expect(
    before.chunkTypes.contains(where: { !["IHDR", "IDAT", "IEND"].contains($0) }),
    "입력 PNG에 테스트 메타데이터 청크가 없습니다.")

  let setXattr = try runProcess(
    "/usr/bin/xattr", arguments: ["-w", "com.metashield.test", "secret", file.path])
  try expect(setXattr.0 == 0, "테스트 xattr를 설정하지 못했습니다.")
  let setScreenshotXattr = try runProcess(
    "/usr/bin/xattr",
    arguments: ["-w", "com.apple.metadata:kMDItemIsScreenCapture", "screenshot-origin", file.path]
  )
  try expect(setScreenshotXattr.0 == 0, "스크린샷 메타데이터 xattr를 설정하지 못했습니다.")

  _ = try ImageSanitizer().sanitizePNGInPlace(at: file)
  let cleaned = try Data(contentsOf: file)
  let after = try PNGInspector.verifyCanonical(cleaned)
  try expect(after.colorType == 2 && after.bitDepth == 8, "결과가 8-bit RGB가 아닙니다.")
  try expect(!after.hasAlpha, "알파 채널이 남았습니다.")
  try expect(Set(after.chunkTypes) == Set(["IHDR", "IDAT", "IEND"]), "부가 청크가 남았습니다.")

  let xattrs = try runProcess("/usr/bin/xattr", arguments: [file.path], captureOutput: true)
  let remainingXattrs = String(decoding: xattrs.1, as: UTF8.self)
    .split(whereSeparator: \.isNewline)
    .map(String.init)
  // macOS can immediately attach protected provenance or MAC/TCC markers to a
  // newly created file. They are OS security state, not copied image metadata.
  let systemManagedXattrs = Set(["com.apple.provenance", "com.apple.macl"])
  try expect(
    xattrs.0 == 0 && remainingXattrs.allSatisfy { systemManagedXattrs.contains($0) },
    "입력에서 복사된 확장 속성이 남았습니다: \(remainingXattrs.joined(separator: ", "))"
  )
}

private func adler32(_ data: Data) -> UInt32 {
  var a: UInt32 = 1
  var b: UInt32 = 0
  for byte in data {
    a = (a + UInt32(byte)) % 65521
    b = (b + a) % 65521
  }
  return (b << 16) | a
}

/// Deflate "stored" blocks so the test can build byte-exact PNG inputs without
/// linking a compressor into the self-test.
private func storedDeflate(_ data: Data) -> Data {
  var output = Data([0x78, 0x01])
  var offset = 0
  repeat {
    let count = min(65_535, data.count - offset)
    let isFinal = offset + count >= data.count
    output.append(isFinal ? 1 : 0)
    output.append(UInt8(truncatingIfNeeded: count))
    output.append(UInt8(truncatingIfNeeded: count >> 8))
    output.append(UInt8(truncatingIfNeeded: ~count))
    output.append(UInt8(truncatingIfNeeded: ~count >> 8))
    output.append(data[offset..<(offset + count)])
    offset += count
  } while offset < data.count
  output.append(contentsOf: uint32BE(adler32(data)))
  return output
}

private func makePNGChunk(_ type: String, _ payload: Data) -> Data {
  var body = Data(type.utf8)
  body.append(payload)
  var chunk = uint32BE(UInt32(payload.count))
  chunk.append(body)
  chunk.append(uint32BE(testCRC32(body)))
  return chunk
}

/// Builds an RGBA PNG whose only per-pixel variation is the alpha low bit.
private func makeAlphaPayloadPNG(width: Int, height: Int, alphaForPixel: (Int) -> UInt8) -> Data {
  var raw = Data()
  for y in 0..<height {
    raw.append(0)
    for x in 0..<width {
      raw.append(contentsOf: [123, 200, 77, alphaForPixel(y * width + x)])
    }
  }
  var header = Data()
  header.append(uint32BE(UInt32(width)))
  header.append(uint32BE(UInt32(height)))
  header.append(contentsOf: [8, 6, 0, 0, 0])

  var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
  png.append(makePNGChunk("IHDR", header))
  png.append(makePNGChunk("IDAT", storedDeflate(raw)))
  png.append(makePNGChunk("IEND", Data()))
  return png
}

/// An alpha-LSB payload must not survive as +/-1 noise in the composited RGB
/// output. Images that differ only inside one alpha quantization bucket have to
/// produce byte-identical canonical PNGs.
private func testAlphaLowBitPayloadIsDestroyed() throws {
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let payload = Array("METASHIELD".utf8).flatMap { byte in
    (0..<8).map { UInt8((byte >> (7 - $0)) & 1) }
  }

  for (name, low, high) in [("translucent", UInt8(8), UInt8(9)), ("opaque", UInt8(254), UInt8(255))]
  {
    let sanitized = try [
      makeAlphaPayloadPNG(width: 64, height: 64) { _ in low },
      makeAlphaPayloadPNG(width: 64, height: 64) { _ in high },
      makeAlphaPayloadPNG(width: 64, height: 64) { index in
        index < payload.count ? (payload[index] == 1 ? high : low) : high
      },
    ].enumerated().map { index, data -> Data in
      let file = directory.appendingPathComponent("\(name)-\(index).png")
      try data.write(to: file)
      _ = try ImageSanitizer().sanitizePNGInPlace(at: file)
      return try Data(contentsOf: file)
    }

    try expect(
      sanitized[0] == sanitized[1] && sanitized[1] == sanitized[2],
      "알파 하위 비트가 \(name) 구간의 출력 픽셀에 남았습니다.")
  }
}

/// The update check consumes exactly one string from the network. Anything that
/// is not a plain major.minor.patch number must be rejected before use.
private func testReleaseTagParsing() throws {
  try expect(ReleaseVersion(tag: "v0.3.3") == ReleaseVersion(major: 0, minor: 3, patch: 3),
    "정상 태그를 해석하지 못했습니다.")
  try expect(ReleaseVersion(tag: "0.3.3") == ReleaseVersion(major: 0, minor: 3, patch: 3),
    "접두사 없는 태그를 해석하지 못했습니다.")

  let rejected = [
    "", "v", "v0.3", "0.3.3.1", "0.3.3-beta", "v0.3.3+build", "main", "latest",
    "v01.3.3", "0.3.x", "../../etc/passwd", "v99999.0.0", "0.3.-1", "0.3. 3",
    "٠.٣.٣", "0.3.3\n0.9.9",
  ]
  for tag in rejected {
    try expect(ReleaseVersion(tag: tag) == nil, "잘못된 태그를 통과시켰습니다: \(tag)")
  }

  let ordered = ["0.3.3", "0.3.4", "0.10.0", "1.0.0", "1.0.1"].compactMap { ReleaseVersion(tag: $0) }
  try expect(ordered.count == 5, "비교용 태그를 해석하지 못했습니다.")
  for index in 1..<ordered.count {
    try expect(ordered[index - 1] < ordered[index], "버전 비교 순서가 잘못되었습니다.")
  }
  try expect(
    ReleaseVersion(tag: "v0.3.3")! == ReleaseVersion(tag: "0.3.3")!, "같은 버전을 다르게 봤습니다.")
}

private func testFilePermissionsArePreserved() throws {
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = directory.appendingPathComponent("private.png")
  try makeImageData(type: "public.png" as CFString, metadata: true).write(to: file)
  try expect(chmod(file.path, 0o600) == 0, "테스트 파일 권한을 설정하지 못했습니다.")
  let addACL = try runProcess(
    "/bin/chmod",
    arguments: ["+a", "everyone allow readattr", file.path]
  )
  try expect(addACL.0 == 0, "테스트 ACL을 설정하지 못했습니다.")

  _ = try ImageSanitizer().sanitizePNGInPlace(at: file)
  var state = stat()
  try expect(lstat(file.path, &state) == 0, "정리된 파일 정보를 읽지 못했습니다.")
  try expect(state.st_mode & 0o7777 == 0o600, "원본의 0600 접근 권한이 보존되지 않았습니다.")
  let aclListing = try runProcess("/bin/ls", arguments: ["-lde", file.path], captureOutput: true)
  let aclText = String(decoding: aclListing.1, as: UTF8.self)
  try expect(
    aclListing.0 == 0 && aclText.contains("everyone allow readattr"),
    "원본 ACL이 보존되지 않았습니다."
  )
}

private func testCorruptInputIsUntouched() throws {
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = directory.appendingPathComponent("broken.png")
  let original = Data("not a png".utf8)
  try original.write(to: file)
  do {
    _ = try ImageSanitizer().sanitizePNGInPlace(at: file)
    throw SelfTestError.assertion("손상된 입력을 성공으로 처리했습니다.")
  } catch let selfTestError as SelfTestError {
    throw selfTestError
  } catch MetaShieldError.unsupportedOrCorruptImage {
    try expect(try Data(contentsOf: file) == original, "실패한 입력의 원본이 변경됐습니다.")
  } catch {
    throw SelfTestError.assertion("손상된 입력 오류가 부정확합니다: \(error.localizedDescription)")
  }
}

private func testJPEGExport() throws {
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let input = directory.appendingPathComponent("photo.jpg")
  let output = directory.appendingPathComponent("photo.clean.png")
  try makeImageData(type: "public.jpeg" as CFString, metadata: true).write(to: input)

  _ = try ImageSanitizer().writeCanonicalPNG(from: input, to: output)
  _ = try ImageSanitizer().verifyCanonicalPNG(at: output)
  try expect(FileManager.default.fileExists(atPath: input.path), "비-PNG 원본이 삭제됐습니다.")
}

private func testAnimatedInputIsRejected() throws {
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let input = directory.appendingPathComponent("animated.gif")
  try makeImageData(type: "com.compuserve.gif" as CFString, count: 2, metadata: false).write(
    to: input)
  do {
    _ = try ImageSanitizer().makeCanonicalPNG(from: input)
    throw SelfTestError.assertion("움직이는 이미지를 단일 프레임으로 처리했습니다.")
  } catch MetaShieldError.animatedImageNotAllowed {
    return
  }
}

private func testTemporaryInputIsNeverReplacedInPlace() throws {
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = directory.appendingPathComponent("Photos Managed Input.png")
  try makeImageData(type: "public.png" as CFString, metadata: true).write(to: file)

  try expect(ImageInputLocationPolicy.isTemporary(file), "임시 파일을 임시 경로로 판정하지 못했습니다.")
  try expect(
    !ImageInputLocationPolicy.canReplaceInPlace(file),
    "사진 앱 임시 파일을 원본 교체 대상으로 판정했습니다."
  )

  let path = file.path
  let aliasedPath: String
  if path.hasPrefix("/private/var/") {
    aliasedPath = String(path.dropFirst("/private".count))
  } else if path.hasPrefix("/var/") {
    aliasedPath = "/private" + path
  } else {
    aliasedPath = path
  }
  try expect(
    ImageInputLocationPolicy.isTemporary(URL(fileURLWithPath: aliasedPath)),
    "/var와 /private/var 별칭을 같은 임시 경로로 판정하지 못했습니다."
  )

  let photosEditPath = URL(
    fileURLWithPath:
      "/private/var/folders/zz/metashield-test/0/01BAABEF-02F5-4F9C-AEF8-98E19A0743DD/이미지.png"
  )
  try expect(
    ImageInputLocationPolicy.shouldImportIntoPhotos(photosEditPath),
    "사진 앱의 /var/folders/.../0 편집 경로를 사진 관리 입력으로 판정하지 못했습니다."
  )
  try expect(
    !ImageInputLocationPolicy.canReplaceInPlace(photosEditPath),
    "사진 앱의 읽기 전용 편집 경로를 원본 교체 대상으로 판정했습니다."
  )

  let libraryPath = URL(
    fileURLWithPath: "/Users/test/Pictures/System.photoslibrary/originals/0/image.png"
  )
  try expect(
    ImageInputLocationPolicy.isPhotosManaged(libraryPath),
    "사진 보관함 내부 원본을 사진 관리 입력으로 판정하지 못했습니다."
  )
  try expect(
    !ImageInputLocationPolicy.canReplaceInPlace(libraryPath),
    "사진 보관함 내부 원본을 원본 교체 대상으로 판정했습니다."
  )
}

private func testInputByteLimit() throws {
  let sanitizer = ImageSanitizer(maximumPixelCount: 100, maximumInputByteCount: 8)
  let oversized = Data(repeating: 0, count: 9)
  do {
    _ = try sanitizer.makeCanonicalPNG(from: oversized)
    throw SelfTestError.assertion("입력 바이트 상한을 초과한 데이터를 처리했습니다.")
  } catch let selfTestError as SelfTestError {
    throw selfTestError
  } catch MetaShieldError.inputFileTooLarge(byteCount: 9, limit: 8) {
    return
  }
}

private func testPixelLimit() throws {
  let data = try makeImageData(type: "public.png" as CFString, metadata: false)
  let sanitizer = ImageSanitizer(maximumPixelCount: 3)
  do {
    _ = try sanitizer.makeCanonicalPNG(from: data)
    throw SelfTestError.assertion("픽셀 상한을 초과한 이미지를 처리했습니다.")
  } catch let selfTestError as SelfTestError {
    throw selfTestError
  } catch MetaShieldError.imageTooLarge(width: 2, height: 2) {
    return
  }
}

private func testSymbolicLinkIsRejected() throws {
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let original = directory.appendingPathComponent("original.png")
  let symbolicLink = directory.appendingPathComponent("alias.png")
  try makeImageData(type: "public.png" as CFString, metadata: true).write(to: original)
  try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: original)

  do {
    _ = try ImageSanitizer().sanitizePNGInPlace(at: symbolicLink)
    throw SelfTestError.assertion("심볼릭 링크를 원본 교체 대상으로 처리했습니다.")
  } catch let selfTestError as SelfTestError {
    throw selfTestError
  } catch MetaShieldError.symbolicLinkNotAllowed {
    return
  }
}

private func testHardLinkIsNotReplacedInPlace() throws {
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let original = directory.appendingPathComponent("original.png")
  let hardLink = directory.appendingPathComponent("hard-link.png")
  let originalData = try makeImageData(type: "public.png" as CFString, metadata: true)
  try originalData.write(to: original)
  try FileManager.default.linkItem(at: original, to: hardLink)

  try expect(!ImageInputLocationPolicy.canReplaceInPlace(original), "하드 링크 입력을 원본 교체 대상으로 판정했습니다.")
  do {
    _ = try ImageSanitizer().sanitizePNGInPlace(at: original)
    throw SelfTestError.assertion("하드 링크 원본을 영구 교체했습니다.")
  } catch let selfTestError as SelfTestError {
    throw selfTestError
  } catch MetaShieldError.hardLinkedFileNotAllowed {
    try expect(try Data(contentsOf: original) == originalData, "거부한 하드 링크 원본이 변경됐습니다.")
  }
}

private func testExistingDestinationIsPreserved() throws {
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let input = directory.appendingPathComponent("입력 ' 특수문자.jpg")
  let output = directory.appendingPathComponent("이미 있음.clean.png")
  let sentinel = Data("keep me".utf8)
  try makeImageData(type: "public.jpeg" as CFString, metadata: true).write(to: input)
  try sentinel.write(to: output)

  do {
    _ = try ImageSanitizer().writeCanonicalPNG(from: input, to: output)
    throw SelfTestError.assertion("기존 출력 파일을 덮어썼습니다.")
  } catch let selfTestError as SelfTestError {
    throw selfTestError
  } catch MetaShieldError.fileOperationFailed {
    try expect(try Data(contentsOf: output) == sentinel, "기존 출력 파일 내용이 변경됐습니다.")
  }
}

private func testTrailingPNGDataIsRejected() throws {
  var data = try makeImageData(type: "public.png" as CFString, metadata: false)
  data.append(contentsOf: [0x53, 0x45, 0x43, 0x52, 0x45, 0x54])
  do {
    _ = try PNGInspector.inspect(data)
    throw SelfTestError.assertion("IEND 뒤의 숨은 데이터를 허용했습니다.")
  } catch let selfTestError as SelfTestError {
    throw selfTestError
  } catch MetaShieldError.invalidPNG {
    return
  }
}

private func testHiddenChunkPayloadsAreRejected() throws {
  let canonical = try ImageSanitizer().makeCanonicalPNG(
    from: makeImageData(type: "public.png" as CFString, metadata: false)
  )

  let nonEmptyIEND = try appendingPayload(Data("SECRET".utf8), toChunk: "IEND", in: canonical)
  do {
    _ = try PNGInspector.verifyCanonical(nonEmptyIEND)
    throw SelfTestError.assertion("비어 있지 않은 IEND 청크를 허용했습니다.")
  } catch let error as SelfTestError {
    throw error
  } catch MetaShieldError.verificationFailed {
    // Expected.
  }

  let trailingIDAT = try appendingPayload(Data("SECRET".utf8), toChunk: "IDAT", in: canonical)
  do {
    _ = try PNGInspector.verifyCanonical(trailingIDAT)
    throw SelfTestError.assertion("zlib 스트림 뒤의 IDAT 데이터를 허용했습니다.")
  } catch let error as SelfTestError {
    throw error
  } catch MetaShieldError.verificationFailed {
    // Expected.
  }

  let originalStream = try payload(ofChunk: "IDAT", in: canonical)
  let concatenatedIDAT = try appendingPayload(originalStream, toChunk: "IDAT", in: canonical)
  do {
    _ = try PNGInspector.verifyCanonical(concatenatedIDAT)
    throw SelfTestError.assertion("연결된 두 번째 zlib 스트림을 허용했습니다.")
  } catch let error as SelfTestError {
    throw error
  } catch MetaShieldError.verificationFailed {
    // Expected.
  }
}

private func testMalformedCorpusNeverCorruptsInput() throws {
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let seedImage = try makeImageData(type: "public.png" as CFString, metadata: true)
  var state: UInt64 = 0x4D_65_74_61_53_68_69_65

  func nextRandom() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }

  for index in 0..<1_024 {
    var mutated = seedImage
    switch index % 4 {
    case 0:
      let keep = Int(nextRandom() % UInt64(max(1, mutated.count)))
      mutated = mutated.prefix(keep)
    case 1:
      let changes = 1 + Int(nextRandom() % 8)
      for _ in 0..<changes where !mutated.isEmpty {
        let position = Int(nextRandom() % UInt64(mutated.count))
        mutated[position] ^= UInt8(truncatingIfNeeded: nextRandom())
      }
    case 2:
      mutated.append(contentsOf: withUnsafeBytes(of: nextRandom().bigEndian, Array.init))
    default:
      if mutated.count >= 16 {
        mutated.replaceSubrange(8..<12, with: [0x7F, 0xFF, 0xFF, 0xFF])
      }
    }

    let file = directory.appendingPathComponent("mutated-\(index).png")
    try mutated.write(to: file)
    do {
      _ = try ImageSanitizer().sanitizePNGInPlace(at: file)
      _ = try ImageSanitizer().verifyCanonicalPNG(at: file)
    } catch {
      try expect(
        try Data(contentsOf: file) == mutated,
        "변조 입력 \(index)가 실패 중 변경됐습니다."
      )
    }
  }
}

let tests: [(String, () throws -> Void)] = [
  ("PNG 메타데이터·알파·xattr 제거", testAggressiveSanitization),
  ("알파 하위 비트 은닉 payload 제거", testAlphaLowBitPayloadIsDestroyed),
  ("릴리스 태그 해석·비교", testReleaseTagParsing),
  ("원본 파일 접근 권한 보존", testFilePermissionsArePreserved),
  ("실패 시 원본 보존", testCorruptInputIsUntouched),
  ("JPEG에서 깨끗한 PNG 사본 생성", testJPEGExport),
  ("다중 프레임 입력 거부", testAnimatedInputIsRejected),
  ("사진 앱 임시 경로 원본 교체 금지", testTemporaryInputIsNeverReplacedInPlace),
  ("입력 바이트 상한", testInputByteLimit),
  ("픽셀 상한", testPixelLimit),
  ("심볼릭 링크 거부", testSymbolicLinkIsRejected),
  ("하드 링크 원본 교체 거부", testHardLinkIsNotReplacedInPlace),
  ("기존 출력 파일 보존", testExistingDestinationIsPreserved),
  ("PNG 꼬리 데이터 거부", testTrailingPNGDataIsRejected),
  ("IEND·IDAT 숨은 페이로드 거부", testHiddenChunkPayloadsAreRejected),
  ("변조 PNG 코퍼스 원본 안전", testMalformedCorpusNeverCorruptsInput),
]

do {
  for (name, test) in tests {
    try test()
    print("PASS  \(name)")
  }
  print("모든 자체 테스트 통과 (\(tests.count)/\(tests.count))")
} catch {
  fputs("FAIL  \(error.localizedDescription)\n", stderr)
  exit(1)
}
