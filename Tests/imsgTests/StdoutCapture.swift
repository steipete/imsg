import Darwin
import Foundation

private actor StdoutCaptureLock {
  private var isLocked = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    if !isLocked {
      isLocked = true
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func release() {
    if waiters.isEmpty {
      isLocked = false
      return
    }
    let next = waiters.removeFirst()
    next.resume()
  }
}

enum StdoutCapture {
  private static let lock = StdoutCaptureLock()

  static func capture<T>(_ body: () async throws -> T) async rethrows -> (output: String, value: T)
  {
    await lock.acquire()

    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else {
      await lock.release()
      fatalError("pipe() failed")
    }
    let readFD = fds[0]
    let writeFD = fds[1]

    let savedStdout = dup(STDOUT_FILENO)
    guard savedStdout >= 0 else {
      close(readFD)
      close(writeFD)
      await lock.release()
      fatalError("dup(STDOUT_FILENO) failed")
    }

    guard dup2(writeFD, STDOUT_FILENO) >= 0 else {
      close(readFD)
      close(writeFD)
      close(savedStdout)
      await lock.release()
      fatalError("dup2(writeFD, STDOUT_FILENO) failed")
    }
    close(writeFD)

    do {
      let value = try await body()

      _ = dup2(savedStdout, STDOUT_FILENO)
      close(savedStdout)

      let handle = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
      let data = handle.readDataToEndOfFile()
      await lock.release()
      return (String(data: data, encoding: .utf8) ?? "", value)
    } catch {
      _ = dup2(savedStdout, STDOUT_FILENO)
      close(savedStdout)
      close(readFD)
      await lock.release()
      throw error
    }
  }
}
