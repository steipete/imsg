import Commander
import Foundation
import IMsgCore

enum ReactCommand {
  static let spec = CommandSpec(
    name: "react",
    abstract: "Send a tapback reaction to the most recent message",
    discussion: """
      Sends a tapback reaction to the most recent incoming message in the specified chat.
      
      IMPORTANT LIMITATIONS:
      - Only reacts to the MOST RECENT incoming message in the conversation
      - Requires Messages.app to be running
      - Uses UI automation (System Events) which requires accessibility permissions
      - The chat must be open in Messages.app for reliable operation
      
      Reaction types:
        love (❤️), like (👍), dislike (👎), laugh (😂), emphasis (‼️), question (❓)
        Or any single emoji for custom reactions (iOS 17+ / macOS 14+)
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chatID", names: [.long("chat-id")], help: "chat rowid to react in"),
          .make(label: "reaction", names: [.long("reaction"), .short("r")], 
                help: "reaction type: love, like, dislike, laugh, emphasis, question, or emoji"),
        ],
        flags: []
      )
    ),
    usageExamples: [
      "imsg react --chat-id 1 --reaction like",
      "imsg react --chat-id 1 -r love",
      "imsg react --chat-id 1 -r 🎉",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions
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
    
    // Get chat info for the GUID
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let store = try MessageStore(path: dbPath)
    guard let chatInfo = try store.chatInfo(chatID: chatID) else {
      throw IMsgError.chatNotFound(chatID: chatID)
    }
    
    // Send the reaction via AppleScript + System Events
    try sendReaction(reactionType: reactionType, chatGUID: chatInfo.guid)
    
    if runtime.jsonOutput {
      let result = ReactResult(
        success: true,
        chatID: chatID,
        reactionType: reactionType.name,
        reactionEmoji: reactionType.emoji
      )
      try JSONLines.print(result)
    } else {
      print("Sent \(reactionType.emoji) reaction to chat \(chatID)")
    }
  }
  
  private static func sendReaction(reactionType: ReactionType, chatGUID: String) throws {
    // Use AppleScript with System Events to:
    // 1. Activate Messages app
    // 2. Open the specific chat
    // 3. Use Cmd+T to open tapback menu on most recent message
    // 4. Press the appropriate number key (1-6) for standard reactions
    //    or type the emoji for custom reactions
    
    let keyNumber: Int?
    switch reactionType {
    case .love: keyNumber = 1
    case .like: keyNumber = 2
    case .dislike: keyNumber = 3
    case .laugh: keyNumber = 4
    case .emphasis: keyNumber = 5
    case .question: keyNumber = 6
    case .custom: keyNumber = nil
    }
    
    let script: String
    if let keyNumber = keyNumber {
      // Standard tapback: Cmd+T then number key
      script = """
        tell application "Messages"
          activate
          set targetChat to chat id "\(chatGUID)"
        end tell
        
        delay 0.3
        
        tell application "System Events"
          tell process "Messages"
            -- Open tapback menu with Cmd+T
            keystroke "t" using command down
            delay 0.2
            -- Select reaction with number key
            keystroke "\(keyNumber)"
          end tell
        end tell
        """
    } else {
      // Custom emoji reaction: Cmd+T, then type the emoji, then Enter
      let emoji = reactionType.emoji
      script = """
        tell application "Messages"
          activate
          set targetChat to chat id "\(chatGUID)"
        end tell
        
        delay 0.3
        
        tell application "System Events"
          tell process "Messages"
            -- Open tapback menu with Cmd+T
            keystroke "t" using command down
            delay 0.2
            -- Type the emoji
            keystroke "\(emoji)"
            delay 0.1
            -- Press Enter to confirm
            keystroke return
          end tell
        end tell
        """
    }
    
    try runAppleScript(script)
  }
  
  private static func runAppleScript(_ source: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    
    let stderrPipe = Pipe()
    process.standardError = stderrPipe
    
    try process.run()
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
