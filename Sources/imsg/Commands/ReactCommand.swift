import Commander
import Foundation
import IMsgCore

enum ReactCommand {
  private enum Automation {
    static let activateDelaySeconds = 0.3
    static let openSearchDelaySeconds = 0.15
    static let searchResultDelaySeconds = 0.25
    static let openTapbackDelaySeconds = 0.35
    static let reactionMenuDelaySeconds = 0.2
    static let customConfirmDelaySeconds = 0.1
    static let returnKeyCode = 36

    static let searchKey = "f"
    static let selectAllKey = "a"
    static let openTapbackKey = "t"
  }

  static let spec = CommandSpec(
    name: "react",
    abstract: "Send a tapback reaction to the most recent message",
    discussion: """
      Sends a tapback reaction to the most recent incoming message in the specified chat.

      IMPORTANT LIMITATIONS:
      - Only reacts to the MOST RECENT incoming message in the conversation
      - Requires Messages.app to be running
      - Uses UI automation (System Events) which requires accessibility permissions

      Reaction types:
        love (❤️), like (👍), dislike (👎), laugh (😂), emphasis (‼️), question (❓)
        Or any single emoji for custom reactions (iOS 17+ / macOS 14+)
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chatID", names: [.long("chat-id")], help: "chat rowid to react in"),
          .make(
            label: "reaction", names: [.long("reaction"), .short("r")],
            help: "reaction type: love, like, dislike, laugh, emphasis, question, or emoji",
          ),
        ],
        flags: [],
      ),
    ),
    usageExamples: [
      "imsg react --chat-id 1 --reaction like",
      "imsg react --chat-id 1 -r love",
      "imsg react --chat-id 1 -r 🎉",
    ],
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    storeFactory: @escaping (String) throws -> MessageStore = { try MessageStore(path: $0) },
    appleScriptRunner: @escaping (String, [String]) throws -> Void = { source, arguments in
      try runAppleScript(source, arguments: arguments)
    },
  ) async throws {
    guard let chatID = values.optionInt64("chatID") else {
      throw ParsedValuesError.missingOption("chat-id")
    }
    guard let reactionString = values.option("reaction") else {
      throw ParsedValuesError.missingOption("reaction")
    }
    guard let reactionType = ReactionType.parse(reactionString) else {
      throw IMsgError.invalidReaction(reactionString)
    }
    if case .custom(let emoji) = reactionType, !isSingleEmoji(emoji) {
      throw IMsgError.invalidReaction(reactionString)
    }

    // Get chat info for the GUID
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let store = try storeFactory(dbPath)
    guard let chatInfo = try store.chatInfo(chatID: chatID) else {
      throw IMsgError.chatNotFound(chatID: chatID)
    }

    let chatLookup = preferredChatLookup(chatInfo: chatInfo)

    // Send the reaction via AppleScript + System Events
    try sendReaction(
      reactionType: reactionType,
      chatGUID: chatInfo.guid,
      chatLookup: chatLookup,
      appleScriptRunner: appleScriptRunner,
    )

    if runtime.jsonOutput {
      let result = ReactResult(
        success: true,
        chatID: chatID,
        reactionType: reactionType.name,
        reactionEmoji: reactionType.emoji,
      )
      try JSONLines.print(result)
    } else {
      print("Sent \(reactionType.emoji) reaction to chat \(chatID)")
    }
  }

  private static func sendReaction(
    reactionType: ReactionType,
    chatGUID: String,
    chatLookup: String,
    appleScriptRunner: @escaping (String, [String]) throws -> Void,
  ) throws {
    let reactionSelection: String
    let shouldConfirmCustomSelection: String
    switch reactionType {
    case .love, .like, .dislike, .laugh, .emphasis, .question:
      reactionSelection = "\(tapbackKeyNumber(for: reactionType))"
      shouldConfirmCustomSelection = "0"
    case .custom:
      reactionSelection = reactionType.emoji
      shouldConfirmCustomSelection = "1"
    }

    try appleScriptRunner(
      reactionScript(),
      [chatGUID, chatLookup, reactionSelection, shouldConfirmCustomSelection],
    )
  }

  private static func reactionScript() -> String {
    """
    on run argv
      set chatGUID to item 1 of argv
      set chatLookup to item 2 of argv
      set reactionSelection to item 3 of argv
      set shouldConfirmSelection to item 4 of argv

      tell application "Messages"
        activate
        set targetChat to chat id chatGUID
      end tell

      delay \(Automation.activateDelaySeconds)

      tell application "System Events"
        tell process "Messages"
          keystroke "\(Automation.searchKey)" using command down
          delay \(Automation.openSearchDelaySeconds)
          keystroke "\(Automation.selectAllKey)" using command down
          keystroke chatLookup
          delay \(Automation.searchResultDelaySeconds)
          key code \(Automation.returnKeyCode)
          delay \(Automation.openTapbackDelaySeconds)
          keystroke "\(Automation.openTapbackKey)" using command down
          delay \(Automation.reactionMenuDelaySeconds)
          keystroke reactionSelection
          if shouldConfirmSelection is "1" then
            delay \(Automation.customConfirmDelaySeconds)
            key code \(Automation.returnKeyCode)
          end if
        end tell
      end tell
    end run
    """
  }

  private static func tapbackKeyNumber(for reactionType: ReactionType) -> Int {
    switch reactionType {
    case .love: 1
    case .like: 2
    case .dislike: 3
    case .laugh: 4
    case .emphasis: 5
    case .question: 6
    case .custom:
      preconditionFailure("custom reactions do not map to numbered tapback keys")
    }
  }

  private static func preferredChatLookup(chatInfo: ChatInfo) -> String {
    let preferred = chatInfo.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !preferred.isEmpty {
      return preferred
    }
    let identifier = chatInfo.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    if !identifier.isEmpty {
      return identifier
    }
    return chatInfo.guid
  }

  private static func isSingleEmoji(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count == 1 else { return false }
    guard let scalar = trimmed.unicodeScalars.first else { return false }
    return scalar.properties.isEmoji || scalar.properties.isEmojiPresentation
  }

  private static func runAppleScript(_ source: String, arguments: [String]) throws {
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
      let message = String(data: data, encoding: .utf8) ?? "Unknown AppleScript error"
      throw IMsgError.appleScriptFailure(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }
}

struct ReactResult: Codable {
  let success: Bool
  let chatID: Int64
  let reactionType: String
  let reactionEmoji: String

  enum CodingKeys: String, CodingKey {
    case success
    case chatID = "chat_id"
    case reactionType = "reaction_type"
    case reactionEmoji = "reaction_emoji"
  }
}
