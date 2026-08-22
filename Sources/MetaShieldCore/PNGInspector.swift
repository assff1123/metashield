import Foundation
import zlib

public struct PNGInspection: Equatable, Sendable {
  public let width: Int
  public let height: Int
  public let bitDepth: UInt8
  public let colorType: UInt8
  public let chunkTypes: [String]

  public var hasAlpha: Bool {
    colorType == 4 || colorType == 6
  }
}

public enum PNGInspector {
  private static let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])

  private struct ParsedChunk {
    let type: String
    let completeRange: Range<Int>
    let payloadRange: Range<Int>
  }

  public static func inspect(_ data: Data) throws -> PNGInspection {
    let chunks = try parse(data)
    guard let first = chunks.first, first.type == "IHDR" else {
      throw MetaShieldError.invalidPNG("IHDR이 첫 청크가 아닙니다.")
    }
    let ihdr = data[first.payloadRange]
    guard ihdr.count == 13 else {
      throw MetaShieldError.invalidPNG("IHDR 길이가 13바이트가 아닙니다.")
    }

    let bytes = Array(ihdr)
    let width = Int(readUInt32BE(bytes, at: 0))
    let height = Int(readUInt32BE(bytes, at: 4))
    guard width > 0, height > 0 else {
      throw MetaShieldError.invalidPNG("가로 또는 세로 크기가 0입니다.")
    }

    return PNGInspection(
      width: width,
      height: height,
      bitDepth: bytes[8],
      colorType: bytes[9],
      chunkTypes: chunks.map(\.type)
    )
  }

  public static func canonicalData(from encodedPNG: Data) throws -> Data {
    let chunks = try parse(encodedPNG)
    guard let first = chunks.first, first.type == "IHDR" else {
      throw MetaShieldError.invalidPNG("IHDR이 첫 청크가 아닙니다.")
    }

    var result = signature
    let idatChunks = chunks.filter { $0.type == "IDAT" }
    guard !idatChunks.isEmpty, chunks.contains(where: { $0.type == "IEND" }) else {
      throw MetaShieldError.invalidPNG("필수 IDAT 또는 IEND 청크가 없습니다.")
    }

    // ImageIO can split large compressed streams across multiple IDAT chunks.
    // Merge their payloads into one newly checksummed chunk so the canonical
    // output has an unambiguous structure at every image size.
    var compressedStream = Data()
    for chunk in idatChunks {
      compressedStream.append(encodedPNG[chunk.payloadRange])
    }
    try appendChunk(type: "IHDR", payload: Data(encodedPNG[first.payloadRange]), to: &result)
    try appendChunk(type: "IDAT", payload: compressedStream, to: &result)
    try appendChunk(type: "IEND", payload: Data(), to: &result)

    _ = try verifyCanonical(result)
    return result
  }

  @discardableResult
  public static func verifyCanonical(_ data: Data) throws -> PNGInspection {
    let chunks = try parse(data)
    let inspection = try inspect(data)
    let types = inspection.chunkTypes
    guard types.first == "IHDR", types.last == "IEND" else {
      throw MetaShieldError.verificationFailed("필수 청크 순서가 잘못되었습니다.")
    }
    guard types.filter({ $0 == "IHDR" }).count == 1,
      types.filter({ $0 == "IEND" }).count == 1,
      types.filter({ $0 == "IDAT" }).count == 1
    else {
      throw MetaShieldError.verificationFailed("필수 청크 개수가 잘못되었습니다.")
    }
    guard types.allSatisfy({ $0 == "IHDR" || $0 == "IDAT" || $0 == "IEND" }) else {
      throw MetaShieldError.verificationFailed("허용되지 않은 PNG 청크가 있습니다.")
    }
    guard inspection.bitDepth == 8, inspection.colorType == 2 else {
      throw MetaShieldError.verificationFailed(
        "8-bit RGB가 아닙니다 (bitDepth=\(inspection.bitDepth), colorType=\(inspection.colorType))."
      )
    }

    guard let ihdrChunk = chunks.first,
      let iendChunk = chunks.last,
      iendChunk.payloadRange.isEmpty
    else {
      throw MetaShieldError.verificationFailed("IEND 청크가 비어 있지 않습니다.")
    }
    let ihdr = Array(data[ihdrChunk.payloadRange])
    guard ihdr.count == 13,
      ihdr[10] == 0,
      ihdr[11] == 0,
      ihdr[12] == 0
    else {
      throw MetaShieldError.verificationFailed("비표준 압축·필터·인터레이스 방식입니다.")
    }

    guard let idatChunk = chunks.first(where: { $0.type == "IDAT" }) else {
      throw MetaShieldError.verificationFailed("IDAT 청크가 없습니다.")
    }
    try validateCanonicalPixelStream(
      Data(data[idatChunk.payloadRange]),
      width: inspection.width,
      height: inspection.height
    )
    return inspection
  }

  /// A decoder accepting a PNG does not prove that every IDAT byte belongs to
  /// the image. Validate the zlib end marker, exact scanline length, and filter
  /// bytes so trailing payloads and concatenated streams cannot pass as clean.
  private static func validateCanonicalPixelStream(
    _ compressed: Data,
    width: Int,
    height: Int
  ) throws {
    guard width <= (Int.max - 1) / 3 else {
      throw MetaShieldError.verificationFailed("스캔라인 크기가 너무 큽니다.")
    }
    let rowByteCount = width * 3 + 1
    guard height <= Int.max / rowByteCount else {
      throw MetaShieldError.verificationFailed("픽셀 데이터 크기가 너무 큽니다.")
    }
    let expectedByteCount = rowByteCount * height
    var output = [UInt8](repeating: 0, count: 64 * 1_024)
    var decodedByteCount = 0
    var stream = z_stream()
    guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
      throw MetaShieldError.verificationFailed("zlib 검증기를 초기화하지 못했습니다.")
    }
    defer { inflateEnd(&stream) }

    let validationError: MetaShieldError? = compressed.withUnsafeBytes { sourceBuffer in
      guard sourceBuffer.count <= Int(UInt32.max),
        let source = sourceBuffer.bindMemory(to: UInt8.self).baseAddress
      else {
        return .verificationFailed("IDAT 데이터가 비어 있거나 너무 큽니다.")
      }
      stream.next_in = UnsafeMutablePointer(mutating: source)
      stream.avail_in = uInt(sourceBuffer.count)

      while true {
        let status = output.withUnsafeMutableBufferPointer { buffer -> Int32 in
          guard let destination = buffer.baseAddress else { return Z_MEM_ERROR }
          stream.next_out = destination
          stream.avail_out = uInt(buffer.count)
          return inflate(&stream, Z_NO_FLUSH)
        }
        let produced = output.count - Int(stream.avail_out)
        for byte in output.prefix(produced) {
          if decodedByteCount % rowByteCount == 0, byte > 4 {
            return .verificationFailed("잘못된 PNG 필터 바이트가 있습니다.")
          }
          decodedByteCount += 1
          if decodedByteCount > expectedByteCount {
            return .verificationFailed("픽셀 스트림 뒤에 데이터가 남아 있습니다.")
          }
        }

        switch status {
        case Z_STREAM_END:
          guard stream.avail_in == 0 else {
            return .verificationFailed("zlib 스트림 뒤에 숨은 데이터가 남아 있습니다.")
          }
          guard decodedByteCount == expectedByteCount else {
            return .verificationFailed("픽셀 스트림 길이가 이미지 크기와 다릅니다.")
          }
          return nil
        case Z_OK:
          if produced == 0, stream.avail_in == 0 {
            return .verificationFailed("zlib 스트림이 완결되지 않았습니다.")
          }
        default:
          return .verificationFailed("IDAT zlib 스트림을 해제할 수 없습니다.")
        }
      }
    }
    if let validationError { throw validationError }
  }

  private static func parse(_ data: Data) throws -> [ParsedChunk] {
    guard data.count >= signature.count, data.prefix(signature.count) == signature else {
      throw MetaShieldError.invalidPNG("PNG 시그니처가 없습니다.")
    }

    var chunks: [ParsedChunk] = []
    var offset = signature.count
    var reachedEnd = false

    while offset < data.count {
      guard data.count - offset >= 12 else {
        throw MetaShieldError.invalidPNG("잘린 청크 헤더입니다.")
      }

      let length = Int(readUInt32BE(data, at: offset))
      guard length >= 0, length <= 512 * 1_024 * 1_024 else {
        throw MetaShieldError.invalidPNG("비정상적인 청크 길이입니다.")
      }

      let typeStart = offset + 4
      let payloadStart = offset + 8
      let payloadEnd = payloadStart + length
      let chunkEnd = payloadEnd + 4
      guard payloadEnd >= payloadStart, chunkEnd <= data.count else {
        throw MetaShieldError.invalidPNG("청크가 파일 끝을 벗어납니다.")
      }

      let typeData = data[typeStart..<(typeStart + 4)]
      guard typeData.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
        let type = String(data: typeData, encoding: .ascii)
      else {
        throw MetaShieldError.invalidPNG("잘못된 청크 이름입니다.")
      }

      let expectedCRC = readUInt32BE(data, at: payloadEnd)
      let actualCRC = CRC32.checksum(data[typeStart..<payloadEnd])
      guard expectedCRC == actualCRC else {
        throw MetaShieldError.invalidPNG("\(type) 청크 CRC가 일치하지 않습니다.")
      }

      chunks.append(
        ParsedChunk(
          type: type,
          completeRange: offset..<chunkEnd,
          payloadRange: payloadStart..<payloadEnd
        )
      )
      offset = chunkEnd

      if type == "IEND" {
        reachedEnd = true
        break
      }
    }

    guard reachedEnd else {
      throw MetaShieldError.invalidPNG("IEND 청크가 없습니다.")
    }
    guard offset == data.count else {
      throw MetaShieldError.invalidPNG("IEND 뒤에 데이터가 남아 있습니다.")
    }
    return chunks
  }

  private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
    let bytes = data[offset..<(offset + 4)]
    return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  }

  private static func readUInt32BE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    (UInt32(bytes[offset]) << 24)
      | (UInt32(bytes[offset + 1]) << 16)
      | (UInt32(bytes[offset + 2]) << 8)
      | UInt32(bytes[offset + 3])
  }

  private static func appendChunk(type: String, payload: Data, to output: inout Data) throws {
    guard let typeData = type.data(using: .ascii),
      typeData.count == 4,
      payload.count <= Int(UInt32.max)
    else {
      throw MetaShieldError.invalidPNG("정규 PNG 청크를 만들 수 없습니다.")
    }
    output.append(contentsOf: [
      UInt8(truncatingIfNeeded: UInt32(payload.count) >> 24),
      UInt8(truncatingIfNeeded: UInt32(payload.count) >> 16),
      UInt8(truncatingIfNeeded: UInt32(payload.count) >> 8),
      UInt8(truncatingIfNeeded: UInt32(payload.count)),
    ])
    output.append(typeData)
    output.append(payload)
    var crcInput = typeData
    crcInput.append(payload)
    let crc = CRC32.checksum(crcInput[...])
    output.append(contentsOf: [
      UInt8(truncatingIfNeeded: crc >> 24),
      UInt8(truncatingIfNeeded: crc >> 16),
      UInt8(truncatingIfNeeded: crc >> 8),
      UInt8(truncatingIfNeeded: crc),
    ])
  }
}

private enum CRC32 {
  private static let table: [UInt32] = (0..<256).map { index in
    var value = UInt32(index)
    for _ in 0..<8 {
      value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
    }
    return value
  }

  static func checksum(_ bytes: Data.SubSequence) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
      let index = Int((crc ^ UInt32(byte)) & 0xFF)
      crc = table[index] ^ (crc >> 8)
    }
    return crc ^ 0xFFFF_FFFF
  }
}
