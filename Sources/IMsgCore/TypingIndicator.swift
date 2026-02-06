import Foundation

/// Sends typing indicators for iMessage chats via the IMCore private framework.
///
/// Uses runtime `dlopen` to load IMCore — the only way to programmatically toggle
/// typing state. AppleScript has no equivalent capability.
///
/// Requires macOS 14+, Messages.app signed in, and an existing conversation with the contact.
public struct TypingIndicator: Sendable {

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
    try startTyping(chatIdentifier: chatIdentifier)
    try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    try stopTyping(chatIdentifier: chatIdentifier)
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

    try ensureDaemonConnection(handle: handle)
    let chat = try lookupChat(handle: handle, identifier: chatIdentifier)

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

  private static func ensureDaemonConnection(handle: UnsafeMutableRawPointer) throws {
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

    let connectSel = sel_registerName("connectToDaemon")
    if controller.responds(to: connectSel) {
      _ = controller.perform(connectSel)
    }

    Thread.sleep(forTimeInterval: 0.5)
  }

  private static func lookupChat(
    handle: UnsafeMutableRawPointer, identifier: String
  ) throws -> NSObject {
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

    throw IMsgError.typingIndicatorFailed(
      "Chat not found for identifier: \(identifier). "
        + "Make sure Messages.app has an active conversation with this contact.")
  }
}
