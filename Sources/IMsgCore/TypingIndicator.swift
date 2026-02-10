import Foundation

public struct TypingIndicator: Sendable {
  public static func startTyping(chatIdentifier: String) throws {
    try setTyping(chatIdentifier: chatIdentifier, isTyping: true)
  }

  public static func stopTyping(chatIdentifier: String) throws {
    try setTyping(chatIdentifier: chatIdentifier, isTyping: false)
  }

  public static func typeForDuration(chatIdentifier: String, duration: TimeInterval) async throws {
    try startTyping(chatIdentifier: chatIdentifier)
    try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    try stopTyping(chatIdentifier: chatIdentifier)
  }

  private static func setTyping(chatIdentifier: String, isTyping: Bool) throws {
    let frameworkPath = "/System/Library/PrivateFrameworks/IMCore.framework/IMCore"
    guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
      let error = String(cString: dlerror())
      throw IMsgError.typingIndicatorFailed("Failed to load IMCore framework: \(error)")
    }
    defer { dlclose(handle) }

    try IMCoreBridge.ensureDaemonConnection()
    let chat = try IMCoreBridge.lookupChat(identifier: chatIdentifier)
    try IMCoreBridge.setTyping(isTyping, in: chat)
  }
}
