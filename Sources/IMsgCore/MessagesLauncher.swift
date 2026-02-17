import Foundation

/// Manages Messages.app lifecycle for DYLD injection.
///
/// Kills any running Messages.app, relaunches with `DYLD_INSERT_LIBRARIES`
/// pointing to the imsg-bridge dylib, then waits for the lock file that
/// confirms the dylib is ready for commands.
public final class MessagesLauncher: @unchecked Sendable {
  public static let shared = MessagesLauncher()

  // File-based IPC paths — must match the paths in IMsgInjected.m.
  // The dylib uses NSHomeDirectory() which resolves to the container path;
  // from outside we construct the full container path ourselves.
  private var commandFile: String {
    containerPath + "/.imsg-command.json"
  }

  private var responseFile: String {
    containerPath + "/.imsg-response.json"
  }

  private var lockFile: String {
    containerPath + "/.imsg-bridge-ready"
  }

  private var containerPath: String {
    NSHomeDirectory() + "/Library/Containers/com.apple.MobileSMS/Data"
  }

  private let messagesAppPath =
    "/System/Applications/Messages.app/Contents/MacOS/Messages"
  private let queue = DispatchQueue(label: "imsg.messages.launcher")
  private let lock = NSLock()

  /// Path to the dylib to inject.
  public var dylibPath: String = ".build/release/imsg-bridge-helper.dylib"

  private init() {
    let possiblePaths = [
      "/usr/local/lib/imsg-bridge-helper.dylib",
      ".build/release/imsg-bridge-helper.dylib",
      ".build/debug/imsg-bridge-helper.dylib",
    ]
    for path in possiblePaths {
      if FileManager.default.fileExists(atPath: path) {
        self.dylibPath = path
        break
      }
    }
  }

  /// Check if Messages.app is running with our dylib (lock file exists and responds to ping).
  public func isInjectedAndReady() -> Bool {
    guard FileManager.default.fileExists(atPath: lockFile) else {
      return false
    }
    do {
      let response = try sendCommandSync(action: "ping", params: [:])
      return response["success"] as? Bool == true
    } catch {
      return false
    }
  }

  /// Ensure Messages.app is running with our dylib injected.
  public func ensureRunning() throws {
    if isInjectedAndReady() { return }

    guard FileManager.default.fileExists(atPath: dylibPath) else {
      throw MessagesLauncherError.dylibNotFound(dylibPath)
    }

    killMessages()
    Thread.sleep(forTimeInterval: 1.0)

    // Clean up stale IPC files
    try? FileManager.default.removeItem(atPath: commandFile)
    try? FileManager.default.removeItem(atPath: responseFile)
    try? FileManager.default.removeItem(atPath: lockFile)

    try launchWithInjection()
    try waitForReady(timeout: 15.0)
  }

  /// Kill Messages.app if running.
  public func killMessages() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    task.arguments = ["Messages"]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try? task.run()
    task.waitUntilExit()
  }

  /// Send a command asynchronously.
  public func sendCommand(
    action: String, params: [String: Any]
  ) async throws -> [String: Any] {
    try ensureRunning()
    // Serialize params to JSON data to cross the Sendable boundary safely
    let paramsData = try JSONSerialization.data(withJSONObject: params, options: [])
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<[String: Any], Error>) in
      queue.async {
        do {
          let deserializedParams =
            (try? JSONSerialization.jsonObject(with: paramsData, options: []))
            as? [String: Any] ?? [:]
          let response = try self.sendCommandSync(action: action, params: deserializedParams)
          continuation.resume(returning: response)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  // MARK: - Private

  private func launchWithInjection() throws {
    let absoluteDylibPath =
      dylibPath.hasPrefix("/")
      ? dylibPath
      : FileManager.default.currentDirectoryPath + "/" + dylibPath

    guard FileManager.default.fileExists(atPath: absoluteDylibPath) else {
      throw MessagesLauncherError.dylibNotFound(absoluteDylibPath)
    }

    let task = Process()
    task.executableURL = URL(fileURLWithPath: messagesAppPath)

    var environment = ProcessInfo.processInfo.environment
    environment["DYLD_INSERT_LIBRARIES"] = absoluteDylibPath
    task.environment = environment

    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice

    do {
      try task.run()
    } catch {
      throw MessagesLauncherError.launchFailed(error.localizedDescription)
    }
  }

  private func waitForReady(timeout: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if FileManager.default.fileExists(atPath: lockFile) {
        Thread.sleep(forTimeInterval: 0.5)
        return
      }
      Thread.sleep(forTimeInterval: 0.5)
    }

    throw MessagesLauncherError.socketTimeout
  }

  private func sendCommandSync(
    action: String, params: [String: Any]
  ) throws -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }

    let command: [String: Any] = [
      "id": Int(Date().timeIntervalSince1970 * 1000),
      "action": action,
      "params": params,
    ]

    let jsonData = try JSONSerialization.data(withJSONObject: command, options: [])
    try jsonData.write(to: URL(fileURLWithPath: commandFile))

    let deadline = Date().addingTimeInterval(10.0)
    while Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)

      guard
        let responseData = try? Data(contentsOf: URL(fileURLWithPath: responseFile)),
        responseData.count > 2
      else { continue }

      // Check if command file was cleared (indicates processing completed)
      if let cmdData = try? Data(contentsOf: URL(fileURLWithPath: commandFile)),
        cmdData.count <= 2
      {
        guard
          let response = try? JSONSerialization.jsonObject(with: responseData, options: [])
            as? [String: Any]
        else {
          throw MessagesLauncherError.invalidResponse
        }
        // Clear response file
        try? "".write(toFile: responseFile, atomically: true, encoding: .utf8)
        return response
      }
    }

    throw MessagesLauncherError.socketError("Timeout waiting for response")
  }
}

public enum MessagesLauncherError: Error, CustomStringConvertible {
  case dylibNotFound(String)
  case launchFailed(String)
  case socketTimeout
  case socketError(String)
  case invalidResponse

  public var description: String {
    switch self {
    case .dylibNotFound(let path):
      return "imsg-bridge-helper.dylib not found at \(path). Build with: make build-dylib"
    case .launchFailed(let reason):
      return "Failed to launch Messages.app: \(reason)"
    case .socketTimeout:
      return
        "Timeout waiting for Messages.app to initialize. "
        + "Ensure SIP is disabled and Messages.app has necessary permissions."
    case .socketError(let reason):
      return "IPC error: \(reason)"
    case .invalidResponse:
      return "Invalid response from Messages.app helper"
    }
  }
}
