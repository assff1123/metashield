import Foundation
import MetaShieldCore

/// The isolated decoder.
///
/// This process holds the only code that reads attacker-controlled image bytes.
/// It is sandboxed with no file, network, or device access: the only things it
/// touches are the descriptor the app hands it and the reply it sends back.
///
/// It does not trust the request either. A security boundary that only enforces
/// limits its caller asked for is not enforcing anything, so the ceilings below
/// are the service's own and the descriptor is measured before it is read.
final class DecodingService: NSObject, ImageDecodingServiceProtocol, @unchecked Sendable {
  /// Absolute ceilings, independent of anything the caller sends.
  private static let absoluteMaximumPixelCount = 40_000_000
  private static let absoluteMaximumInputByteCount = 256 * 1_024 * 1_024
  private static let absoluteMaximumOutputByteCount = 256 * 1_024 * 1_024
  private static let readChunkByteCount = 4 * 1_024 * 1_024

  func sanitizeImage(
    handle: FileHandle,
    request: ImageDecodingRequest,
    withReply reply: @escaping (ImageDecodingResponse?, String?) -> Void
  ) {
    respond(to: reply) {
      let sanitizer = try Self.makeSanitizer(for: request)
      let data = try Self.boundedData(from: handle)
      let encoded: Data
      let size: (width: Int, height: Int)
      if request.outputFormat == ImageDecodingRequest.avifFormat {
        (encoded, size) = try sanitizer.encodedSanitizedAVIF(
          from: data, quality: .compressed(request.compressionQuality))
      } else {
        (encoded, size) = try sanitizer.encodedSanitizedPNG(from: data)
      }
      guard encoded.count <= Self.absoluteMaximumOutputByteCount else {
        throw MetaShieldError.verificationFailed("정리된 이미지가 출력 크기 제한을 넘었습니다.")
      }
      return ImageDecodingResponse(encoded: encoded, width: size.width, height: size.height)
    }
  }

  func verifyImage(
    handle: FileHandle,
    request: ImageDecodingRequest,
    withReply reply: @escaping (ImageDecodingResponse?, String?) -> Void
  ) {
    respond(to: reply) {
      let sanitizer = try Self.makeSanitizer(for: request)
      let data = try Self.boundedData(from: handle)
      let size = try sanitizer.verifiedImageSize(of: data, format: request.outputFormat)
      return ImageDecodingResponse(encoded: Data(), width: size.width, height: size.height)
    }
  }

  /// Errors cross the boundary as text. Nothing here may trap: a malformed
  /// request must fail the call, not take the service down.
  private func respond(
    to reply: @escaping (ImageDecodingResponse?, String?) -> Void,
    work: () throws -> ImageDecodingResponse
  ) {
    do {
      // XPC services are long-lived. Drain ImageIO/CoreGraphics temporary
      // objects after every request so batches do not retain prior frames.
      let response = try autoreleasepool(invoking: work)
      reply(response, nil)
    } catch {
      reply(nil, error.localizedDescription)
    }
  }

  private static func makeSanitizer(for request: ImageDecodingRequest) throws -> ImageSanitizer {
    // `ImageSanitizer` treats non-positive limits as a programming error and
    // traps. Values arriving over IPC are input, so they are clamped here
    // instead of being handed straight to a precondition.
    guard request.maximumPixelCount > 0, request.maximumInputByteCount > 0 else {
      throw MetaShieldError.verificationFailed("요청한 처리 한도가 올바르지 않습니다.")
    }
    guard
      request.outputFormat == ImageDecodingRequest.pngFormat
        || request.outputFormat == ImageDecodingRequest.avifFormat
    else {
      throw MetaShieldError.verificationFailed("요청한 출력 형식이 올바르지 않습니다.")
    }
    if request.outputFormat == ImageDecodingRequest.avifFormat {
      guard request.compressionQuality.isFinite,
        (0...1).contains(request.compressionQuality)
      else {
        throw MetaShieldError.verificationFailed("요청한 AVIF 품질 값이 올바르지 않습니다.")
      }
    }
    return ImageSanitizer(
      maximumPixelCount: min(request.maximumPixelCount, absoluteMaximumPixelCount),
      maximumInputByteCount: min(request.maximumInputByteCount, absoluteMaximumInputByteCount)
    )
  }

  /// Measures the descriptor before reading it, then reads in bounded chunks so
  /// an oversized or endless input cannot be materialized first and rejected
  /// afterwards.
  private static func boundedData(from handle: FileHandle) throws -> Data {
    var state = stat()
    guard fstat(handle.fileDescriptor, &state) == 0 else {
      throw MetaShieldError.fileOperationFailed(String(cString: strerror(errno)))
    }
    guard state.st_mode & S_IFMT == S_IFREG else {
      throw MetaShieldError.notARegularFile
    }
    guard state.st_size >= 0, state.st_size <= Int64(absoluteMaximumInputByteCount) else {
      throw MetaShieldError.inputFileTooLarge(
        byteCount: state.st_size < 0 ? Int.max : Int(state.st_size),
        limit: absoluteMaximumInputByteCount
      )
    }

    var data = Data()
    data.reserveCapacity(Int(state.st_size))
    while true {
      let chunk = try handle.read(upToCount: readChunkByteCount) ?? Data()
      if chunk.isEmpty { break }
      guard data.count <= absoluteMaximumInputByteCount - chunk.count else {
        throw MetaShieldError.inputFileTooLarge(
          byteCount: data.count + chunk.count,
          limit: absoluteMaximumInputByteCount
        )
      }
      data.append(chunk)
    }
    return data
  }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection connection: NSXPCConnection
  ) -> Bool {
    let interface = NSXPCInterface(with: ImageDecodingServiceProtocol.self)
    for selector in [
      #selector(ImageDecodingServiceProtocol.sanitizeImage(handle:request:withReply:)),
      #selector(ImageDecodingServiceProtocol.verifyImage(handle:request:withReply:)),
    ] {
      interface.setClasses(
        NSSet(array: [ImageDecodingRequest.self]) as! Set<AnyHashable>,
        for: selector, argumentIndex: 1, ofReply: false)
      interface.setClasses(
        NSSet(array: [ImageDecodingResponse.self]) as! Set<AnyHashable>,
        for: selector, argumentIndex: 0, ofReply: true)
    }
    connection.exportedInterface = interface
    connection.exportedObject = DecodingService()
    connection.resume()
    return true
  }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
