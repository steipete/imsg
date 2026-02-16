import Commander
import IMsgCore

enum CommandSignatures {
  static func baseOptions() -> [OptionDefinition] {
    [
      .make(
        label: "db",
        names: [.long("db")],
        help: "Path to chat.db (defaults to ~/Library/Messages/chat.db)",
      )
    ]
  }

  static func withRuntimeFlags(_ signature: CommandSignature) -> CommandSignature {
    signature.withStandardRuntimeFlags()
  }
}
