import Darwin
import Foundation

public struct MessageWatcherConfiguration: Sendable, Equatable {
  public var debounceInterval: TimeInterval
  public var batchLimit: Int
  /// When true, reaction events (tapback add/remove) are included in the stream
  public var includeReactions: Bool
  /// Delay in milliseconds before re-reading a message row to confirm is_from_me.
  /// macOS may write is_from_me=0 on INSERT and update it to 1 shortly after.
  /// Messages where is_from_me is still false after the delay are emitted normally.
  /// Set to 0 to disable re-confirmation (preserves original behavior).
  public var reconfirmDelayMs: Int

  public init(
    debounceInterval: TimeInterval = 0.25,
    batchLimit: Int = 100,
    includeReactions: Bool = false,
    reconfirmDelayMs: Int = 400
  ) {
    self.debounceInterval = debounceInterval
    self.batchLimit = batchLimit
    self.includeReactions = includeReactions
    self.reconfirmDelayMs = reconfirmDelayMs
  }
}

public final class MessageWatcher: @unchecked Sendable {
  private let store: MessageStore

  public init(store: MessageStore) {
    self.store = store
  }

  public func stream(
    chatID: Int64? = nil,
    sinceRowID: Int64? = nil,
    configuration: MessageWatcherConfiguration = MessageWatcherConfiguration()
  ) -> AsyncThrowingStream<Message, Error> {
    AsyncThrowingStream { continuation in
      let state = WatchState(
        store: store,
        chatID: chatID,
        sinceRowID: sinceRowID,
        configuration: configuration,
        continuation: continuation
      )
      state.start()
      continuation.onTermination = { _ in
        state.stop()
      }
    }
  }
}

private final class WatchState: @unchecked Sendable {
  private let store: MessageStore
  private let chatID: Int64?
  private let configuration: MessageWatcherConfiguration
  private let continuation: AsyncThrowingStream<Message, Error>.Continuation
  private let queue = DispatchQueue(label: "imsg.watch", qos: .userInitiated)

  private var cursor: Int64
  private var sources: [DispatchSourceFileSystemObject] = []
  private var pending = false
  /// RowIDs currently pending re-confirmation (awaiting is_from_me re-read)
  private var pendingReconfirm: Set<Int64> = []

  init(
    store: MessageStore,
    chatID: Int64?,
    sinceRowID: Int64?,
    configuration: MessageWatcherConfiguration,
    continuation: AsyncThrowingStream<Message, Error>.Continuation
  ) {
    self.store = store
    self.chatID = chatID
    self.configuration = configuration
    self.continuation = continuation
    self.cursor = sinceRowID ?? 0
  }

  func start() {
    queue.async {
      do {
        if self.cursor == 0 {
          self.cursor = try self.store.maxRowID()
        }
        self.poll()
      } catch {
        self.continuation.finish(throwing: error)
      }
    }

    let paths = [store.path, store.path + "-wal", store.path + "-shm"]
    for path in paths {
      if let source = makeSource(path: path) {
        sources.append(source)
      }
    }

  }

  func stop() {
    queue.async {
      for source in self.sources {
        source.cancel()
      }
      self.sources.removeAll()
    }
  }

  private func makeSource(path: String) -> DispatchSourceFileSystemObject? {
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return nil }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .extend, .rename, .delete],
      queue: queue
    )
    source.setEventHandler { [weak self] in
      self?.schedulePoll()
    }
    source.setCancelHandler {
      close(fd)
    }
    source.resume()
    return source
  }

  private func schedulePoll() {
    if pending { return }
    pending = true
    let delay = configuration.debounceInterval
    queue.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      self.pending = false
      self.poll()
    }
  }

  private func poll() {
    do {
      let messages = try store.messagesAfter(
        afterRowID: cursor,
        chatID: chatID,
        limit: configuration.batchLimit,
        includeReactions: configuration.includeReactions
      )
      for message in messages {
        if message.rowID > cursor {
          cursor = message.rowID
        }
        // If reconfirmDelayMs > 0 and the message appears outbound (is_from_me=false
        // with no handle), schedule a re-read: macOS may not have set is_from_me=1 yet.
        let delayMs = configuration.reconfirmDelayMs
        if delayMs > 0 && !message.isFromMe && message.handleID == nil {
          let rowID = message.rowID
          guard !pendingReconfirm.contains(rowID) else { continue }
          pendingReconfirm.insert(rowID)
          let delay = DispatchTimeInterval.milliseconds(delayMs)
          queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.reconfirm(rowID: rowID, original: message)
          }
        } else {
          continuation.yield(message)
        }
      }
    } catch {
      continuation.finish(throwing: error)
    }
  }

  private func reconfirm(rowID: Int64, original: Message) {
    pendingReconfirm.remove(rowID)
    do {
      if let fresh = try store.message(rowID: rowID) {
        // Suppress if macOS has now marked this as sent by us
        if fresh.isFromMe { return }
        continuation.yield(fresh)
      } else {
        // Row gone — suppress
      }
    } catch {
      // On error, fall back to emitting the original
      continuation.yield(original)
    }
  }
}
