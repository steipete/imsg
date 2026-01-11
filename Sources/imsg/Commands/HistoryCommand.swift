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

    if runtime.jsonOutput {
      for message in filtered {
        let attachments = try store.attachments(for: message.rowID)
        let reactions = try store.reactions(for: message.rowID)
        let payload = MessagePayload(
          message: message,
          attachments: attachments,
          reactions: reactions
        )
        try JSONLines.print(payload)
      }
      return
    }

    for message in filtered {
      let direction = message.isFromMe ? "sent" : "recv"
      let timestamp = CLIISO8601.format(message.date)
      Swift.print("\(timestamp) [\(direction)] \(message.sender): \(message.text)")
      if message.attachmentsCount > 0 {
        if showAttachments {
          let metas = try store.attachments(for: message.rowID)
          for meta in metas {
            let name = displayName(for: meta)
            Swift.print(
              "  attachment: name=\(name) mime=\(meta.mimeType) missing=\(meta.missing) path=\(meta.originalPath)"
            )
          }
        } else {
          Swift.print(
            "  (\(message.attachmentsCount) attachment\(pluralSuffix(for: message.attachmentsCount)))"
          )
        }
      }
    }
  }
}
