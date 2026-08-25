import Foundation

/// Runs the sanitizing pipeline somewhere.
///
/// One implementation decodes in this process; the other hands the bytes to the
/// sandboxed service. Everything above this protocol is unchanged either way,
/// so the file-handling and verification logic has a single implementation.
public protocol CanonicalImageEncoding: Sendable {
  func encodedSanitizedPNG(from sourceData: Data) throws -> (Data, (width: Int, height: Int))
  func encodedSanitizedAVIF(
    from sourceData: Data,
    quality: AVIFQuality
  ) throws -> (Data, (width: Int, height: Int))
  /// Decodes `sourceData` only to confirm it is a clean result of the expected
  /// format, returning its dimensions.
  func verifiedImageSize(
    of sourceData: Data,
    format: String
  ) throws -> (width: Int, height: Int)
}

extension ImageSanitizer: CanonicalImageEncoding {}

/// Talks to the sandboxed decoder.
///
/// Calls are synchronous because the callers already run on a background queue,
/// and because a half-finished sanitization has no useful meaning: the app needs
/// the bytes before it can verify and write them.
public final class DecodingServiceClient: CanonicalImageEncoding, @unchecked Sendable {
  public enum ClientError: LocalizedError {
    case unavailable
    case timedOut
    case remote(String)

    public var errorDescription: String? {
      switch self {
      case .unavailable:
        return "격리된 디코더를 시작하지 못했습니다."
      case .timedOut:
        return "격리된 디코더가 응답하지 않았습니다."
      case .remote(let message):
        return message
      }
    }
  }

  private let serviceName: String
  private let timeout: TimeInterval

  public init(
    serviceName: String = ImageDecodingServiceIdentity.bundleIdentifier,
    timeout: TimeInterval = 120
  ) {
    self.serviceName = serviceName
    self.timeout = timeout
  }

  public func encodedSanitizedPNG(from sourceData: Data) throws -> (Data, (width: Int, height: Int))
  {
    try run(sourceData, format: ImageDecodingRequest.pngFormat, quality: 0)
  }

  public func encodedSanitizedAVIF(
    from sourceData: Data,
    quality: AVIFQuality
  ) throws -> (Data, (width: Int, height: Int)) {
    try run(
      sourceData,
      format: ImageDecodingRequest.avifFormat,
      quality: quality.compressionValue
    )
  }

  public func verifiedImageSize(
    of sourceData: Data,
    format: String
  ) throws -> (width: Int, height: Int) {
    try run(sourceData, format: format, quality: 0, verifyOnly: true).1
  }

  private func run(
    _ sourceData: Data,
    format: String,
    quality: Double,
    verifyOnly: Bool = false
  ) throws -> (Data, (width: Int, height: Int)) {
    // The bytes travel as a descriptor rather than a copied payload, so a large
    // image does not have to exist twice in memory to cross the boundary.
    let (handle, temporaryURL) = try makeTransferHandle(for: sourceData)
    defer {
      try? handle.close()
      try? FileManager.default.removeItem(at: temporaryURL)
    }

    let connection = NSXPCConnection(serviceName: serviceName)
    connection.remoteObjectInterface = Self.makeInterface()
    connection.resume()
    defer { connection.invalidate() }

    let box = ResultBox()
    let proxy =
      connection.remoteObjectProxyWithErrorHandler { error in
        box.finish(.failure(ClientError.remote(error.localizedDescription)))
      } as? ImageDecodingServiceProtocol
    guard let proxy else { throw ClientError.unavailable }

    let request = ImageDecodingRequest(
      outputFormat: format,
      maximumPixelCount: maximumPixelCount,
      maximumInputByteCount: maximumInputByteCount,
      compressionQuality: quality
    )
    let completion: (ImageDecodingResponse?, String?) -> Void = { response, message in
      if let response {
        box.finish(.success(response))
      } else {
        box.finish(.failure(ClientError.remote(message ?? "격리된 디코더가 실패했습니다.")))
      }
    }
    if verifyOnly {
      proxy.verifyImage(handle: handle, request: request, withReply: completion)
    } else {
      proxy.sanitizeImage(handle: handle, request: request, withReply: completion)
    }

    let response = try box.wait(timeout: timeout)
    return (response.encoded, (response.width, response.height))
  }

  /// Limits are carried in the request so the service enforces the same ceilings
  /// the app would have enforced in process.
  public var maximumPixelCount: Int = 40_000_000
  public var maximumInputByteCount: Int = 256 * 1_024 * 1_024

  private func makeTransferHandle(for data: Data) throws -> (FileHandle, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MetaShieldTransfer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let url = directory.appendingPathComponent("input")
    try data.write(to: url, options: [.atomic])
    let handle = try FileHandle(forReadingFrom: url)
    return (handle, directory)
  }

  private static func makeInterface() -> NSXPCInterface {
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
    return interface
  }

  private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var stored: Result<ImageDecodingResponse, Error>?

    func finish(_ result: Result<ImageDecodingResponse, Error>) {
      lock.lock()
      guard stored == nil else {
        lock.unlock()
        return
      }
      stored = result
      lock.unlock()
      semaphore.signal()
    }

    func wait(timeout: TimeInterval) throws -> ImageDecodingResponse {
      guard semaphore.wait(timeout: .now() + timeout) == .success else {
        throw ClientError.timedOut
      }
      lock.lock()
      let result = stored
      lock.unlock()
      return try (result ?? .failure(ClientError.unavailable)).get()
    }
  }
}
