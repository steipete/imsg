import Commander
import Foundation
import IMsgCore

enum TypingCommand {
  static let spec = CommandSpec(
    name: "typing",
    abstract: "Send typing indicator to a chat",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "to", names: [.long("to")], help: "phone number or email"),
          .make(label: "chatID", names: [.long("chat-id")], help: "chat rowid"),
          .make(
            label: "chatIdentifier", names: [.long("chat-identifier")],
            help: "chat identifier (e.g. iMessage;-;+14155551212)"),
          .make(label: "chatGUID", names: [.long("chat-guid")], help: "chat guid"),
          .make(
            label: "duration", names: [.long("duration")],
            help: "how long to show typing (e.g. 5s, 3000ms); omit for start-only"),
          .make(
            label: "stop", names: [.long("stop")],
            help: "stop typing indicator instead of starting"),
          .make(
            label: "service", names: [.long("service")],
            help: "service to use: imessage|sms|auto"),
        ]
      )
    ),
    usageExamples: [
      "imsg typing --to +14155551212",
      "imsg typing --to +14155551212 --duration 5s",
      "imsg typing --to +14155551212 --stop true",
      "imsg typing --chat-identifier \"iMessage;-;+14155551212\"",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    storeFactory: @escaping (String) throws -> MessageStore = { try MessageStore(path: $0) }
  ) async throws {
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let recipient = values.option("to") ?? ""
    let chatID = values.optionInt64("chatID")
    let chatIdentifier = values.option("chatIdentifier") ?? ""
    let chatGUID = values.option("chatGUID") ?? ""
    let hasChatTarget = chatID != nil || !chatIdentifier.isEmpty || !chatGUID.isEmpty
    let stopFlag = values.option("stop") == "true"
    let durationRaw = values.option("duration") ?? ""

    if !hasChatTarget && recipient.isEmpty {
      throw ParsedValuesError.missingOption("to")
    }

    let resolvedIdentifier = try resolveIdentifier(
      dbPath: dbPath,
      recipient: recipient,
      chatID: chatID,
      chatIdentifier: chatIdentifier,
      chatGUID: chatGUID,
      service: values.option("service") ?? "imessage",
      storeFactory: storeFactory
    )

    if stopFlag {
      try TypingIndicator.stopTyping(chatIdentifier: resolvedIdentifier)
      if runtime.jsonOutput {
        try JSONLines.print(["status": "stopped"])
      } else {
        Swift.print("typing indicator stopped")
      }
      return
    }

    if !durationRaw.isEmpty {
      let seconds = try parseDurationToSeconds(durationRaw)
      try await TypingIndicator.typeForDuration(
        chatIdentifier: resolvedIdentifier, duration: seconds)
      if runtime.jsonOutput {
        try JSONLines.print(["status": "completed", "duration_s": "\(seconds)"])
      } else {
        Swift.print("typing indicator shown for \(durationRaw)")
      }
      return
    }

    try TypingIndicator.startTyping(chatIdentifier: resolvedIdentifier)
    if runtime.jsonOutput {
      try JSONLines.print(["status": "started"])
    } else {
      Swift.print("typing indicator started")
    }
  }

  private static func resolveIdentifier(
    dbPath: String,
    recipient: String,
    chatID: Int64?,
    chatIdentifier: String,
    chatGUID: String,
    service: String,
    storeFactory: (String) throws -> MessageStore
  ) throws -> String {
    if !chatGUID.isEmpty { return chatGUID }
    if !chatIdentifier.isEmpty { return chatIdentifier }
    if let chatID {
      let store = try storeFactory(dbPath)
      guard let info = try store.chatInfo(chatID: chatID) else {
        throw IMsgError.invalidChatTarget("Unknown chat id \(chatID)")
      }
      if !info.guid.isEmpty { return info.guid }
      return info.identifier
    }
    let svc = service == "sms" ? "SMS" : "iMessage"
    return "\(svc);-;\(recipient)"
  }

  private static func parseDurationToSeconds(_ raw: String) throws -> TimeInterval {
    let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
    if trimmed.hasSuffix("ms") {
      let numStr = String(trimmed.dropLast(2))
      guard let ms = Double(numStr), ms > 0 else {
        throw IMsgError.typingIndicatorFailed("Invalid duration: \(raw)")
      }
      return ms / 1000.0
    }
    if trimmed.hasSuffix("s") {
      let numStr = String(trimmed.dropLast(1))
      guard let s = Double(numStr), s > 0 else {
        throw IMsgError.typingIndicatorFailed("Invalid duration: \(raw)")
      }
      return s
    }
    guard let s = Double(trimmed), s > 0 else {
      throw IMsgError.typingIndicatorFailed("Invalid duration: \(raw). Use e.g. 5s or 3000ms")
    }
    return s
  }
}
