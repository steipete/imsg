import Commander
import Foundation
import IMsgCore

enum TypingCommand {
  static let spec = CommandSpec(
    name: "typing",
    abstract: "Send typing indicator",
    discussion: "Show or hide the typing indicator in a conversation using IMCore.",
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
            label: "service", names: [.long("service")],
            help: "service: imessage|sms (default imessage)"),
          .make(label: "duration", names: [.long("duration")], help: "duration (e.g. 5s, 10s)"),
          .make(label: "stop", names: [.long("stop")], help: "stop typing (true to stop)"),
          .make(
            label: "region", names: [.long("region")],
            help: "default region for phone normalization"),
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
    let stopTyping = values.option("stop")?.lowercased() == "true"
    let durationStr = values.option("duration")
    let service = values.option("service") ?? "imessage"
    let region = values.option("region") ?? "US"

    var resolved = chatGUID.isEmpty ? chatIdentifier : chatGUID
    if resolved.isEmpty && !recipient.isEmpty {
      let normalizer = PhoneNumberNormalizer()
      let normalized = normalizer.normalize(recipient, region: region)
      let svc = service.lowercased() == "sms" ? "SMS" : "iMessage"
      resolved = "\(svc);-;\(normalized)"
    }

    if let chatID {
      let store = try storeFactory(dbPath)
      guard let info = try store.chatInfo(chatID: chatID) else {
        throw IMsgError.invalidChatTarget("Unknown chat id \(chatID)")
      }
      resolved = info.guid.isEmpty ? info.identifier : info.guid
    }

    if resolved.isEmpty {
      throw IMsgError.invalidChatTarget(
        "Provide --to, --chat-id, --chat-identifier, or --chat-guid")
    }

    if stopTyping {
      try TypingIndicator.stopTyping(chatIdentifier: resolved)
    } else if let durationStr, let seconds = parseDuration(durationStr) {
      try await TypingIndicator.typeForDuration(chatIdentifier: resolved, duration: seconds)
    } else {
      try TypingIndicator.startTyping(chatIdentifier: resolved)
    }

    if runtime.jsonOutput {
      let action = stopTyping ? "stopped" : "started"
      try JSONLines.print(["status": action, "chat_identifier": resolved])
    } else {
      Swift.print(stopTyping ? "stopped" : "started")
    }
  }

  private static func parseDuration(_ value: String) -> TimeInterval? {
    let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
    if trimmed.hasSuffix("s") {
      return Double(trimmed.dropLast())
    }
    if trimmed.hasSuffix("ms") {
      if let ms = Double(trimmed.dropLast(2)) {
        return ms / 1000.0
      }
    }
    return Double(trimmed)
  }
}
