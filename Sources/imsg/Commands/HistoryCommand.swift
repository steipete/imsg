import Commander
import Foundation
import IMsgCore

enum HistoryCommand {
  static let spec = CommandSpec(
    name: "history",
    abstract: "Show recent messages for a chat",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chatID", names: [.long("chat-id")], help: "chat rowid from 'imsg chats'"),
          .make(label: "limit", names: [.long("limit")], help: "Number of messages to show"),
          .make(
            label: "participants", names: [.long("participants")],
            help: "filter by participant handles", parsing: .upToNextOption),
          .make(label: "start", names: [.long("start")], help: "ISO8601 start (inclusive)"),
          .make(label: "end", names: [.long("end")], help: "ISO8601 end (exclusive)"),
        ],
        flags: [
          .make(
            label: "attachments", names: [.long("attachments")], help: "include attachment metadata"
          )
        ]
      )
    ),
    usageExamples: [
      "imsg history --chat-id 1 --limit 10 --attachments",
      "imsg history --chat-id 1 --start 2025-01-01T00:00:00Z --json",
    ]
  ) { values, runtime in
    guard let chatID = values.optionInt64("chatID") else {
      throw ParsedValuesError.missingOption("chat-id")
    }
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let limit = values.optionInt("limit") ?? 50
    let showAttachments = values.flag("attachments")
    let participants = values.optionValues("participants")
      .flatMap { $0.split(separator: ",").map { String($0) } }
      .filter { !$0.isEmpty }
    let filter = try MessageFilter.fromISO(
      participants: participants,
      startISO: values.option("start"),
      endISO: values.option("end")
    )

    let store = try MessageStore(path: dbPath)
    let filtered = try store.messages(chatID: chatID, limit: limit, filter: filter)
    let resolver = ContactResolver()

    // Batch resolve all unique senders
    let uniqueSenders = Array(Set(filtered.map(\.sender)))
    let resolvedNames = resolver.resolve(uniqueSenders)

    // Print header (CLI only)
    if !runtime.jsonOutput {
      let chatInfo = try store.chatInfo(chatID: chatID)
      let participantHandles = try store.participants(chatID: chatID)
      let identifier = chatInfo?.identifier ?? ""
      let guid = chatInfo?.guid ?? ""
      let dbName = chatInfo?.name ?? ""
      let service = chatInfo?.service ?? ""
      let isGroup = isGroupHandle(identifier: identifier, guid: guid)
      let displayName = resolver.displayNameForChat(
        identifier: identifier, name: dbName, participants: participantHandles
      )

      if isGroup {
        StdoutWriter.writeLine("\(displayName) \u{00B7} \(service)")
        // Show participant list only if we have a DB name (otherwise displayName IS the participants)
        if !dbName.isEmpty {
          let resolved = resolver.resolve(participantHandles)
          let names = participantHandles.map { resolved[$0] ?? $0 }
          StdoutWriter.writeLine("  \(names.joined(separator: ", "))")
        }
      } else {
        let resolvedChat = resolver.resolve(identifier)
        if let resolvedChat, resolvedChat != identifier {
          StdoutWriter.writeLine("Chat with \(resolvedChat) (\(identifier)) \u{00B7} \(service)")
        } else {
          StdoutWriter.writeLine("Chat with \(displayName) \u{00B7} \(service)")
        }
      }
      StdoutWriter.writeLine(String(repeating: "\u{2500}", count: 49))
    }

    for message in filtered {
      let senderName = message.isFromMe
        ? "You"
        : (resolvedNames[message.sender] ?? message.sender)

      if runtime.jsonOutput {
        let attachments = try store.attachments(for: message.rowID)
        let reactions = try store.reactions(for: message.rowID)
        // Resolve any reaction senders not already in the batch
        let reactionNames = resolver.resolve(reactions.map(\.sender))
        let allResolved = resolvedNames.merging(reactionNames) { existing, _ in existing }
        let payload = MessagePayload(
          message: message,
          attachments: attachments,
          reactions: reactions,
          senderDisplayName: resolvedNames[message.sender],
          resolvedNames: allResolved
        )
        try StdoutWriter.writeJSONLine(payload)
        continue
      }

      let direction = message.isFromMe ? "sent" : "recv"
      let timestamp = CLIISO8601.format(message.date)
      StdoutWriter.writeLine("\(timestamp) [\(direction)] \(senderName): \(message.text)")
      if message.attachmentsCount > 0 {
        if showAttachments {
          let metas = try store.attachments(for: message.rowID)
          for meta in metas {
            let name = displayName(for: meta)
            StdoutWriter.writeLine(
              "  attachment: name=\(name) mime=\(meta.mimeType) missing=\(meta.missing) path=\(meta.originalPath)"
            )
          }
        } else {
          StdoutWriter.writeLine(
            "  (\(message.attachmentsCount) attachment\(pluralSuffix(for: message.attachmentsCount)))"
          )
        }
      }
    }
  }
}
