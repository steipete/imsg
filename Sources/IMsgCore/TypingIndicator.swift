import Foundation

/// Sends typing indicators for iMessage chats via the IMCore private framework.
///
/// Uses runtime `dlopen` to load IMCore — the only way to programmatically toggle
/// typing state. AppleScript has no equivalent capability.
///
/// Requires macOS 14+, Messages.app signed in, and an existing conversation with the contact.
public struct TypingIndicator: Sendable {
  private static let daemonConnectionTracker = DaemonConnectionTracker()

  /// Start showing the typing indicator for a chat.
  /// - Parameter chatIdentifier: e.g. `"iMessage;-;+14155551212"` or a chat GUID.
  /// - Throws: `IMsgError.typingIndicatorFailed` if IMCore is unavailable or chat not found.
  public static func startTyping(chatIdentifier: String) throws {
    try setTyping(chatIdentifier: chatIdentifier, isTyping: true)
  }

  /// Stop showing the typing indicator for a chat.
  /// - Parameter chatIdentifier: The chat identifier string.
  /// - Throws: `IMsgError.typingIndicatorFailed` if IMCore is unavailable or chat not found.
  public static func stopTyping(chatIdentifier: String) throws {
    try setTyping(chatIdentifier: chatIdentifier, isTyping: false)
  }

  /// Show typing indicator for a duration, then automatically stop.
  /// - Parameters:
  ///   - chatIdentifier: The chat identifier string.
  ///   - duration: Seconds to show the typing indicator.
  public static func typeForDuration(chatIdentifier: String, duration: TimeInterval) async throws {
    try await typeForDuration(
      chatIdentifier: chatIdentifier,
      duration: duration,
      startTyping: { try startTyping(chatIdentifier: $0) },
      stopTyping: { try stopTyping(chatIdentifier: $0) },
      sleep: { try await Task.sleep(nanoseconds: $0) }
    )
  }

  // MARK: - Private

  private static func setTyping(chatIdentifier: String, isTyping: Bool) throws {
    let frameworkPath = "/System/Library/PrivateFrameworks/IMCore.framework/IMCore"
    guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
      let error = String(cString: dlerror())
      throw IMsgError.typingIndicatorFailed(
        "Failed to load IMCore framework: \(error)")
    }
    defer { dlclose(handle) }

    try ensureDaemonConnection()
    let chat = try lookupChat(identifier: chatIdentifier)

    let selector = sel_registerName("setLocalUserIsTyping:")
    guard let method = class_getInstanceMethod(object_getClass(chat), selector) else {
      throw IMsgError.typingIndicatorFailed(
        "setLocalUserIsTyping: method not found on IMChat")
    }
    let implementation = method_getImplementation(method)

    typealias SetTypingFunc = @convention(c) (AnyObject, Selector, Bool) -> Void
    let setTypingFunc = unsafeBitCast(implementation, to: SetTypingFunc.self)
    setTypingFunc(chat, selector, isTyping)
  }

  static func typeForDuration(
    chatIdentifier: String,
    duration: TimeInterval,
    startTyping: (String) throws -> Void,
    stopTyping: (String) throws -> Void,
    sleep: (UInt64) async throws -> Void
  ) async throws {
    try startTyping(chatIdentifier)
    var stopped = false
    defer {
      if !stopped {
        try? stopTyping(chatIdentifier)
      }
    }
    try await sleep(UInt64(duration * 1_000_000_000))
    try stopTyping(chatIdentifier)
    stopped = true
  }

  private static func ensureDaemonConnection() throws {
    guard let controllerClass = objc_getClass("IMDaemonController") as? NSObject.Type else {
      throw IMsgError.typingIndicatorFailed("IMDaemonController class not found")
    }

    let sharedSel = sel_registerName("sharedInstance")
    guard controllerClass.responds(to: sharedSel) else {
      throw IMsgError.typingIndicatorFailed("IMDaemonController.sharedInstance not available")
    }

    guard let controller = controllerClass.perform(sharedSel)?.takeUnretainedValue() else {
      throw IMsgError.typingIndicatorFailed("Failed to get IMDaemonController shared instance")
    }

    if hasLiveDaemonConnection(controller) {
      daemonConnectionTracker.lock.lock()
      daemonConnectionTracker.hasAttemptedConnection = true
      daemonConnectionTracker.lock.unlock()
      return
    }

    daemonConnectionTracker.lock.lock()
    let shouldAttemptConnection = !daemonConnectionTracker.hasAttemptedConnection
    if shouldAttemptConnection {
      daemonConnectionTracker.hasAttemptedConnection = true
    }
    daemonConnectionTracker.lock.unlock()
    if !shouldAttemptConnection { return }

    let connectSel = sel_registerName("connectToDaemon")
    if controller.responds(to: connectSel) {
      _ = controller.perform(connectSel)
    }

    // Wait for daemon connection to establish and chat registry to populate
    try waitForDaemonConnection(controller)
  }

  private static func waitForDaemonConnection(_ controller: AnyObject) throws {
    let maxAttempts = 50  // 50 attempts × 100ms = 5 seconds max
    let sleepInterval: UInt32 = 100_000  // 100ms in microseconds

    for attempt in 0..<maxAttempts {
      if hasLiveDaemonConnection(controller) {
        // Connection established; give registry a moment to populate
        if attempt > 0 {
          usleep(sleepInterval)
        }
        return
      }
      usleep(sleepInterval)
    }

    throw IMsgError.typingIndicatorFailed(
      "Failed to establish daemon connection after 5 seconds. "
        + "Make sure Messages.app is running and signed in.")
  }

  private static func hasLiveDaemonConnection(_ controller: AnyObject) -> Bool {
    let isConnectedSel = sel_registerName("isConnected")
    guard controller.responds(to: isConnectedSel) else { return false }
    guard let value = controller.perform(isConnectedSel)?.takeUnretainedValue() else {
      return false
    }
    if let number = value as? NSNumber {
      return number.boolValue
    }
    return false
  }

  private static func lookupChat(identifier: String) throws -> NSObject {
    guard let registryClass = objc_getClass("IMChatRegistry") as? NSObject.Type else {
      throw IMsgError.typingIndicatorFailed("IMChatRegistry class not found")
    }

    let sharedSel = sel_registerName("sharedInstance")
    guard registryClass.responds(to: sharedSel) else {
      throw IMsgError.typingIndicatorFailed("IMChatRegistry.sharedInstance not available")
    }

    guard let registry = registryClass.perform(sharedSel)?.takeUnretainedValue() as? NSObject
    else {
      throw IMsgError.typingIndicatorFailed("Failed to get IMChatRegistry shared instance")
    }

    // Poll for the chat to appear in the registry (registry may be syncing after daemon connection)
    let maxAttempts = 30  // 30 attempts × 100ms = 3 seconds max
    let sleepInterval: UInt32 = 100_000  // 100ms in microseconds

    for _ in 0..<maxAttempts {
      if let chat = tryFindChat(in: registry, identifier: identifier) {
        return chat
      }
      usleep(sleepInterval)
    }

    throw IMsgError.typingIndicatorFailed(
      "Chat not found for identifier: \(identifier). "
        + "Make sure Messages.app has an active conversation with this contact.")
  }

  private static func tryFindChat(in registry: NSObject, identifier: String) -> NSObject? {
    let guidSel = sel_registerName("existingChatWithGUID:")
    if registry.responds(to: guidSel) {
      if let chat = registry.perform(guidSel, with: identifier)?.takeUnretainedValue() as? NSObject
      {
        return chat
      }
    }

    let identSel = sel_registerName("existingChatWithChatIdentifier:")
    if registry.responds(to: identSel) {
      if let chat = registry.perform(identSel, with: identifier)?.takeUnretainedValue() as? NSObject
      {
        return chat
      }
    }

    return nil
  }
}

private final class DaemonConnectionTracker: @unchecked Sendable {
  let lock = NSLock()
  var hasAttemptedConnection = false
}
