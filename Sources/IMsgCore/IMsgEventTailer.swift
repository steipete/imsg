import Foundation

/// Live tailer for `.imsg-events.jsonl` written by the injected dylib.
///
/// Uses `DispatchSource.makeFileSystemObjectSource` watching `.write`,
/// `.extend`, and `.rename`. On rename (file rotation by the dylib at 1 MiB)
/// the source closes and reopens. Each newly-written full line is decoded as
/// a JSON object and surfaced via the `events` AsyncStream.
///
/// Designed to be co-resident with `MessageWatcher` inside `imsg watch`.
public final class IMsgEventTailer: @unchecked Sendable {
  /// One decoded event line. `payloadJSON` is the raw JSON-encoded `data`
  /// object (UTF-8 bytes); decode lazily on the consumer side via
  /// `JSONSerialization` if you need typed access. Holding raw Data keeps the
  /// type Sendable across actor boundaries under Swift 6 strict concurrency.
  public struct Event: Sendable {
    public let timestamp: String?
    public let name: String
    public let payloadJSON: Data

    public init(timestamp: String?, name: String, payloadJSON: Data) {
      self.timestamp = timestamp
      self.name = name
      self.payloadJSON = payloadJSON
    }

    /// Decode `payloadJSON` to a dictionary. Returns `[:]` on any error.
    public func decodedPayload() -> [String: Any] {
      guard
        let obj = try? JSONSerialization.jsonObject(with: payloadJSON, options: [])
          as? [String: Any]
      else { return [:] }
      return obj
    }
  }

  private let path: String
  private let replayExisting: Bool
  private var source: DispatchSourceFileSystemObject?
  private var fd: Int32 = -1
  private var pending = Data()
  private var continuation: AsyncStream<Event>.Continuation?
  private let queue = DispatchQueue(label: "imsg.event.tailer")

  public init(path: String, replayExisting: Bool = false) {
    self.path = path
    self.replayExisting = replayExisting
  }

  /// Start tailing and return an AsyncStream of decoded events. Starts at EOF
  /// by default so `watch --bb-events` only emits live events.
  public func events() -> AsyncStream<Event> {
    return AsyncStream { continuation in
      self.continuation = continuation
      continuation.onTermination = { @Sendable _ in
        self.stop()
      }
      self.queue.async {
        self.openAndStart()
      }
    }
  }

  public func stop() {
    queue.async { [weak self] in
      guard let self else { return }
      self.source?.cancel()
      self.source = nil
      if self.fd >= 0 {
        close(self.fd)
        self.fd = -1
      }
    }
  }

  // MARK: - Private

  private func openAndStart() {
    if !FileManager.default.fileExists(atPath: path) {
      // Create empty file so we can watch it. The dylib appends; missing
      // file means injection isn't active yet — caller can retry later.
      FileManager.default.createFile(atPath: path, contents: Data(), attributes: nil)
    }
    let fd = open(path, O_RDONLY)
    if fd < 0 { return }
    self.fd = fd
    if replayExisting {
      drainAvailable()
    } else {
      lseek(fd, 0, SEEK_END)
    }

    let src = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.extend, .write, .rename, .delete],
      queue: queue
    )
    src.setEventHandler { [weak self] in
      guard let self else { return }
      let mask = src.data
      if mask.contains(.rename) || mask.contains(.delete) {
        // File rotated by the dylib — close and reopen the new file.
        self.reopen()
        return
      }
      self.drainAvailable()
    }
    src.setCancelHandler { [weak self] in
      guard let self else { return }
      if self.fd >= 0 {
        close(self.fd)
        self.fd = -1
      }
    }
    src.resume()
    self.source = src
  }

  private func reopen() {
    source?.cancel()
    source = nil
    if fd >= 0 {
      close(fd)
      fd = -1
    }
    pending.removeAll(keepingCapacity: true)
    // Small delay lets the dylib finish the rename; then start fresh.
    queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      self?.openAndStart()
    }
  }

  private func drainAvailable() {
    guard fd >= 0 else { return }
    var buffer = Data(count: 8192)
    while true {
      let n = buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
        guard let base = raw.baseAddress else { return -1 }
        return read(fd, base, raw.count)
      }
      if n <= 0 { break }
      pending.append(buffer.prefix(n))
      processPending()
    }
  }

  private func processPending() {
    while let nl = pending.firstIndex(of: 0x0A) {
      let line = pending[..<nl]
      pending.removeSubrange(...nl)
      guard !line.isEmpty else { continue }
      guard
        let obj = try? JSONSerialization.jsonObject(with: line, options: [])
          as? [String: Any]
      else { continue }
      let name = (obj["event"] as? String) ?? "unknown"
      let ts = obj["ts"] as? String
      let data = (obj["data"] as? [String: Any]) ?? [:]
      let payloadData = (try? JSONSerialization.data(withJSONObject: data, options: [])) ?? Data()
      continuation?.yield(Event(timestamp: ts, name: name, payloadJSON: payloadData))
    }
  }
}
