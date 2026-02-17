import Foundation

public enum IMCoreBridgeError: Error, CustomStringConvertible {
  case dylibNotFound
  case connectionFailed(String)
  case chatNotFound(String)
  case operationFailed(String)

  public var description: String {
    switch self {
    case .dylibNotFound:
      return "imsg-bridge-helper.dylib not found. Build with: make build-dylib"
    case .connectionFailed(let error):
      return "Connection to Messages.app failed: \(error)"
    case .chatNotFound(let id):
      return "Chat not found: \(id)"
    case .operationFailed(let reason):
      return "Operation failed: \(reason)"
    }
  }
}

/// Bridge to IMCore via DYLD injection into Messages.app.
///
/// Communicates with an injected dylib inside Messages.app via file-based IPC.
/// The dylib has full access to IMCore because it runs within the Messages.app
/// context with proper entitlements.
///
/// Requires:
/// - SIP disabled (for `DYLD_INSERT_LIBRARIES` on system apps)
/// - The `imsg-bridge-helper.dylib` built via `make build-dylib`
public final class IMCoreBridge: @unchecked Sendable {
  public static let shared = IMCoreBridge()

  private let launcher = MessagesLauncher.shared

  /// Whether the dylib exists on disk (does not check if Messages.app is running).
  public var isAvailable: Bool {
    let possiblePaths = [
      "/usr/local/lib/imsg-bridge-helper.dylib",
      ".build/release/imsg-bridge-helper.dylib",
      ".build/debug/imsg-bridge-helper.dylib",
    ]
    return possiblePaths.contains { FileManager.default.fileExists(atPath: $0) }
  }

  private init() {}

  // MARK: - Commands

  /// Set typing indicator for a conversation.
  public func setTyping(for handle: String, typing: Bool) async throws {
    let params: [String: Any] = [
      "handle": handle,
      "typing": typing,
    ]
    _ = try await sendCommand(action: "typing", params: params)
  }

  /// Mark all messages as read in a conversation.
  public func markAsRead(handle: String) async throws {
    _ = try await sendCommand(action: "read", params: ["handle": handle])
  }

  /// List all available chats (for debugging).
  public func listChats() async throws -> [[String: Any]] {
    let response = try await sendCommand(action: "list_chats", params: [:])
    return response["chats"] as? [[String: Any]] ?? []
  }

  /// Get detailed status from the injected helper.
  public func getStatus() async throws -> [String: Any] {
    return try await sendCommand(action: "status", params: [:])
  }

  /// Check availability and return a diagnostic message.
  public func checkAvailability() -> (available: Bool, message: String) {
    let possiblePaths = [
      "/usr/local/lib/imsg-bridge-helper.dylib",
      ".build/release/imsg-bridge-helper.dylib",
      ".build/debug/imsg-bridge-helper.dylib",
    ]

    var dylibPath: String?
    for path in possiblePaths {
      if FileManager.default.fileExists(atPath: path) {
        dylibPath = path
        break
      }
    }

    guard dylibPath != nil else {
      return (
        false,
        """
        imsg-bridge-helper.dylib not found. To build:
        1. make build-dylib
        2. Restart imsg

        Note: Advanced features require:
        - SIP disabled (for DYLD injection)
        - Full Disk Access granted to Terminal
        """
      )
    }

    if launcher.isInjectedAndReady() {
      return (true, "Connected to Messages.app. IMCore features available.")
    }

    do {
      try launcher.ensureRunning()
      return (true, "Messages.app launched with injection. IMCore features available.")
    } catch let error as MessagesLauncherError {
      return (false, error.description)
    } catch {
      return (false, "Failed to connect to Messages.app: \(error.localizedDescription)")
    }
  }

  // MARK: - Private

  private func sendCommand(
    action: String, params: [String: Any]
  ) async throws -> [String: Any] {
    do {
      let response = try await launcher.sendCommand(action: action, params: params)

      if response["success"] as? Bool == true {
        return response
      }

      let error = response["error"] as? String ?? "Unknown error"
      if error.contains("Chat not found") {
        let handle = params["handle"] as? String ?? "unknown"
        throw IMCoreBridgeError.chatNotFound(handle)
      }
      throw IMCoreBridgeError.operationFailed(error)
    } catch let error as MessagesLauncherError {
      throw IMCoreBridgeError.connectionFailed(error.description)
    }
  }
}
