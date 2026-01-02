import Carbon
import Foundation
import ScriptingBridge

public enum MessageService: String, Sendable, CaseIterable {
  case auto
  case imessage
  case sms
}

public struct MessageSendOptions: Sendable {
  public var recipient: String
  public var text: String
  public var attachmentPath: String
  public var service: MessageService
  public var region: String
  public var chatIdentifier: String
  public var chatGUID: String
  public var replyToGUID: String

  public init(
    recipient: String,
    text: String = "",
    attachmentPath: String = "",
    service: MessageService = .auto,
    region: String = "US",
    chatIdentifier: String = "",
    chatGUID: String = "",
    replyToGUID: String = ""
  ) {
    self.recipient = recipient
    self.text = text
    self.attachmentPath = attachmentPath
    self.service = service
    self.region = region
    self.chatIdentifier = chatIdentifier
    self.chatGUID = chatGUID
    self.replyToGUID = replyToGUID
  }
}

public struct MessageSender {
  private let normalizer: PhoneNumberNormalizer
  private let runner: (String, [String]) throws -> Void

  public init() {
    self.normalizer = PhoneNumberNormalizer()
    self.runner = MessageSender.runAppleScript
  }

  init(runner: @escaping (String, [String]) throws -> Void) {
    self.normalizer = PhoneNumberNormalizer()
    self.runner = runner
  }

  public func send(_ options: MessageSendOptions) throws {
    var resolved = options
    let chatTarget = resolved.chatIdentifier.isEmpty ? resolved.chatGUID : resolved.chatIdentifier
    let useChat = !chatTarget.isEmpty
    if !resolved.replyToGUID.isEmpty {
      throw IMsgError.replyToNotSupported("Messages AppleScript does not support reply-to.")
    }
    if useChat == false {
      if resolved.region.isEmpty { resolved.region = "US" }
      resolved.recipient = normalizer.normalize(resolved.recipient, region: resolved.region)
      if resolved.service == .auto { resolved.service = .imessage }
    } else if chatTarget.isEmpty {
      throw IMsgError.invalidChatTarget("Missing chat identifier or guid")
    }

    let script = appleScript()
    let arguments = [
      resolved.recipient,
      resolved.text,
      resolved.service.rawValue,
      resolved.attachmentPath,
      resolved.attachmentPath.isEmpty ? "0" : "1",
      chatTarget,
      useChat ? "1" : "0",
    ]

    try runner(script, arguments)
  }

  private func appleScript() -> String {
    return """
      on run argv
          set theRecipient to item 1 of argv
          set theMessage to item 2 of argv
          set theService to item 3 of argv
          set theFilePath to item 4 of argv
          set useAttachment to item 5 of argv
          set chatId to item 6 of argv
          set useChat to item 7 of argv

          tell application "Messages"
              if useChat is "1" then
                  set targetChat to chat id chatId
                  if theMessage is not "" then
                      send theMessage to targetChat
                  end if
                  if useAttachment is "1" then
                      set theFile to POSIX file theFilePath as alias
                      send theFile to targetChat
                  end if
              else
                  if theService is "sms" then
                      set targetService to first service whose service type is SMS
                  else
                      set targetService to first service whose service type is iMessage
                  end if

                  set targetBuddy to buddy theRecipient of targetService
                  if theMessage is not "" then
                      send theMessage to targetBuddy
                  end if
                  if useAttachment is "1" then
                      set theFile to POSIX file theFilePath as alias
                      send theFile to targetBuddy
                  end if
              end if
          end tell
      end run
      """
  }

  private static func runAppleScript(source: String, arguments: [String]) throws {
    guard let script = NSAppleScript(source: source) else {
      throw IMsgError.appleScriptFailure("Unable to compile AppleScript")
    }
    var errorInfo: NSDictionary?
    let event = NSAppleEventDescriptor(
      eventClass: AEEventClass(kASAppleScriptSuite),
      eventID: AEEventID(kASSubroutineEvent),
      targetDescriptor: nil,
      returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID)
    )
    event.setParam(
      NSAppleEventDescriptor(string: "run"), forKeyword: AEKeyword(keyASSubroutineName))
    let list = NSAppleEventDescriptor.list()
    for (index, value) in arguments.enumerated() {
      list.insert(NSAppleEventDescriptor(string: value), at: index + 1)
    }
    event.setParam(list, forKeyword: keyDirectObject)
    script.executeAppleEvent(event, error: &errorInfo)
    if let errorInfo {
      if shouldFallbackToOsascript(errorInfo: errorInfo) {
        try runOsascript(source: source, arguments: arguments)
        return
      }
      let message =
        (errorInfo[NSAppleScript.errorMessage] as? String) ?? "Unknown AppleScript error"
      throw IMsgError.appleScriptFailure(message)
    }
  }

  private static func shouldFallbackToOsascript(errorInfo: NSDictionary) -> Bool {
    if let errorNumber = errorInfo[NSAppleScript.errorNumber] as? Int, errorNumber == -1743 {
      return true
    }
    if errorInfo[NSAppleScript.errorMessage] == nil {
      return true
    }
    if let message = errorInfo[NSAppleScript.errorMessage] as? String {
      let lower = message.lowercased()
      return lower.contains("not authorized") || lower.contains("not authorised")
    }
    return false
  }

  private static func runOsascript(source: String, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-l", "AppleScript", "-"] + arguments
    let stdinPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardError = stderrPipe
    try process.run()
    if let data = source.data(using: .utf8) {
      stdinPipe.fileHandleForWriting.write(data)
    }
    stdinPipe.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
      let message = String(data: data, encoding: .utf8) ?? "Unknown osascript error"
      throw IMsgError.appleScriptFailure(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }
}
