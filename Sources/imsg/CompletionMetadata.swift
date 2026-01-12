import Foundation
import IMsgCore

/// Metadata for shell and LLM completion generation.
///
/// This structure exists separately from CommandSpec/CommandSignature because Commander's
/// OptionDefinition doesn't support value hints (file, rowid, timestamp) or enumerated choices
/// needed for shell completion. Rather than forking Commander, we maintain this parallel
/// structure. The consistency test verifies command names stay in sync with CommandRouter.
///
/// If maintainers prefer, this could be integrated into CommandSpec by extending
/// Commander's types or adding a completion metadata property to CommandSpec.
///
/// Update this file when commands or options change.
enum CompletionMetadata {
  static let cliName = "imsg"
  static let description = "macOS CLI for iMessage/SMS - send, read, and stream messages"

  /// Service values derived from MessageService enum to avoid hardcoding
  static let serviceChoices: [String] = MessageService.allCases.map { $0.rawValue }

  /// Log levels as defined in Commander's withStandardRuntimeFlags.
  /// Commander doesn't expose these as an enum, so we define them here.
  static let logLevelChoices: [String] = [
    "trace", "verbose", "debug", "info", "warning", "error", "critical",
  ]

  struct Option {
    let long: String
    let short: String?
    let description: String
    let takesValue: Bool
    let valueHint: String?
    let choices: [String]?

    init(
      _ long: String,
      short: String? = nil,
      description: String,
      takesValue: Bool = true,
      valueHint: String? = nil,
      choices: [String]? = nil
    ) {
      self.long = long
      self.short = short
      self.description = description
      self.takesValue = takesValue
      self.valueHint = valueHint
      self.choices = choices
    }
  }

  struct Command {
    let name: String
    let description: String
    let options: [Option]
    let examples: [String]
  }

  static let runtimeOptions: [Option] = [
    Option("db", description: "Path to chat.db", valueHint: "file"),
    Option("log-level", description: "Set log level", choices: logLevelChoices),
    Option("verbose", short: "v", description: "Enable verbose logging", takesValue: false),
    Option("json", short: "j", description: "Emit machine-readable JSON output", takesValue: false),
  ]

  static let commands: [Command] = [
    Command(
      name: "chats",
      description: "List recent conversations",
      options: [
        Option("limit", description: "Number of chats to list", valueHint: "number")
      ],
      examples: [
        "imsg chats --limit 5",
        "imsg chats --json",
      ]
    ),
    Command(
      name: "history",
      description: "Show recent messages for a chat",
      options: [
        Option("chat-id", description: "Chat rowid from 'imsg chats'", valueHint: "rowid"),
        Option("limit", description: "Number of messages to show", valueHint: "number"),
        Option(
          "participants",
          description: "Filter by participant handles (comma-separated)",
          valueHint: "handles"
        ),
        Option("start", description: "ISO8601 start timestamp (inclusive)", valueHint: "timestamp"),
        Option("end", description: "ISO8601 end timestamp (exclusive)", valueHint: "timestamp"),
        Option("attachments", description: "Include attachment metadata", takesValue: false),
      ],
      examples: [
        "imsg history --chat-id 1 --limit 10 --attachments",
        "imsg history --chat-id 1 --start 2025-01-01T00:00:00Z --json",
      ]
    ),
    Command(
      name: "watch",
      description: "Stream incoming messages",
      options: [
        Option("chat-id", description: "Limit to chat rowid", valueHint: "rowid"),
        Option("debounce", description: "Debounce interval (e.g., 250ms)", valueHint: "duration"),
        Option("since-rowid", description: "Start watching after this rowid", valueHint: "rowid"),
        Option(
          "participants",
          description: "Filter by participant handles (comma-separated)",
          valueHint: "handles"
        ),
        Option("start", description: "ISO8601 start timestamp (inclusive)", valueHint: "timestamp"),
        Option("end", description: "ISO8601 end timestamp (exclusive)", valueHint: "timestamp"),
        Option("attachments", description: "Include attachment metadata", takesValue: false),
      ],
      examples: [
        "imsg watch --chat-id 1 --attachments --debounce 250ms",
        "imsg watch --json",
      ]
    ),
    Command(
      name: "send",
      description: "Send a message (text and/or attachment)",
      options: [
        Option("to", description: "Phone number or email", valueHint: "recipient"),
        Option("chat-id", description: "Chat rowid (alternative to --to)", valueHint: "rowid"),
        Option("chat-identifier", description: "Chat identifier string", valueHint: "identifier"),
        Option("chat-guid", description: "Chat GUID", valueHint: "guid"),
        Option("text", description: "Message body", valueHint: "message"),
        Option("file", description: "Path to attachment", valueHint: "file"),
        Option("service", description: "Service to use", choices: serviceChoices),
        Option("region", description: "Default region for phone normalization", valueHint: "code"),
      ],
      examples: [
        "imsg send --to +14155551212 --text \"hello\"",
        "imsg send --chat-id 1 --text \"hi\" --file ~/photo.jpg",
      ]
    ),
    Command(
      name: "rpc",
      description: "Run JSON-RPC server over stdin/stdout",
      options: [],
      examples: [
        "imsg rpc",
        "imsg rpc --db ~/Library/Messages/chat.db",
      ]
    ),
    Command(
      name: "completions",
      description: "Generate shell completions or LLM context",
      options: [],
      examples: [
        "imsg completions bash",
        "imsg completions zsh",
        "imsg completions fish",
        "imsg completions llm",
      ]
    ),
  ]
}
