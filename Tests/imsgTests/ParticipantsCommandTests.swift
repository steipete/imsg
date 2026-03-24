import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func participantsCommandShowsGroupCLI() async throws {
  let path = try CommandTestDatabase.makePathWithParticipants()
  let values = ParsedValues(
    positional: [],
    options: ["chatID": ["1"], "db": [path]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)

  let (output, _) = try await StdoutCapture.capture {
    try await ParticipantsCommand.spec.run(values, runtime)
  }
  // Should show group header (the RPC chat has identifier "iMessage;+;chat123")
  #expect(output.contains("Group Chat"))
  #expect(output.contains("iMessage"))
  // Should list participants
  #expect(output.contains("+123"))
  #expect(output.contains("me@icloud.com"))
}

@Test
func participantsCommandShowsJSON() async throws {
  let path = try CommandTestDatabase.makePathWithParticipants()
  let values = ParsedValues(
    positional: [],
    options: ["chatID": ["1"], "db": [path]],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)

  let (output, _) = try await StdoutCapture.capture {
    try await ParticipantsCommand.spec.run(values, runtime)
  }
  let data = output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8)!
  let json = try JSONDecoder().decode(ParticipantsResponse.self, from: data)
  #expect(json.chatID == 1)
  #expect(json.isGroup == true)
  #expect(json.participants.count == 2)
  #expect(json.participants[0].identifier == "+123")
  #expect(json.participants[1].identifier == "me@icloud.com")
}

@Test
func participantsCommandShows1on1CLI() async throws {
  let path = try CommandTestDatabase.makePathWith1on1Chat()
  let values = ParsedValues(
    positional: [],
    options: ["chatID": ["1"], "db": [path]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)

  let (output, _) = try await StdoutCapture.capture {
    try await ParticipantsCommand.spec.run(values, runtime)
  }
  // 1:1 should show "Chat with" prefix, not bare name
  #expect(output.contains("Chat with"))
  #expect(output.contains("+15551234567"))
  #expect(output.contains("iMessage"))
  // Should NOT contain group-style header (no "Chat with" would be missing for groups)
  #expect(!output.contains("Group"))
}

@Test
func participantsCommandSingleColumnForUnresolved() async throws {
  let path = try CommandTestDatabase.makePathWith1on1Chat()
  let values = ParsedValues(
    positional: [],
    options: ["chatID": ["1"], "db": [path]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)

  let (output, _) = try await StdoutCapture.capture {
    try await ParticipantsCommand.spec.run(values, runtime)
  }
  let lines = output.split(separator: "\n").map(String.init)
  // Find the participant line — should be "  +15551234567" with no duplicate
  let participantLine = lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("+1555") }
  #expect(participantLine != nil)
  // The number should appear exactly once in the participant line (single column)
  let count = participantLine!.components(separatedBy: "+15551234567").count - 1
  #expect(count == 1)
}

@Test
func participantsCommandRejectsMissingChatID() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["db": ["/tmp/unused"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  do {
    _ = try await StdoutCapture.capture {
      try await ParticipantsCommand.spec.run(values, runtime)
    }
    #expect(Bool(false))
  } catch is ParsedValuesError {
    // Expected
  }
}

@Test
func participantsCommandRejectsInvalidChatID() async throws {
  let path = try CommandTestDatabase.makePathWithParticipants()
  let values = ParsedValues(
    positional: [],
    options: ["chatID": ["999"], "db": [path]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  do {
    _ = try await StdoutCapture.capture {
      try await ParticipantsCommand.spec.run(values, runtime)
    }
    #expect(Bool(false))
  } catch is ParsedValuesError {
    // Expected — no chat found
  }
}
