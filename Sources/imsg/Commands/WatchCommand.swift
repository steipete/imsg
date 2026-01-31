import Commander
import Foundation
import IMsgCore

enum WatchCommand {
  static let spec = CommandSpec(
    name: "watch",
    abstract: "Stream incoming messages",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chatID", names: [.long("chat-id")], help: "limit to chat rowid"),
          .make(
            label: "debounce", names: [.long("debounce")],
            help: "debounce interval for filesystem events (e.g. 250ms)"),
          .make(
            label: "sinceRowID", names: [.long("since-rowid")],
            help: "start watching after this rowid"),
          .make(
            label: "participants", names: [.long("participants")],
            help: "filter by participant handles", parsing: .upToNextOption),
          .make(label: "start", names: [.long("start")], help: "ISO8601 start (inclusive)"),
          .make(label: "end", names: [.long("end")], help: "ISO8601 end (exclusive)"),
        ],
        flags: [
          .make(
            label: "attachments", names: [.long("attachments")], help: "include attachment metadata"
          ),
          .make(
            label: "reactions", names: [.long("reactions")], 
            help: "include reaction events (tapback add/remove) in the stream"
          )
        ]
      )
    ),
    usageExamples: [
      "imsg watch --chat-id 1 --attachments --debounce 250ms",
      "imsg watch --chat-id 1 --participants +15551234567",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    storeFactory: @escaping (String) throws -> MessageStore = { try MessageStore(path: $0) },
    streamProvider:
      @escaping (
        MessageWatcher,
        Int64?,
        Int64?,
        MessageWatcherConfiguration
      ) -> AsyncThrowingStream<Message, Error> = { watcher, chatID, sinceRowID, config in
        watcher.stream(chatID: chatID, sinceRowID: sinceRowID, configuration: config)
      }
  ) async throws {
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let chatID = values.optionInt64("chatID")
    let debounceString = values.option("debounce") ?? "250ms"
    guard let debounceInterval = DurationParser.parse(debounceString) else {
      throw ParsedValuesError.invalidOption("debounce")
    }
    let sinceRowID = values.optionInt64("sinceRowID")
    let showAttachments = values.flag("attachments")
    let includeReactions = values.flag("reactions")
    let participants = values.optionValues("participants")
      .flatMap { $0.split(separator: ",").map { String($0) } }
      .filter { !$0.isEmpty }
    let filter = try MessageFilter.fromISO(
      participants: participants,
      startISO: values.option("start"),
      endISO: values.option("end")
    )

    let store = try storeFactory(dbPath)
    let watcher = MessageWatcher(store: store)
    let config = MessageWatcherConfiguration(
      debounceInterval: debounceInterval,
      batchLimit: 100,
      includeReactions: includeReactions
    )

    let stream = streamProvider(watcher, chatID, sinceRowID, config)
    for try await message in stream {
      if !filter.allows(message) {
        continue
      }
      if runtime.jsonOutput {
        let attachments = try store.attachments(for: message.rowID)
        let reactions = try store.reactions(for: message.rowID)
        let payload = MessagePayload(
          message: message,
          attachments: attachments,
          reactions: reactions
        )
        try JSONLines.print(payload)
        continue
      }
      let direction = message.isFromMe ? "sent" : "recv"
      let timestamp = CLIISO8601.format(message.date)
      
      // Format reaction events differently
      if message.isReaction, let reactionType = message.reactionType {
        let action = (message.isReactionAdd ?? true) ? "added" : "removed"
        let targetGUID = message.reactedToGUID ?? "unknown"
        Swift.print("\(timestamp) [\(direction)] \(message.sender) \(action) \(reactionType.emoji) reaction to \(targetGUID)")
        continue
      }
      
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
