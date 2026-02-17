import Commander
import Foundation
import IMsgCore

enum StatusCommand {
  static let spec = CommandSpec(
    name: "status",
    abstract: "Check availability of imsg advanced features",
    discussion: """
      Display the current status of imsg features and permissions.
      Shows which advanced features (typing indicators, read receipts) are
      available and provides setup instructions if needed.
      """,
    signature: CommandSignatures.withRuntimeFlags(CommandSignature()),
    usageExamples: [
      "imsg status",
      "imsg status --json",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    let bridge = IMCoreBridge.shared
    let availability = bridge.checkAvailability()

    if runtime.jsonOutput {
      try JSONLines.print([
        "basic_features": "true",
        "advanced_features": availability.available ? "true" : "false",
        "typing_indicators": availability.available ? "true" : "false",
        "read_receipts": availability.available ? "true" : "false",
        "message": availability.message,
      ])
    } else {
      StdoutWriter.writeLine("imsg Status Report")
      StdoutWriter.writeLine("==================")
      StdoutWriter.writeLine("")
      StdoutWriter.writeLine("Basic features (send, receive, history):")
      StdoutWriter.writeLine("  Available")
      StdoutWriter.writeLine("")
      StdoutWriter.writeLine("Advanced features (typing, read receipts):")
      if availability.available {
        StdoutWriter.writeLine("  Available - IMCore bridge connected")
        StdoutWriter.writeLine("")
        StdoutWriter.writeLine("Available commands:")
        StdoutWriter.writeLine("  imsg typing --to <handle>")
        StdoutWriter.writeLine("  imsg launch")
        StdoutWriter.writeLine("  imsg status")
      } else {
        StdoutWriter.writeLine("  Not available")
        StdoutWriter.writeLine("")
        StdoutWriter.writeLine("To enable advanced features:")
        StdoutWriter.writeLine("  1. Disable System Integrity Protection (SIP)")
        StdoutWriter.writeLine("     - Restart Mac holding Cmd+R")
        StdoutWriter.writeLine("     - Open Terminal from Utilities menu")
        StdoutWriter.writeLine("     - Run: csrutil disable")
        StdoutWriter.writeLine("     - Restart normally")
        StdoutWriter.writeLine("")
        StdoutWriter.writeLine("  2. Grant Full Disk Access")
        StdoutWriter.writeLine("     - System Settings > Privacy & Security > Full Disk Access")
        StdoutWriter.writeLine("     - Add Terminal or your terminal app")
        StdoutWriter.writeLine("")
        StdoutWriter.writeLine("  3. Build and launch:")
        StdoutWriter.writeLine("     make build-dylib")
        StdoutWriter.writeLine("     imsg launch")
        StdoutWriter.writeLine("")
        StdoutWriter.writeLine("Note: Basic messaging features work without these steps.")
      }
    }
  }
}
