import Commander
import Foundation
import IMsgCore

enum SendCommand {
  static let spec = CommandSpec(
    name: "send",
    abstract: "Send a message (text and/or attachment)",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "to", names: [.long("to")], help: "phone number or email"),
          .make(label: "chatID", names: [.long("chat-id")], help: "chat rowid"),
          .make(
            label: "chatIdentifier", names: [.long("chat-identifier")],
            help: "chat identifier (e.g. iMessage;+;chat...)"),
          .make(label: "chatGUID", names: [.long("chat-guid")], help: "chat guid"),
          .make(label: "text", names: [.long("text")], help: "message body"),
          .make(label: "file", names: [.long("file")], help: "path to attachment"),
          .make(
            label: "service", names: [.long("service")], help: "service to use: imessage|sms|auto"),
          .make(
            label: "region", names: [.long("region")],
            help: "default region for phone normalization"),
        ]
      )
    ),
    usageExamples: [
      "imsg send --to +14155551212 --text \"hi\"",
      "imsg send --to +14155551212 --text \"hi\" --file ~/Desktop/pic.jpg --service imessage",
      "imsg send --chat-id 1 --text \"hi\"",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    sendMessage: @escaping (MessageSendOptions) throws -> Void = { try MessageSender().send($0) },
    storeFactory: @escaping (String) throws -> MessageStore = { try MessageStore(path: $0) }
  ) async throws {
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let input = ChatTargetInput(
      recipient: values.option("to") ?? "",
      chatID: values.optionInt64("chatID"),
      chatIdentifier: values.option("chatIdentifier") ?? "",
      chatGUID: values.option("chatGUID") ?? ""
    )
    try ChatTargetResolver.validateRecipientRequirements(
      input: input,
      mixedTargetError: ParsedValuesError.invalidOption("to"),
      missingRecipientError: ParsedValuesError.missingOption("to")
    )

    let text = values.option("text") ?? ""
    let file = values.option("file") ?? ""
    if text.isEmpty && file.isEmpty {
      throw ParsedValuesError.missingOption("text or file")
    }
    let serviceRaw = values.option("service") ?? "auto"
    guard let service = MessageService(rawValue: serviceRaw) else {
      throw IMsgError.invalidService(serviceRaw)
    }
    let region = values.option("region") ?? "US"

    let resolvedTarget = try await ChatTargetResolver.resolveChatTarget(
      input: input,
      lookupChat: { chatID in
        let store = try storeFactory(dbPath)
        return try store.chatInfo(chatID: chatID)
      },
      unknownChatError: { chatID in
        IMsgError.invalidChatTarget("Unknown chat id \(chatID)")
      }
    )
    if input.hasChatTarget && resolvedTarget.preferredIdentifier == nil {
      throw IMsgError.invalidChatTarget("Missing chat identifier or guid")
    }

    try sendMessage(
      MessageSendOptions(
        recipient: input.recipient,
        text: text,
        attachmentPath: file,
        service: service,
        region: region,
        chatIdentifier: resolvedTarget.chatIdentifier,
        chatGUID: resolvedTarget.chatGUID
      ))

    if runtime.jsonOutput {
      try StdoutWriter.writeJSONLine(["status": "sent"])
    } else {
      StdoutWriter.writeLine("sent")
    }
  }
}
