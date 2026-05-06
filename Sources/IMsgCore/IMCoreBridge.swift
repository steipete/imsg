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
/// The dylib has access to IMCore when Messages.app accepts the injection.
/// macOS 26/Tahoe can still block this path with library validation/private
/// entitlement checks.
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
    _ = try await invokeBridge(action: .typing, params: params)
  }

  /// Mark all messages as read in a conversation.
  public func markAsRead(handle: String) async throws {
    _ = try await invokeBridge(action: .read, params: ["handle": handle])
  }

  /// List all available chats (for debugging).
  public func listChats() async throws -> [[String: Any]] {
    let response = try await invokeBridge(action: .listChats, params: [:])
    return response["chats"] as? [[String: Any]] ?? []
  }

  /// Get detailed status from the injected helper.
  public func getStatus() async throws -> [String: Any] {
    return try await invokeBridge(action: .status, params: [:])
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

    switch MessagesLauncher.currentSIPStatus() {
    case .enabled:
      return (
        false,
        """
        System Integrity Protection (SIP) is enabled.
        Advanced IMCore features are intentionally disabled.

        To enable advanced features:
        1. Disable SIP in Recovery mode (`csrutil disable`)
        2. Run `make build-dylib`
        3. Run `imsg launch`
        """
      )
    case .unknown(let details):
      return (
        false,
        """
        Unable to determine SIP status. Refusing to auto-inject Messages.app.
        Details: \(details)
        """
      )
    case .disabled:
      break
    }

    if launcher.hasReadyLockFile() {
      return (true, "Connected to Messages.app. IMCore features available.")
    }

    return (
      false,
      """
      SIP is disabled and the helper dylib is present, but Messages.app is not currently injected.
      Run `imsg launch` to enable advanced IMCore features.

      Note: macOS 26/Tahoe can still block advanced IMCore features through
      library validation or imagent private entitlement checks. Basic send,
      history, and watch commands do not use this path.
      """
    )
  }

  // MARK: - Private

  private func invokeBridge(
    action: BridgeAction, params: [String: Any]
  ) async throws -> [String: Any] {
    do {
      return try await IMsgBridgeClient.shared.invoke(action: action, params: params)
    } catch let error as IMsgBridgeError {
      switch error {
      case .dylibReturnedError(let message):
        if message.contains("Chat not found") {
          let handle = params["handle"] as? String ?? "unknown"
          throw IMCoreBridgeError.chatNotFound(handle)
        }
        throw IMCoreBridgeError.operationFailed(message)
      default:
        throw IMCoreBridgeError.connectionFailed(error.description)
      }
    } catch let error as MessagesLauncherError {
      throw IMCoreBridgeError.connectionFailed(error.description)
    }
  }
}
