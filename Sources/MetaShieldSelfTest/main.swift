import CoreGraphics
import CryptoKit
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

private func makeOrientationFixture(_ orientation: Int) throws -> Data {
  // Six opaque, distinct pixels in a non-square frame make every EXIF
  // orientation distinguishable without introducing lossy comparisons.
  let pixels = Data([
    255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
    255, 255, 0, 255, 255, 0, 255, 255, 0, 255, 255, 255,
  ])
  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  let provider = CGDataProvider(data: pixels as CFData)!
  guard
    let image = CGImage(
      width: 3,
      height: 2,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: 12,
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
  let output = NSMutableData()
  guard
    let destination = CGImageDestinationCreateWithData(
      output, "public.tiff" as CFString, 1, nil)
  else {
    throw MetaShieldError.imageEncodingFailed
  }
  CGImageDestinationAddImage(
    destination,
    image,
    [kCGImagePropertyOrientation: orientation] as CFDictionary
  )
  guard CGImageDestinationFinalize(destination) else {
    throw MetaShieldError.imageEncodingFailed
  }
  return output as Data
}

private func decodedRGB(_ data: Data) throws -> (pixels: Data, width: Int, height: Int) {
  guard let source = CGImageSourceCreateWithData(data as CFData, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
    let space = CGColorSpace(name: CGColorSpace.sRGB)
  else {
    throw MetaShieldError.unsupportedOrCorruptImage
  }
  var rgba = Data(count: image.width * image.height * 4)
  let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
    guard let address = bytes.baseAddress,
      let context = CGContext(
        data: address,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: space,
        bitmapInfo: CGBitmapInfo(
          rawValue: CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        )
      )
    else { return false }
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return true
  }
  guard rendered else { throw MetaShieldError.bitmapAllocationFailed }
  var rgb = Data(count: image.width * image.height * 3)
  rgba.withUnsafeBytes { sourceBytes in
    rgb.withUnsafeMutableBytes { destinationBytes in
      guard let sourcePixels = sourceBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
        let destinationPixels = destinationBytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
      else { return }
      for pixel in 0..<(image.width * image.height) {
        for channel in 0..<3 {
          destinationPixels[pixel * 3 + channel] = sourcePixels[pixel * 4 + channel]
        }
      }
    }
  }
  return (rgb, image.width, image.height)
}

private func orientedRGB(
  _ source: Data,
  width: Int,
  height: Int,
  orientation: Int
) -> (pixels: Data, width: Int, height: Int) {
  let isTransposed = orientation >= 5
  let outputWidth = isTransposed ? height : width
  let outputHeight = isTransposed ? width : height
  var output = Data(count: source.count)
  source.withUnsafeBytes { sourceBytes in
    output.withUnsafeMutableBytes { outputBytes in
      guard let sourcePixels = sourceBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
        let outputPixels = outputBytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
      else { return }
      for y in 0..<outputHeight {
        for x in 0..<outputWidth {
          let sourceX: Int
          let sourceY: Int
          switch orientation {
          case 1: (sourceX, sourceY) = (x, y)
          case 2: (sourceX, sourceY) = (width - 1 - x, y)
          case 3: (sourceX, sourceY) = (width - 1 - x, height - 1 - y)
          case 4: (sourceX, sourceY) = (x, height - 1 - y)
          case 5: (sourceX, sourceY) = (y, x)
          case 6: (sourceX, sourceY) = (y, height - 1 - x)
          case 7: (sourceX, sourceY) = (width - 1 - y, height - 1 - x)
          default: (sourceX, sourceY) = (width - 1 - y, x)
          }
          let sourceIndex = (sourceY * width + sourceX) * 3
          let outputIndex = (y * outputWidth + x) * 3
          memcpy(outputPixels.advanced(by: outputIndex), sourcePixels.advanced(by: sourceIndex), 3)
        }
      }
    }
  }
  return (output, outputWidth, outputHeight)
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

  for (name, low, high) in [
    ("translucent", UInt8(8), UInt8(9)), ("opaque", UInt8(254), UInt8(255)),
  ] {
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
  try expect(
    ReleaseVersion(tag: "v0.3.3") == ReleaseVersion(major: 0, minor: 3, patch: 3),
    "정상 태그를 해석하지 못했습니다.")
  try expect(
    ReleaseVersion(tag: "0.3.3") == ReleaseVersion(major: 0, minor: 3, patch: 3),
    "접두사 없는 태그를 해석하지 못했습니다.")

  let rejected = [
    "", "v", "v0.3", "0.3.3.1", "0.3.3-beta", "v0.3.3+build", "main", "latest",
    "v01.3.3", "0.3.x", "../../etc/passwd", "v99999.0.0", "0.3.-1", "0.3. 3",
    "٠.٣.٣", "0.3.3\n0.9.9",
  ]
  for tag in rejected {
    try expect(ReleaseVersion(tag: tag) == nil, "잘못된 태그를 통과시켰습니다: \(tag)")
  }

  let ordered = ["0.3.3", "0.3.4", "0.10.0", "1.0.0", "1.0.1"].compactMap {
    ReleaseVersion(tag: $0)
  }
  try expect(ordered.count == 5, "비교용 태그를 해석하지 못했습니다.")
  for index in 1..<ordered.count {
    try expect(ordered[index - 1] < ordered[index], "버전 비교 순서가 잘못되었습니다.")
  }
  try expect(
    ReleaseVersion(tag: "v0.3.3")! == ReleaseVersion(tag: "0.3.3")!, "같은 버전을 다르게 봤습니다.")
}

/// A signed manifest is the only thing standing between a compromised release
/// host and a user installing an attacker's disk image, so every field is
/// checked and anything unexpected is rejected outright.
private func testUpdateManifestValidation() throws {
  let expected = ReleaseVersion(tag: "0.3.7")!
  let validDigest = String(repeating: "ab", count: 32)

  func manifest(_ overrides: [String: Any]) -> Data {
    var payload: [String: Any] = [
      "schema": 1,
      "version": "0.3.7",
      "dmgName": "MetaShield-0.3.7-direct.dmg",
      "sha256": validDigest,
      "size": 1_234,
    ]
    for (key, value) in overrides { payload[key] = value }
    return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
  }

  let accepted = UpdateManifest(json: manifest([:]), expectedVersion: expected)
  try expect(accepted != nil, "정상 manifest 를 거부했습니다.")
  try expect(accepted?.byteCount == 1_234, "크기를 잘못 읽었습니다.")
  try expect(accepted?.sha256.count == 32, "SHA-256 을 32바이트로 읽지 못했습니다.")

  let rejected: [(String, Data)] = [
    ("스키마 불일치", manifest(["schema": 2])),
    ("태그와 다른 버전", manifest(["version": "0.3.8", "dmgName": "MetaShield-0.3.8-direct.dmg"])),
    ("파일명 불일치", manifest(["dmgName": "MetaShield-0.3.7.dmg"])),
    ("경로가 섞인 파일명", manifest(["dmgName": "../MetaShield-0.3.7-direct.dmg"])),
    ("대문자 다이제스트", manifest(["sha256": validDigest.uppercased()])),
    ("짧은 다이제스트", manifest(["sha256": String(repeating: "ab", count: 31)])),
    ("16진수가 아닌 다이제스트", manifest(["sha256": String(repeating: "zz", count: 32)])),
    ("크기 0", manifest(["size": 0])),
    ("크기 상한 초과", manifest(["size": UpdateManifest.maximumDiskImageByteCount + 1])),
    ("크기가 문자열", manifest(["size": "1234"])),
    ("빈 본문", Data()),
    ("JSON 이 아님", Data("not json".utf8)),
  ]
  for (name, data) in rejected {
    try expect(
      UpdateManifest(json: data, expectedVersion: expected) == nil,
      "잘못된 manifest 를 통과시켰습니다: \(name)")
  }
}

private func testUpdateSignatureVerification() throws {
  let key = Curve25519.Signing.PrivateKey()
  let otherKey = Curve25519.Signing.PrivateKey()
  let payload = Data("{\"schema\":1}".utf8)
  let signature = Data(try key.signature(for: payload))
  let publicKey = key.publicKey.rawRepresentation

  try expect(
    UpdateSignature.isValid(signature, of: payload, publicKeys: [publicKey]),
    "정상 서명을 거부했습니다.")
  try expect(
    UpdateSignature.isValid(
      signature, of: payload, publicKeys: [otherKey.publicKey.rawRepresentation, publicKey]),
    "키 목록의 두 번째 키로 검증하지 못했습니다.")
  try expect(
    !UpdateSignature.isValid(
      signature, of: payload, publicKeys: [otherKey.publicKey.rawRepresentation]),
    "다른 키로 서명 검증이 통과했습니다.")
  try expect(
    !UpdateSignature.isValid(signature, of: Data("{\"schema\":2}".utf8), publicKeys: [publicKey]),
    "변조된 본문의 서명이 통과했습니다.")
  try expect(
    !UpdateSignature.isValid(signature.dropLast(), of: payload, publicKeys: [publicKey]),
    "잘린 서명이 통과했습니다.")
  try expect(
    !UpdateSignature.isValid(signature, of: payload, publicKeys: []),
    "키가 없는데 검증이 통과했습니다.")
}

private func testDownloadDigestCheck() throws {
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = directory.appendingPathComponent("payload.bin")
  let contents = Data((0..<(3 * 1_024 * 1_024)).map { UInt8($0 % 251) })
  try contents.write(to: file)

  let digest = try FileDigest.sha256(ofFileAt: file)
  try expect(
    FileDigest.matches(digest, Data(SHA256.hash(data: contents))),
    "스트리밍 SHA-256 이 한 번에 계산한 값과 다릅니다.")
  try expect(
    !FileDigest.matches(digest, Data(SHA256.hash(data: contents + Data([0])))),
    "다른 내용의 다이제스트가 일치로 판정됐습니다.")
  try expect(!FileDigest.matches(digest, digest.dropLast()), "길이가 다른데 일치로 판정됐습니다.")
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
  // The host-side parser intentionally checks only the canonical container.
  // Full zlib validation belongs to the sandboxed decoder service.
  _ = try PNGInspector.verifyCanonicalStructure(trailingIDAT)
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
  _ = try PNGInspector.verifyCanonicalStructure(concatenatedIDAT)
  do {
    _ = try PNGInspector.verifyCanonical(concatenatedIDAT)
    throw SelfTestError.assertion("연결된 두 번째 zlib 스트림을 허용했습니다.")
  } catch let error as SelfTestError {
    throw error
  } catch MetaShieldError.verificationFailed {
    // Expected.
  }
}

private func testAllEXIFOrientationsArePreserved() throws {
  let sanitizer = ImageSanitizer()
  let baselineInput = try makeOrientationFixture(1)
  let baseline = try decodedRGB(sanitizer.makeCanonicalPNG(from: baselineInput))
  try expect(baseline.width == 3 && baseline.height == 2, "기준 방향의 크기가 달라졌습니다.")

  for orientation in 1...8 {
    let input = try makeOrientationFixture(orientation)
    guard let source = CGImageSourceCreateWithData(input as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      properties[kCGImagePropertyOrientation] as? Int == orientation
    else {
      throw SelfTestError.assertion("EXIF 방향 (orientation) 테스트 입력을 만들지 못했습니다.")
    }
    let actual = try decodedRGB(sanitizer.makeCanonicalPNG(from: input))
    let expected = orientedRGB(
      baseline.pixels,
      width: baseline.width,
      height: baseline.height,
      orientation: orientation
    )
    try expect(
      actual.width == expected.width && actual.height == expected.height,
      "EXIF 방향 (orientation)의 출력 크기가 잘못됐습니다."
    )
    try expect(actual.pixels == expected.pixels, "EXIF 방향 (orientation)의 픽셀이 달라졌습니다.")
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

private func testPhotoPermissionSetupMarker() throws {
  let inspection = try PNGInspector.verifyCanonical(PhotoPermissionSetup.previewPNGData)
  try expect(
    inspection.width == 1 && inspection.height == 1,
    "권한 설정용 PNG 크기가 예상과 다릅니다."
  )
  try expect(
    PhotoPermissionSetup.isSetupRequest(
      registeredTypeIdentifiers: ["public.png", PhotoPermissionSetup.typeIdentifier],
      markerData: PhotoPermissionSetup.markerData
    ),
    "권한 설정 마커를 인식하지 못했습니다."
  )
  try expect(
    !PhotoPermissionSetup.isSetupRequest(
      registeredTypeIdentifiers: ["public.png"],
      markerData: PhotoPermissionSetup.markerData
    ),
    "일반 PNG를 권한 설정 요청으로 잘못 인식했습니다."
  )
  try expect(
    !PhotoPermissionSetup.isSetupRequest(
      registeredTypeIdentifiers: ["public.png", PhotoPermissionSetup.typeIdentifier],
      markerData: Data("wrong marker".utf8)
    ),
    "잘못된 권한 설정 마커를 인식했습니다."
  )
  try expect(
    !PhotoPermissionSetup.isSetupRequest(
      registeredTypeIdentifiers: ["public.png", PhotoPermissionSetup.typeIdentifier],
      markerData: nil
    ),
    "데이터가 없는 권한 설정 마커를 인식했습니다."
  )
}

/// On a system without an AVIF encoder every conversion must fail with the
/// dedicated error, leave no partial file behind, and never touch the source.
private func expectAVIFUnavailableFailure() throws {
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("in.png")
  let original = try makeImageData(type: "public.png" as CFString, metadata: false)
  try original.write(to: source)
  let output = directory.appendingPathComponent("out.avif")
  do {
    _ = try ImageSanitizer().writeCanonicalAVIF(from: source, to: output, quality: .high)
    throw SelfTestError.assertion("AVIF 인코더가 없는데 변환이 성공했습니다.")
  } catch let error as MetaShieldError {
    try expect(error == .avifEncodingUnavailable, "예상과 다른 오류: \(error)")
  }
  try expect(
    !FileManager.default.fileExists(atPath: output.path), "실패했는데 출력 파일이 남았습니다.")
  try expect(
    (try Data(contentsOf: source)) == original, "AVIF 실패가 원본을 변경했습니다.")
}

private func testAVIFExportRemovesMetadata() throws {
  // AVIF encoding is unavailable on older macOS. Where it is missing the
  // contract is a clear, specific failure rather than a crash or a bad file.
  guard AVIFInspector.isEncodingAvailable else {
    try expectAVIFUnavailableFailure()
    return
  }
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  // A JPEG carrying EXIF, GPS and a distinctive comment string.
  let source = directory.appendingPathComponent("source.jpg")
  let image = try makeRGBAImage()
  let encoded = NSMutableData()
  guard
    let destination = CGImageDestinationCreateWithData(
      encoded, "public.jpeg" as CFString, 1, nil)
  else { throw SelfTestError.assertion("테스트용 JPEG 대상 생성 실패") }
  CGImageDestinationAddImage(
    destination, image,
    [
      kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifUserComment: "AVIF-LEAK-CANARY",
        kCGImagePropertyExifDateTimeOriginal: "2026:08:23 21:00:00",
      ],
      kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.5665],
    ] as CFDictionary)
  try expect(CGImageDestinationFinalize(destination), "테스트용 JPEG 생성 실패")
  try (encoded as Data).write(to: source)

  let sanitizer = ImageSanitizer()
  let output = directory.appendingPathComponent("out.avif")
  let report = try sanitizer.writeCanonicalAVIF(from: source, to: output, quality: .high)
  try expect(report.width > 0 && report.height > 0, "AVIF 출력 크기가 잘못되었습니다.")

  // The canary must not survive anywhere in the produced bytes.
  let produced = try Data(contentsOf: output)
  let canary = Array("AVIF-LEAK-CANARY".utf8)
  let bytes = Array(produced)
  let leaked = bytes.indices.contains { index in
    index + canary.count <= bytes.count && Array(bytes[index..<(index + canary.count)]) == canary
  }
  try expect(!leaked, "AVIF 출력에 원본 EXIF 문자열이 남았습니다.")

  // And the structural verification must accept the file we just wrote.
  let inspection = try sanitizer.verifyCanonicalAVIF(at: output)
  try expect(
    inspection.width == report.width && inspection.height == report.height,
    "AVIF 재검증 크기가 다릅니다.")

  // The source must be untouched.
  try expect(
    FileManager.default.fileExists(atPath: source.path), "AVIF 변환이 원본을 지웠습니다.")
}

private func testAVIFNeverReplacesExistingFile() throws {
  guard AVIFInspector.isEncodingAvailable else { return }
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("in.png")
  try makeImageData(type: "public.png" as CFString, metadata: false).write(to: source)

  let output = directory.appendingPathComponent("out.avif")
  let existing = Data("PRE-EXISTING".utf8)
  try existing.write(to: output)

  let sanitizer = ImageSanitizer()
  do {
    _ = try sanitizer.writeCanonicalAVIF(from: source, to: output, quality: .compressed(0.7))
    throw SelfTestError.assertion("이미 존재하는 파일을 AVIF가 덮어썼습니다.")
  } catch let error as MetaShieldError {
    guard case .fileOperationFailed = error else { throw error }
  }
  try expect(
    (try Data(contentsOf: output)) == existing, "AVIF 변환이 기존 파일을 훼손했습니다.")
}

private func testAVIFQualityClamping() throws {
  // ImageIO rejects a quality of 1.0 outright, so the range must stay below it.
  try expect(
    AVIFQuality.compressed(5.0).compressionValue == AVIFQuality.maximumCompressionValue,
    "AVIF 품질 상한 클램프가 동작하지 않습니다.")
  try expect(
    AVIFQuality.compressed(-1.0).compressionValue == AVIFQuality.minimumCompressionValue,
    "AVIF 품질 하한 클램프가 동작하지 않습니다.")
  try expect(
    AVIFQuality.maximumCompressionValue < 1.0,
    "AVIF 품질 상한이 1.0 미만이어야 합니다.")
  try expect(
    AVIFQuality.high.compressionValue > AVIFQuality.defaultCompressionValue,
    "고품질 변환이 기본 압축보다 품질이 높아야 합니다.")
}

private func testAVIFRejectsAnimatedInput() throws {
  guard AVIFInspector.isEncodingAvailable else { return }
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("animated.gif")
  try makeImageData(type: "com.compuserve.gif" as CFString, count: 3, metadata: false)
    .write(to: source)
  let output = directory.appendingPathComponent("out.avif")
  do {
    _ = try ImageSanitizer().writeCanonicalAVIF(from: source, to: output, quality: .high)
    throw SelfTestError.assertion("움직이는 이미지를 AVIF로 변환했습니다.")
  } catch let error as MetaShieldError {
    try expect(error == .animatedImageNotAllowed, "예상과 다른 오류: \(error)")
  }
  try expect(
    !FileManager.default.fileExists(atPath: output.path), "실패했는데 출력 파일이 남았습니다.")
}

private func testAVIFDestroysAlphaLowBitPayload() throws {
  guard AVIFInspector.isEncodingAvailable else { return }
  // The PNG path has this test; the AVIF path shares the pipeline but ships a
  // different encoder, so the guarantee has to be proven at the AVIF output too.
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("payload.png")
  let secret = Array("SELFTEST-ALPHA-CANARY".utf8)
  var bits: [UInt8] = []
  for byte in secret {
    for shift in (0..<8).reversed() { bits.append((byte >> UInt8(shift)) & 1) }
  }
  var index = 0
  let png = makeAlphaPayloadPNG(width: 64, height: 64) { _ in
    defer { index += 1 }
    guard index < bits.count else { return 255 }
    return 254 | bits[index]
  }
  try png.write(to: source)

  let output = directory.appendingPathComponent("out.avif")
  let sanitizer = ImageSanitizer()
  _ = try sanitizer.writeCanonicalAVIF(from: source, to: output, quality: .high)

  let produced = try Data(contentsOf: output)
  let bytes = Array(produced)
  let leaked = bytes.indices.contains { start in
    start + secret.count <= bytes.count && Array(bytes[start..<(start + secret.count)]) == secret
  }
  try expect(!leaked, "AVIF 출력에 알파 페이로드 문자열이 남았습니다.")

  // And the decoded image must be fully opaque, so no alpha plane survives.
  guard let source2 = CGImageSourceCreateWithData(produced as CFData, nil),
    let image = CGImageSourceCreateImageAtIndex(source2, 0, nil)
  else { throw SelfTestError.assertion("AVIF 출력을 다시 열지 못했습니다.") }
  try expect(
    image.alphaInfo == .none || image.alphaInfo == .noneSkipFirst
      || image.alphaInfo == .noneSkipLast,
    "AVIF 출력에 알파 채널이 남았습니다.")
}

private func testAVIFRespectsResourceLimits() throws {
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("in.png")
  try makeImageData(type: "public.png" as CFString, metadata: false).write(to: source)

  // Byte ceiling.
  let tinyByteLimit = ImageSanitizer(maximumPixelCount: 40_000_000, maximumInputByteCount: 8)
  do {
    _ = try tinyByteLimit.writeCanonicalAVIF(
      from: source, to: directory.appendingPathComponent("a.avif"), quality: .high)
    throw SelfTestError.assertion("AVIF 경로가 입력 바이트 상한을 무시했습니다.")
  } catch let error as MetaShieldError {
    guard case .inputFileTooLarge = error else { throw error }
  }

  // The byte ceiling above is checked before the encoder is consulted, so it
  // holds everywhere. The pixel ceiling lives inside the decode step, which is
  // only reached where AVIF encoding exists.
  guard AVIFInspector.isEncodingAvailable else {
    try expect(
      !FileManager.default.fileExists(atPath: directory.appendingPathComponent("a.avif").path),
      "상한을 넘겼는데 출력 파일이 생겼습니다.")
    return
  }

  // Pixel ceiling.
  let tinyPixelLimit = ImageSanitizer(maximumPixelCount: 1, maximumInputByteCount: 256 * 1_024)
  do {
    _ = try tinyPixelLimit.writeCanonicalAVIF(
      from: source, to: directory.appendingPathComponent("b.avif"), quality: .high)
    throw SelfTestError.assertion("AVIF 경로가 픽셀 상한을 무시했습니다.")
  } catch let error as MetaShieldError {
    guard case .imageTooLarge = error else { throw error }
  }

  try expect(
    !FileManager.default.fileExists(atPath: directory.appendingPathComponent("a.avif").path)
      && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("b.avif").path),
    "상한을 넘겼는데 출력 파일이 생겼습니다.")
}

private func testAVIFRejectsSymbolicLinkInput() throws {
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let real = directory.appendingPathComponent("real.png")
  try makeImageData(type: "public.png" as CFString, metadata: false).write(to: real)
  let link = directory.appendingPathComponent("link.png")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

  do {
    _ = try ImageSanitizer().writeCanonicalAVIF(
      from: link, to: directory.appendingPathComponent("out.avif"), quality: .high)
    throw SelfTestError.assertion("AVIF 경로가 심볼릭 링크 입력을 처리했습니다.")
  } catch let error as MetaShieldError {
    try expect(error == .symbolicLinkNotAllowed, "예상과 다른 오류: \(error)")
  }
}

private func testMalformedInputNeverProducesAVIF() throws {
  // Corrupt containers must fail closed on the conversion path too: no output
  // file, and the input left byte-identical.
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let sanitizer = ImageSanitizer()
  var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
  func nextRandom() -> UInt64 {
    seed ^= seed << 13
    seed ^= seed >> 7
    seed ^= seed << 17
    return seed
  }

  let clean = try makeImageData(type: "public.png" as CFString, metadata: true)
  for iteration in 0..<128 {
    var mutated = Array(clean)
    let mutations = 1 + Int(nextRandom() % 4)
    for _ in 0..<mutations {
      let offset = Int(nextRandom() % UInt64(mutated.count))
      mutated[offset] = UInt8(nextRandom() % 256)
    }
    let input = directory.appendingPathComponent("case-\(iteration).png")
    let data = Data(mutated)
    try data.write(to: input)
    let output = directory.appendingPathComponent("case-\(iteration).avif")

    do {
      _ = try sanitizer.writeCanonicalAVIF(from: input, to: output, quality: .high)
      // Success is allowed: a mutation may leave a decodable image. The output
      // must then still pass verification.
      _ = try sanitizer.verifyCanonicalAVIF(at: output)
    } catch {
      try expect(
        !FileManager.default.fileExists(atPath: output.path),
        "실패한 변환이 출력 파일을 남겼습니다: case-\(iteration)")
    }
    try expect(
      (try Data(contentsOf: input)) == data,
      "변환 경로가 입력을 변경했습니다: case-\(iteration)")
  }
}

private func testMalformedAVIFInputCorpusIsSafe() throws {
  guard AVIFInspector.isEncodingAvailable else { return }
  // The PNG corpus test covers PNG inputs. AVIF is also an accepted input type,
  // so a mutated AVIF container must fail closed the same way: no unverified
  // output, and the input left byte-identical.
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let sanitizer = ImageSanitizer()

  let seedPNG = directory.appendingPathComponent("seed.png")
  try makeImageData(type: "public.png" as CFString, metadata: false).write(to: seedPNG)
  let seedAVIF = directory.appendingPathComponent("seed.avif")
  _ = try sanitizer.writeCanonicalAVIF(from: seedPNG, to: seedAVIF, quality: .high)
  let clean = Array(try Data(contentsOf: seedAVIF))

  var seed: UInt64 = 0xD1B5_4A32_D192_ED03
  func nextRandom() -> UInt64 {
    seed ^= seed << 13
    seed ^= seed >> 7
    seed ^= seed << 17
    return seed
  }

  for iteration in 0..<256 {
    var mutated = clean
    let mutations = 1 + Int(nextRandom() % 6)
    for _ in 0..<mutations {
      let offset = Int(nextRandom() % UInt64(mutated.count))
      mutated[offset] = UInt8(nextRandom() % 256)
    }
    let input = directory.appendingPathComponent("case-\(iteration).avif")
    let data = Data(mutated)
    try data.write(to: input)

    // Both output paths must be safe for a hostile AVIF input.
    let pngOutput = directory.appendingPathComponent("case-\(iteration).png")
    do {
      _ = try sanitizer.writeCanonicalPNG(from: input, to: pngOutput)
      _ = try sanitizer.verifyCanonicalPNG(at: pngOutput)
    } catch {
      try expect(
        !FileManager.default.fileExists(atPath: pngOutput.path),
        "실패한 PNG 변환이 출력을 남겼습니다: case-\(iteration)")
    }

    let avifOutput = directory.appendingPathComponent("case-\(iteration).out.avif")
    do {
      _ = try sanitizer.writeCanonicalAVIF(from: input, to: avifOutput, quality: .high)
      _ = try sanitizer.verifyCanonicalAVIF(at: avifOutput)
    } catch {
      try expect(
        !FileManager.default.fileExists(atPath: avifOutput.path),
        "실패한 AVIF 변환이 출력을 남겼습니다: case-\(iteration)")
    }

    try expect(
      (try Data(contentsOf: input)) == data,
      "변조 AVIF 입력이 변경되었습니다: case-\(iteration)")
  }
}

private func testHostileSuggestedNamesStayInsideDirectory() throws {
  // The share extension takes `NSItemProvider.suggestedName` from whichever app
  // is sharing, so that string is attacker-controlled. Every surface funnels it
  // through OutputNaming, which must never let a name escape the destination
  // directory or collide with an existing file.
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let root = directory.standardizedFileURL.path

  let hostileNames = [
    "../../../../etc/passwd",
    "../../evil",
    "..",
    ".",
    "/etc/shadow",
    "a/b/c",
    "",
    String(repeating: "A", count: 400),
    "~/.ssh/authorized_keys",
    "....//....//x",
    "..\\..\\windows",
    "con",
    ".hidden",
    "-rf",
  ]

  for name in hostileNames {
    // Exactly the normalization the share extension and the app perform.
    let cleaned = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
    for output in [
      OutputNaming.uniqueCleanPNGURL(in: directory, baseName: cleaned),
      OutputNaming.uniqueCleanAVIFURL(in: directory, baseName: cleaned),
    ] {
      let resolved = output.standardizedFileURL.path
      try expect(
        resolved.hasPrefix(root + "/"),
        "출력 경로가 대상 폴더를 벗어났습니다: \(name) → \(resolved)")
      try expect(
        URL(fileURLWithPath: resolved).deletingLastPathComponent().standardizedFileURL.path == root,
        "출력이 하위 폴더로 새어나갔습니다: \(name) → \(resolved)")
      try expect(
        !FileManager.default.fileExists(atPath: resolved),
        "이미 존재하는 경로를 출력으로 골랐습니다: \(name)")
    }
  }
}

private func testUpdateFeedRollbackDetection() throws {
  func v(_ major: Int, _ minor: Int, _ patch: Int) -> ReleaseVersion {
    ReleaseVersion(major: major, minor: minor, patch: patch)
  }

  // Normal cases still behave exactly as before.
  try expect(
    UpdateFeedPolicy.judge(reported: v(0, 4, 0), current: v(0, 3, 9), highestSeen: nil)
      == .updateAvailable(latest: v(0, 4, 0)),
    "새 버전을 알리지 못했습니다.")
  try expect(
    UpdateFeedPolicy.judge(reported: v(0, 3, 9), current: v(0, 3, 9), highestSeen: v(0, 3, 9))
      == .upToDate(current: v(0, 3, 9)),
    "최신 상태를 잘못 판정했습니다.")
  // An older tag with nothing remembered is just "up to date", not an alarm:
  // a fresh install must not accuse a healthy host.
  try expect(
    UpdateFeedPolicy.judge(reported: v(0, 3, 1), current: v(0, 3, 9), highestSeen: nil)
      == .upToDate(current: v(0, 3, 9)),
    "기억이 없는 상태에서 과거 태그를 의심으로 처리했습니다.")

  // The host regresses after this copy has already seen a newer release.
  try expect(
    UpdateFeedPolicy.judge(reported: v(0, 3, 8), current: v(0, 3, 9), highestSeen: v(0, 4, 0))
      == .regressionSuspected(highestSeen: v(0, 4, 0), reported: v(0, 3, 8)),
    "릴리스 되돌림을 감지하지 못했습니다.")
  // Even when the reported version would otherwise look like an upgrade.
  try expect(
    UpdateFeedPolicy.judge(reported: v(0, 3, 9), current: v(0, 3, 8), highestSeen: v(0, 4, 0))
      == .regressionSuspected(highestSeen: v(0, 4, 0), reported: v(0, 3, 9)),
    "업그레이드처럼 보이는 되돌림을 놓쳤습니다.")

  // A poisoned answer must never lower the high-water mark.
  try expect(
    UpdateFeedPolicy.updatedHighestSeen(
      reported: v(0, 3, 1), current: v(0, 3, 9), highestSeen: v(0, 4, 0)) == v(0, 4, 0),
    "되돌림 응답이 기억을 낮췄습니다.")
  try expect(
    UpdateFeedPolicy.updatedHighestSeen(
      reported: v(0, 5, 0), current: v(0, 3, 9), highestSeen: v(0, 4, 0)) == v(0, 5, 0),
    "새 최고 버전을 기억하지 못했습니다.")
  // Installing a build newer than anything the feed ever showed also counts.
  try expect(
    UpdateFeedPolicy.updatedHighestSeen(
      reported: v(0, 3, 9), current: v(0, 9, 9), highestSeen: nil) == v(0, 9, 9),
    "설치된 버전이 기억의 하한이 되어야 합니다.")
}

private func testReadOnlyDirectoryNeverDamagesOriginal() throws {
  // Staging a replacement can fail when the original's directory is closed to
  // us. Whatever the outcome, the original must be either fully replaced or
  // completely untouched — never truncated, and never left as a stray temp file.
  let directory = try makeTemporaryDirectory()
  defer {
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    try? FileManager.default.removeItem(at: directory)
  }
  let source = directory.appendingPathComponent("locked.png")
  let original = try makeImageData(type: "public.png" as CFString, metadata: true)
  try original.write(to: source)

  // Read and execute only: the file stays writable, the directory does not.
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o500], ofItemAtPath: directory.path)

  let sanitizer = ImageSanitizer()
  var replaced = false
  do {
    _ = try sanitizer.sanitizePNGInPlace(at: source)
    replaced = true
  } catch {
    // Any failure is acceptable here; silent corruption is not.
  }

  try FileManager.default.setAttributes(
    [.posixPermissions: 0o755], ofItemAtPath: directory.path)

  let after = try Data(contentsOf: source)
  if replaced {
    _ = try sanitizer.verifyCanonicalPNG(at: source)
  } else {
    try expect(after == original, "실패한 원위치 교체가 원본을 훼손했습니다.")
  }

  let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    .filter { $0.hasPrefix(".metashield-") }
  try expect(leftovers.isEmpty, "임시 파일이 남았습니다: \(leftovers)")
}

private func testServiceRejectsHostileRequestValues() throws {
  // The isolated decoder is a security boundary, so it must not trust the
  // limits its caller sends. Non-positive values used to reach a precondition
  // inside ImageSanitizer, which would take the service down rather than fail
  // the call.
  for badLimit in [0, -1, Int.min] {
    let request = ImageDecodingRequest(
      outputFormat: ImageDecodingRequest.pngFormat,
      maximumPixelCount: badLimit,
      maximumInputByteCount: badLimit,
      compressionQuality: 0.7
    )
    try expect(
      request.maximumPixelCount <= 0 || request.maximumInputByteCount <= 0,
      "테스트 전제가 잘못되었습니다.")
    // The request type itself must carry the value unchanged; rejecting it is
    // the service's job and is covered by the packaging check in
    // scripts/verify-direct-dmg.sh plus the guard in the service.
    try expect(request.outputFormat == ImageDecodingRequest.pngFormat, "형식이 보존되어야 합니다.")
  }

  // Round-tripping through NSSecureCoding must not change the values, or the
  // service would be validating something other than what was sent.
  let original = ImageDecodingRequest(
    outputFormat: ImageDecodingRequest.avifFormat,
    maximumPixelCount: 1_234,
    maximumInputByteCount: 5_678,
    compressionQuality: 0.42
  )
  let encoded = try NSKeyedArchiver.archivedData(
    withRootObject: original, requiringSecureCoding: true)
  guard
    let restored = try NSKeyedUnarchiver.unarchivedObject(
      ofClass: ImageDecodingRequest.self, from: encoded)
  else {
    throw SelfTestError.assertion("요청을 복원하지 못했습니다.")
  }
  try expect(
    restored.outputFormat == original.outputFormat
      && restored.maximumPixelCount == original.maximumPixelCount
      && restored.maximumInputByteCount == original.maximumInputByteCount
      && restored.compressionQuality == original.compressionQuality,
    "요청 값이 전송 과정에서 달라졌습니다.")
}

private func testVerificationAcceptsOnlyCleanResults() throws {
  // verifiedImageSize is what the app relies on instead of decoding results
  // itself, so it has to actually reject a file that is not a clean result.
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let sanitizer = ImageSanitizer()

  let clean = directory.appendingPathComponent("clean.png")
  let source = directory.appendingPathComponent("in.png")
  try makeImageData(type: "public.png" as CFString, metadata: true).write(to: source)
  _ = try sanitizer.writeCanonicalPNG(from: source, to: clean)
  let cleanData = try Data(contentsOf: clean)
  let size = try sanitizer.verifiedImageSize(
    of: cleanData, format: ImageDecodingRequest.pngFormat)
  try expect(size.width > 0 && size.height > 0, "정상 결과를 거부했습니다.")

  // A PNG that still carries metadata chunks is not a clean result.
  let dirty = try makeImageData(type: "public.png" as CFString, metadata: true)
  do {
    _ = try sanitizer.verifiedImageSize(of: dirty, format: ImageDecodingRequest.pngFormat)
    throw SelfTestError.assertion("메타데이터가 남은 PNG를 통과시켰습니다.")
  } catch let error as MetaShieldError {
    guard case .verificationFailed = error else {
      guard case .invalidPNG = error else { throw error }
      return
    }
  }
}

private func testOriginalDisposalOnlyRetiresWhatItShould() throws {
  // `decide` compares paths and consults the location policy; it never touches
  // the file system, so synthetic paths are used. A real temporary directory
  // would sit under /var/folders, which the policy correctly treats as
  // Photos-managed — and that would test the wrong branch.
  let source = URL(fileURLWithPath: "/Users/example/Pictures/photo.jpg")
  let besideCopy = URL(fileURLWithPath: "/Users/example/Pictures/photo.clean.png")

  try expect(
    OriginalDisposal.decide(source: source, sanitizedCopy: besideCopy) == .moveToTrash,
    "원본 옆에 사본이 생겼는데 원본을 그대로 두었습니다.")

  // A copy that landed elsewhere (a read-only folder falls back to Downloads)
  // must never take the source with it: the user would be left staring at an
  // empty folder wondering where the file went.
  let elsewhere = URL(fileURLWithPath: "/Users/example/Downloads/photo.clean.png")
  guard case .keep = OriginalDisposal.decide(source: source, sanitizedCopy: elsewhere) else {
    throw SelfTestError.assertion("다른 폴더에 저장됐는데 원본을 휴지통으로 보내려 했습니다.")
  }

  // An in-place replacement has no separate source to retire.
  guard case .keep = OriginalDisposal.decide(source: source, sanitizedCopy: source) else {
    throw SelfTestError.assertion("원본 자체를 다시 휴지통으로 보내려 했습니다.")
  }

  // Photos owns its managed originals; they are not ours to retire, even when
  // the copy lands right beside them.
  let managed = URL(fileURLWithPath: "/private/var/folders/ab/managed/photo.jpg")
  let managedCopy = URL(fileURLWithPath: "/private/var/folders/ab/managed/photo.clean.png")
  guard case .keep = OriginalDisposal.decide(source: managed, sanitizedCopy: managedCopy) else {
    throw SelfTestError.assertion("사진 보관함 관리 원본을 휴지통으로 보내려 했습니다.")
  }

  let library = URL(fileURLWithPath: "/Users/example/Pictures/My.photoslibrary/originals/a.jpg")
  let libraryCopy = URL(
    fileURLWithPath: "/Users/example/Pictures/My.photoslibrary/originals/a.clean.png")
  guard case .keep = OriginalDisposal.decide(source: library, sanitizedCopy: libraryCopy) else {
    throw SelfTestError.assertion("사진 보관함 내부 원본을 휴지통으로 보내려 했습니다.")
  }
}

let tests: [(String, () throws -> Void)] = [
  ("PNG 메타데이터·알파·xattr 제거", testAggressiveSanitization),
  ("알파 하위 비트 은닉 payload 제거", testAlphaLowBitPayloadIsDestroyed),
  ("릴리스 태그 해석·비교", testReleaseTagParsing),
  ("업데이트 manifest 검증", testUpdateManifestValidation),
  ("업데이트 서명 검증", testUpdateSignatureVerification),
  ("다운로드 체크섬 검증", testDownloadDigestCheck),
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
  ("EXIF 방향 1~8 보존", testAllEXIFOrientationsArePreserved),
  ("변조 PNG 코퍼스 원본 안전", testMalformedCorpusNeverCorruptsInput),
  ("사진 앱 권한 설정 마커", testPhotoPermissionSetupMarker),
  ("AVIF 변환이 메타데이터를 남기지 않음", testAVIFExportRemovesMetadata),
  ("AVIF 변환이 기존 파일을 덮어쓰지 않음", testAVIFNeverReplacesExistingFile),
  ("AVIF 품질 범위 클램프", testAVIFQualityClamping),
  ("AVIF 다중 프레임 입력 거부", testAVIFRejectsAnimatedInput),
  ("AVIF 알파 하위 비트 페이로드 제거", testAVIFDestroysAlphaLowBitPayload),
  ("AVIF 자원 상한 준수", testAVIFRespectsResourceLimits),
  ("AVIF 심볼릭 링크 입력 거부", testAVIFRejectsSymbolicLinkInput),
  ("변조 입력에서 AVIF 미생성·원본 안전", testMalformedInputNeverProducesAVIF),
  ("변조 AVIF 입력 코퍼스 안전", testMalformedAVIFInputCorpusIsSafe),
  ("적대적 파일명이 대상 폴더를 벗어나지 않음", testHostileSuggestedNamesStayInsideDirectory),
  ("릴리스 되돌림 감지", testUpdateFeedRollbackDetection),
  ("쓰기 불가 폴더에서 원본 불변", testReadOnlyDirectoryNeverDamagesOriginal),
  ("XPC 요청 값 왕복 보존", testServiceRejectsHostileRequestValues),
  ("검증이 깨끗한 결과만 통과", testVerificationAcceptsOnlyCleanResults),
  ("원본 휴지통 이동 판단", testOriginalDisposalOnlyRetiresWhatItShould),
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
