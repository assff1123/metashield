import Foundation
import MetaShieldCore

/// `NSFilePromiseReceiver` invokes its callback once per promised file, not once
/// per receiver. Track every callback explicitly so multi-file Photos drags cannot
/// unbalance a DispatchGroup or finish before all promised files arrive.
final class FilePromiseReceptionCoordinator: @unchecked Sendable {
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
    states[receiverIndex].expectedCallbacks = max(1, count)
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
    } else if let safeURL = validatedReceivedURL(url) {
      receivedURLs.append(safeURL)
    } else {
      errors.append(MetaShieldError.fileOperationFailed("안전한 임시 폴더 밖의 파일은 처리하지 않습니다."))
    }
    updateCompletionState(for: receiverIndex)
    lock.unlock()
    finishIfReady()
  }

  func timeout() {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    errors.append(MetaShieldError.fileOperationFailed("사진 앱이 60초 안에 모든 원본을 전달하지 않았습니다."))
    for index in states.indices {
      states[index].completed = true
    }
    lock.unlock()
    finishIfReady()
  }

  private func validatedReceivedURL(_ url: URL) -> URL? {
    let root = destinationDirectory.resolvingSymlinksInPath().path
    let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
    guard candidate.path.hasPrefix(root + "/"),
      FileManager.default.fileExists(atPath: candidate.path)
    else {
      return nil
    }
    return candidate
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
