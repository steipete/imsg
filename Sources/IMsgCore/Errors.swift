import Foundation

public enum IMsgError: LocalizedError, CustomStringConvertible, Sendable {
  case permissionDenied(path: String, underlying: Error)
  case invalidISODate(String)
  case invalidService(String)
  case unsupportedService(String)
  case invalidChatTarget(String)
  case appleScriptFailure(String)
  case typingIndicatorFailed(String)
  case invalidReaction(String)
  case unsupportedReaction(String)
  case chatNotFound(chatID: Int64)

  public var errorDescription: String? {
    switch self {
    case .permissionDenied(let path, let underlying):
      return """
        \(underlying)

        ⚠️  Permission Error: Cannot access Messages database

        The Messages database at \(path) requires Full Disk Access permission.

        To fix:
        1. Open System Settings → Privacy & Security → Full Disk Access
        2. Add your terminal application and any parent launcher (VS Code, Node, gateway, etc.)
        3. Also add the built-in Terminal.app if you normally use another terminal
        4. Toggle stale entries off and on after terminal/Homebrew/app updates
        5. Restart the terminal or parent app, then try again

        Note: This is required because macOS protects the Messages database.
        For more details, see: https://github.com/steipete/imsg#permissions-troubleshooting
        """
    case .invalidISODate(let value):
      return "Invalid ISO8601 date: \(value)"
    case .invalidService(let value):
      return "Invalid service: \(value)"
    case .unsupportedService(let value):
      return "Unsupported service: \(value)"
    case .invalidChatTarget(let value):
      return "Invalid chat target: \(value)"
    case .appleScriptFailure(let message):
      return "AppleScript failed: \(message)"
    case .typingIndicatorFailed(let message):
      return "Typing indicator failed: \(message)"
    case .invalidReaction(let value):
      return """
        Invalid reaction: \(value)

        Valid reactions: love, like, dislike, laugh, emphasis, question
        """
    case .unsupportedReaction(let message):
      return "Unsupported reaction: \(message)"
    case .chatNotFound(let chatID):
      return "Chat not found: \(chatID)"
    }
  }

  public var description: String {
    errorDescription ?? "Unknown imsg error"
  }
}
