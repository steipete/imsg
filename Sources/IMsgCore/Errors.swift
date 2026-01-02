import Foundation

public enum IMsgError: LocalizedError, Sendable {
  case permissionDenied(path: String, underlying: Error)
  case invalidISODate(String)
  case invalidService(String)
  case invalidChatTarget(String)
  case replyToNotSupported(String)
  case appleScriptFailure(String)

  public var errorDescription: String? {
    switch self {
    case .permissionDenied(let path, let underlying):
      return """
        \(underlying)

        ⚠️  Permission Error: Cannot access Messages database

        The Messages database at \(path) requires Full Disk Access permission.

        To fix:
        1. Open System Settings → Privacy & Security → Full Disk Access
        2. Add your terminal application (Terminal.app, iTerm, etc.)
        3. Restart your terminal
        4. Try again

        Note: This is required because macOS protects the Messages database.
        For more details, see: https://github.com/steipete/imsg#permissions-troubleshooting
        """
    case .invalidISODate(let value):
      return "Invalid ISO8601 date: \(value)"
    case .invalidService(let value):
      return "Invalid service: \(value)"
    case .invalidChatTarget(let value):
      return "Invalid chat target: \(value)"
    case .replyToNotSupported(let value):
      return "Reply-to not supported: \(value)"
    case .appleScriptFailure(let message):
      return "AppleScript failed: \(message)"
    }
  }
}
