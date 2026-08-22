import Foundation

/// Receives the release response incrementally so the configured byte limit is
/// an actual transfer limit rather than a check performed after URLSession has
/// buffered the whole body. Redirects are rejected: the opt-in request is only
/// allowed to reach the exact HTTPS endpoint compiled into the app.
final class BoundedUpdateSessionDelegate: NSObject, URLSessionDataDelegate,
  @unchecked Sendable
{
  typealias Completion = @Sendable (Data?, HTTPURLResponse?) -> Void

  private let expectedURL: URL
  private let maximumByteCount: Int
  private let completion: Completion
  private var receivedData = Data()
  private var acceptedResponse: HTTPURLResponse?
  private var failed = false

  init(expectedURL: URL, maximumByteCount: Int, completion: @escaping Completion) {
    self.expectedURL = expectedURL
    self.maximumByteCount = maximumByteCount
    self.completion = completion
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    failed = true
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let response = response as? HTTPURLResponse,
      response.statusCode == 200,
      response.url == expectedURL,
      response.expectedContentLength <= Int64(maximumByteCount)
        || response.expectedContentLength == NSURLSessionTransferSizeUnknown
    else {
      failed = true
      completionHandler(.cancel)
      return
    }

    acceptedResponse = response
    if response.expectedContentLength > 0 {
      receivedData.reserveCapacity(Int(response.expectedContentLength))
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard !failed,
      data.count <= maximumByteCount - receivedData.count
    else {
      failed = true
      dataTask.cancel()
      return
    }
    receivedData.append(data)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    let data = !failed && error == nil ? receivedData : nil
    let response = !failed && error == nil ? acceptedResponse : nil
    session.finishTasksAndInvalidate()
    completion(data, response)
  }
}

/// Downloads one release asset with a hard byte ceiling.
///
/// Redirects are allowed here, unlike the metadata request: GitHub serves release
/// assets from a separate object host. That is safe only because nothing about
/// this transfer is trusted until the Ed25519 signature and the SHA-256 in the
/// signed manifest have both matched. Redirect targets must still be HTTPS.
final class BoundedAssetDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  typealias Completion = @Sendable (Data?) -> Void

  private let maximumByteCount: Int
  private let sink: FileHandle?
  private let completion: Completion
  private var buffer = Data()
  private var receivedByteCount = 0
  private var remainingRedirects = 3
  private var failed = false

  init(maximumByteCount: Int, sink: FileHandle?, completion: @escaping Completion) {
    self.maximumByteCount = maximumByteCount
    self.sink = sink
    self.completion = completion
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard remainingRedirects > 0, request.url?.scheme == "https" else {
      failed = true
      completionHandler(nil)
      return
    }
    remainingRedirects -= 1
    completionHandler(request)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let response = response as? HTTPURLResponse,
      response.statusCode == 200,
      response.expectedContentLength <= Int64(maximumByteCount)
        || response.expectedContentLength == NSURLSessionTransferSizeUnknown
    else {
      failed = true
      completionHandler(.cancel)
      return
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard !failed, data.count <= maximumByteCount - receivedByteCount else {
      failed = true
      dataTask.cancel()
      return
    }
    receivedByteCount += data.count
    if let sink {
      do {
        try sink.write(contentsOf: data)
      } catch {
        failed = true
        dataTask.cancel()
      }
    } else {
      buffer.append(data)
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    let succeeded = !failed && error == nil
    session.finishTasksAndInvalidate()
    completion(succeeded ? (sink == nil ? buffer : Data()) : nil)
  }
}
