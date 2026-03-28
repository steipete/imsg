import Commander
import Foundation
import IMsgCore

enum ChatsCommand {
  static let spec = CommandSpec(
    name: "chats",
    abstract: "List recent conversations",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "limit", names: [.long("limit")], help: "Number of chats to list")
        ]
      )
    ),
    usageExamples: [
      "imsg chats --limit 5",
      "imsg chats --limit 5 --json",
    ]
  ) { values, runtime in
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let limit = values.optionInt("limit") ?? 20
    let store = try MessageStore(path: dbPath)
    let contacts = await ContactResolver.create()
    let chats = try store.listChats(limit: limit)

    for chat in chats {
      let needsResolve = chat.name.isEmpty || chat.name == chat.identifier
      let contactName = needsResolve ? contacts.displayName(for: chat.identifier) : nil

      if runtime.jsonOutput {
        try StdoutWriter.writeJSONLine(ChatPayload(chat: chat, contactName: contactName))
      } else {
        let last = CLIISO8601.format(chat.lastMessageAt)
        let displayName = contactName ?? (chat.name.isEmpty ? chat.identifier : chat.name)
        StdoutWriter.writeLine("[\(chat.id)] \(displayName) (\(chat.identifier)) last=\(last)")
      }
    }
  }
}
