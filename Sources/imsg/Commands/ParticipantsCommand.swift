import Commander
import Foundation
import IMsgCore

enum ParticipantsCommand {
  static let spec = CommandSpec(
    name: "participants",
    abstract: "List participants in a chat",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chatID", names: [.long("chat-id")], help: "chat rowid from 'imsg chats'")
        ]
      )
    ),
    usageExamples: [
      "imsg participants --chat-id 42",
      "imsg participants --chat-id 42 --json",
    ]
  ) { values, runtime in
    guard let chatID = values.optionInt64("chatID") else {
      throw ParsedValuesError.missingOption("chat-id")
    }
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let store = try MessageStore(path: dbPath)

    guard let info = try store.chatInfo(chatID: chatID) else {
      throw ParsedValuesError.invalidOption("chat-id: no chat found with id \(chatID)")
    }

    let participantHandles = try store.participants(chatID: chatID)
    let resolver = ContactResolver()
    let resolved = resolver.resolve(participantHandles)
    let isGroup = isGroupHandle(identifier: info.identifier, guid: info.guid)
    let displayName = resolver.displayNameForChat(
      identifier: info.identifier, name: info.name, participants: participantHandles
    )

    if runtime.jsonOutput {
      let payloads = participantHandles.map {
        ParticipantPayload(identifier: $0, displayName: resolved[$0])
      }
      let response = ParticipantsResponse(
        chatID: chatID,
        identifier: info.identifier,
        displayName: displayName,
        service: info.service,
        isGroup: isGroup,
        participants: payloads
      )
      try StdoutWriter.writeJSONLine(response)
      return
    }

    // CLI output
    if isGroup {
      StdoutWriter.writeLine("\(displayName) \u{00B7} \(info.service)")
    } else {
      StdoutWriter.writeLine("Chat with \(displayName) \u{00B7} \(info.service)")
    }
    StdoutWriter.writeLine("")
    for handle in participantHandles {
      if let name = resolved[handle] {
        let padded = name.padding(toLength: max(name.count, 24), withPad: " ", startingAt: 0)
        StdoutWriter.writeLine("  \(padded)\(handle)")
      } else {
        StdoutWriter.writeLine("  \(handle)")
      }
    }
  }
}
