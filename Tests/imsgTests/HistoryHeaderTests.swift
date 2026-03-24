import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func historyHeaderShowsGroupInfo() async throws {
  let path = try CommandTestDatabase.makePathWithParticipants()
  let values = ParsedValues(
    positional: [],
    options: ["chatID": ["1"], "db": [path]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)

  let (output, _) = try await StdoutCapture.capture {
    try await HistoryCommand.spec.run(values, runtime)
  }
  // Group chat header should show chat name and service
  #expect(output.contains("Group Chat"))
  #expect(output.contains("iMessage"))
  // Should show separator
  #expect(output.contains("\u{2500}"))
  // Should show participant list on second line
  #expect(output.contains("+123"))
  #expect(output.contains("me@icloud.com"))
  // Should also show message content
  #expect(output.contains("hello"))
}

@Test
func historyHeaderShows1on1Format() async throws {
  let path = try CommandTestDatabase.makePathWith1on1Chat()
  let values = ParsedValues(
    positional: [],
    options: ["chatID": ["1"], "db": [path]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)

  let (output, _) = try await StdoutCapture.capture {
    try await HistoryCommand.spec.run(values, runtime)
  }
  // 1:1 header should show "Chat with +15551234567 · iMessage"
  #expect(output.contains("Chat with"))
  #expect(output.contains("+15551234567"))
  #expect(output.contains("\u{00B7} iMessage"))
  // Should show separator
  #expect(output.contains("\u{2500}"))
  // Should show message
  #expect(output.contains("hey there"))
  // Should NOT show participant list line (that's group-only)
  let lines = output.split(separator: "\n").map(String.init)
  let indentedLines = lines.filter { $0.hasPrefix("  ") && !$0.contains("attachment") }
  #expect(indentedLines.isEmpty)
}

@Test
func historyHeaderShowsWithEmptyMessages() async throws {
  let path = try CommandTestDatabase.makePathWith1on1Chat()
  // Use a limit of 0 or a date range that excludes all messages
  let values = ParsedValues(
    positional: [],
    options: [
      "chatID": ["1"],
      "db": [path],
      "start": ["2099-01-01T00:00:00Z"],
    ],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)

  let (output, _) = try await StdoutCapture.capture {
    try await HistoryCommand.spec.run(values, runtime)
  }
  // Header should still appear even with no messages
  #expect(output.contains("Chat with"))
  #expect(output.contains("\u{2500}"))
  // But no message content
  #expect(!output.contains("hey there"))
}

@Test
func historyHeaderNotInJSONMode() async throws {
  let path = try CommandTestDatabase.makePathWithParticipants()
  let values = ParsedValues(
    positional: [],
    options: ["chatID": ["1"], "db": [path]],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)

  let (output, _) = try await StdoutCapture.capture {
    try await HistoryCommand.spec.run(values, runtime)
  }
  // JSON mode should NOT contain the header
  #expect(!output.contains("Group Chat \u{00B7}"))
  #expect(!output.contains("\u{2500}"))
  // Should contain JSON message data
  #expect(output.contains("\"text\":\"hello\""))
}
