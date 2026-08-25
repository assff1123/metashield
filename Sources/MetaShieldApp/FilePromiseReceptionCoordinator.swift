import Foundation
import MetaShieldCore

/// `NSFilePromiseReceiver` invokes its callback once per promised file, not once
/// per receiver. Track every callback explicitly so multi-file Photos drags cannot
/// unbalance a DispatchGroup or finish before all promised files arrive.
final class FilePromiseReceptionCoordinator: @unchecked Sendable {
  static let maximumFileByteCount = 256 * 1_024 * 1_024
  static let maximumBatchByteCount = 4 * 1_024 * 1_024 * 1_024

  private struct ReceiverState {
    var expectedCallbacks: Int?
    var callbackCount = 0
    var completed = false
  }

  private let lock = NSLock()
  private let destinationDirectory: URL
  private var states: [ReceiverState]
  private var receivedURLs: [URL] = []
  private var errors: [Error] = []
  private var finished = false
  private var resourceMonitor: DispatchSourceTimer?
  private var completion: (@Sendable ([URL], [Error]) -> Void)?

  init(
    receiverCount: Int,
    destinationDirectory: URL,
    completion: @escaping @Sendable ([URL], [Error]) -> Void
  ) {
    states = Array(repeating: ReceiverState(), count: receiverCount)
    self.destinationDirectory = destinationDirectory.standardizedFileURL
    self.completion = completion
  }

  func setExpectedCallbackCount(_ count: Int, for receiverIndex: Int) {
    lock.lock()
    guard !finished, states.indices.contains(receiverIndex) else {
      lock.unlock()
      return
    }
    // Some providers legitimately advertise an empty promise. Mark that
    // receiver complete immediately instead of waiting for a callback that can
    // never arrive and turning it into a misleading 60-second timeout.
    states[receiverIndex].expectedCallbacks = max(0, count)
    updateCompletionState(for: receiverIndex)
    lock.unlock()
    finishIfReady()
  }

  func record(url: URL, error: Error?, for receiverIndex: Int) {
    lock.lock()
    guard !finished, states.indices.contains(receiverIndex) else {
      lock.unlock()
      return
    }

    states[receiverIndex].callbackCount += 1
    if let error {
      errors.append(error)
    } else {
      do {
        receivedURLs.append(try validatedReceivedURL(url))
      } catch {
        errors.append(error)
      }
    }
    updateCompletionState(for: receiverIndex)
    lock.unlock()
    finishIfReady()
  }

  func timeout() {
    abort(with: MetaShieldError.fileOperationFailed("사진 앱이 60초 안에 모든 원본을 전달하지 않았습니다."))
  }

  func startResourceMonitor(cancelReception: @escaping @Sendable () -> Void) {
    let monitor = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    monitor.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
    monitor.setEventHandler { [weak self] in
      guard let self, let error = self.currentResourceLimitViolation() else { return }
      cancelReception()
      self.abort(with: error)
    }
    lock.lock()
    guard !finished, resourceMonitor == nil else {
      lock.unlock()
      monitor.cancel()
      return
    }
    resourceMonitor = monitor
    lock.unlock()
    monitor.resume()
  }

  func abort(with error: Error) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    errors.append(error)
    for index in states.indices {
      states[index].completed = true
    }
    lock.unlock()
    finishIfReady()
  }

  private func validatedReceivedURL(_ url: URL) throws -> URL {
    let root = destinationDirectory.resolvingSymlinksInPath().path
    let submitted = url.standardizedFileURL
    var submittedState = stat()
    guard submitted.path.withCString({ lstat($0, &submittedState) }) == 0 else {
      throw MetaShieldError.fileOperationFailed(String(cString: strerror(errno)))
    }
    if submittedState.st_mode & S_IFMT == S_IFLNK {
      throw MetaShieldError.symbolicLinkNotAllowed
    }
    guard submittedState.st_mode & S_IFMT == S_IFREG else {
      throw MetaShieldError.notARegularFile
    }
    let candidate = submitted.resolvingSymlinksInPath()
    guard candidate.path.hasPrefix(root + "/") else {
      throw MetaShieldError.fileOperationFailed("안전한 임시 폴더 밖의 파일은 처리하지 않습니다.")
    }
    guard submittedState.st_size >= 0, UInt64(submittedState.st_size) <= UInt64(Int.max) else {
      throw MetaShieldError.inputFileTooLarge(
        byteCount: Int.max,
        limit: Self.maximumFileByteCount
      )
    }
    let byteCount = Int(submittedState.st_size)
    guard byteCount <= Self.maximumFileByteCount else {
      throw MetaShieldError.inputFileTooLarge(
        byteCount: byteCount,
        limit: Self.maximumFileByteCount
      )
    }
    return candidate
  }

  /// `NSFilePromiseReceiver` exposes no promised size or cancellation token.
  /// Poll the private destination while providers write so a hostile promise
  /// cannot grow without a bound before its completion callback arrives.
  private func currentResourceLimitViolation() -> Error? {
    let errorLock = NSLock()
    var enumerationError: Error?
    guard
      let enumerator = FileManager.default.enumerator(
        at: destinationDirectory,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
        options: [],
        errorHandler: { _, error in
          errorLock.lock()
          enumerationError = error
          errorLock.unlock()
          return false
        }
      )
    else {
      return MetaShieldError.fileOperationFailed("사진 앱 임시 폴더를 확인하지 못했습니다.")
    }

    var totalByteCount = 0
    for case let url as URL in enumerator {
      do {
        let values = try url.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        if values.isSymbolicLink == true {
          return MetaShieldError.symbolicLinkNotAllowed
        }
        guard values.isRegularFile == true else { continue }
        let byteCount = values.fileSize ?? Int.max
        if byteCount > Self.maximumFileByteCount {
          return MetaShieldError.inputFileTooLarge(
            byteCount: byteCount,
            limit: Self.maximumFileByteCount
          )
        }
        let (nextTotal, overflow) = totalByteCount.addingReportingOverflow(byteCount)
        if overflow || nextTotal > Self.maximumBatchByteCount {
          return MetaShieldError.inputFileTooLarge(
            byteCount: overflow ? Int.max : nextTotal,
            limit: Self.maximumBatchByteCount
          )
        }
        totalByteCount = nextTotal
      } catch {
        return error
      }
    }
    errorLock.lock()
    let capturedEnumerationError = enumerationError
    errorLock.unlock()
    if let capturedEnumerationError { return capturedEnumerationError }
    return nil
  }

  private func updateCompletionState(for receiverIndex: Int) {
    guard let expected = states[receiverIndex].expectedCallbacks,
      states[receiverIndex].callbackCount >= expected
    else { return }
    states[receiverIndex].completed = true
  }

  private func finishIfReady() {
    let result: ((@Sendable ([URL], [Error]) -> Void), [URL], [Error])?
    lock.lock()
    if !finished, states.allSatisfy(\.completed), let completion {
      finished = true
      self.completion = nil
      resourceMonitor?.cancel()
      resourceMonitor = nil
      result = (completion, receivedURLs, errors)
    } else {
      result = nil
    }
    lock.unlock()
    if let result {
      result.0(result.1, result.2)
    }
  }
}
