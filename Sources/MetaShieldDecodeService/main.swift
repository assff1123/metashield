import Foundation
import MetaShieldCore

/// The isolated decoder.
///
/// This process holds the only code that reads attacker-controlled image bytes.
/// It is sandboxed with no file, network, or device access: the only thing it
/// can touch is the descriptor the app hands it and the reply it sends back.
final class DecodingService: NSObject, ImageDecodingServiceProtocol, @unchecked Sendable {
  func sanitizeImage(
    handle: FileHandle,
    request: ImageDecodingRequest,
    withReply reply: @escaping (ImageDecodingResponse?, String?) -> Void
  ) {
    do {
      let sanitizer = ImageSanitizer(
        maximumPixelCount: request.maximumPixelCount,
        maximumInputByteCount: request.maximumInputByteCount
      )
      let data = try handle.readToEnd() ?? Data()
      let encoded: Data
      let size: (width: Int, height: Int)
      switch request.outputFormat {
      case ImageDecodingRequest.avifFormat:
        (encoded, size) = try sanitizer.encodedSanitizedAVIF(
          from: data, quality: .compressed(request.compressionQuality))
      default:
        (encoded, size) = try sanitizer.encodedSanitizedPNG(from: data)
      }
      reply(
        ImageDecodingResponse(encoded: encoded, width: size.width, height: size.height), nil)
    } catch {
      reply(nil, error.localizedDescription)
    }
  }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection connection: NSXPCConnection
  ) -> Bool {
    let interface = NSXPCInterface(with: ImageDecodingServiceProtocol.self)
    interface.setClasses(
      NSSet(array: [ImageDecodingRequest.self]) as! Set<AnyHashable>,
      for: #selector(ImageDecodingServiceProtocol.sanitizeImage(handle:request:withReply:)),
      argumentIndex: 1,
      ofReply: false
    )
    interface.setClasses(
      NSSet(array: [ImageDecodingResponse.self]) as! Set<AnyHashable>,
      for: #selector(ImageDecodingServiceProtocol.sanitizeImage(handle:request:withReply:)),
      argumentIndex: 0,
      ofReply: true
    )
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
