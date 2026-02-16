import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func reactCommandRejectsMultiCharacterEmojiInput() async {
  do {
    let path = try CommandTestDatabase.makePath()
    let values = ParsedValues(
      positional: [],
      options: ["db": [path], "chatID": ["1"], "reaction": ["🎉 party"]],
      flags: [],
    )
    let runtime = RuntimeOptions(parsedValues: values)
    try await ReactCommand.run(values: values, runtime: runtime)
    #expect(Bool(false))
  } catch let error as IMsgError {
    switch error {
    case .invalidReaction(let value):
      #expect(value == "🎉 party")
    default:
      #expect(Bool(false))
    }
  } catch {
    #expect(Bool(false))
  }
}

@Test
func reactCommandBuildsParameterizedAppleScriptForStandardTapback() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"], "reaction": ["like"]],
    flags: [],
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var capturedScript = ""
  var capturedArguments: [String] = []
  try await ReactCommand.run(
    values: values,
    runtime: runtime,
    appleScriptRunner: { source, arguments in
      capturedScript = source
      capturedArguments = arguments
    },
  )
  #expect(capturedArguments == ["iMessage;+;chat123", "Test Chat", "2", "0"])
  #expect(capturedScript.contains("on run argv"))
  #expect(capturedScript.contains("keystroke \"f\" using command down"))
  #expect(capturedScript.contains("set targetChat to chat id chatGUID"))
  #expect(capturedScript.contains("keystroke reactionSelection"))
  #expect(capturedScript.contains("if shouldConfirmSelection is \"1\" then"))
  #expect(capturedScript.contains("chat123") == false)
}

@Test
func reactCommandBuildsParameterizedAppleScriptForCustomEmoji() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"], "reaction": ["🎉"]],
    flags: [],
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var capturedScript = ""
  var capturedArguments: [String] = []
  try await ReactCommand.run(
    values: values,
    runtime: runtime,
    appleScriptRunner: { source, arguments in
      capturedScript = source
      capturedArguments = arguments
    },
  )
  #expect(capturedArguments == ["iMessage;+;chat123", "Test Chat", "🎉", "1"])
  #expect(capturedScript.contains("on run argv"))
  #expect(capturedScript.contains("keystroke reactionSelection"))
  #expect(capturedScript.contains("if shouldConfirmSelection is \"1\" then"))
  #expect(capturedScript.contains("key code 36"))
  #expect(capturedScript.contains("chat123") == false)
}

@Test
func reactCommandMapsStandardTapbacksToExpectedShortcuts() async throws {
  let path = try CommandTestDatabase.makePath()
  let runtime = RuntimeOptions(parsedValues: ParsedValues(positional: [], options: [:], flags: []))
  let cases: [(reaction: String, expectedKey: String)] = [
    ("love", "1"),
    ("like", "2"),
    ("dislike", "3"),
    ("laugh", "4"),
    ("emphasis", "5"),
    ("question", "6"),
  ]
  for (reaction, expectedKey) in cases {
    let values = ParsedValues(
      positional: [],
      options: ["db": [path], "chatID": ["1"], "reaction": [reaction]],
      flags: [],
    )
    var capturedArguments: [String] = []
    try await ReactCommand.run(
      values: values,
      runtime: runtime,
      appleScriptRunner: { _, arguments in
        capturedArguments = arguments
      },
    )
    #expect(capturedArguments[2] == expectedKey)
    #expect(capturedArguments[3] == "0")
  }
}

@Test
func reactCommandFallsBackToIdentifierWhenNameIsEmpty() async throws {
  let path = try CommandTestDatabase.makePath(
    chatIdentifier: "fallback-identifier",
    chatGUID: "fallback-guid",
    chatName: "",
  )
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"], "reaction": ["like"]],
    flags: [],
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var capturedArguments: [String] = []
  try await ReactCommand.run(
    values: values,
    runtime: runtime,
    appleScriptRunner: { _, arguments in
      capturedArguments = arguments
    },
  )
  #expect(capturedArguments[0] == "fallback-guid")
  #expect(capturedArguments[1] == "fallback-identifier")
}

@Test
func reactCommandFallsBackToGuidWhenNameAndIdentifierAreEmpty() async throws {
  let path = try CommandTestDatabase.makePath(
    chatIdentifier: "",
    chatGUID: "guid-only-target",
    chatName: "",
  )
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"], "reaction": ["like"]],
    flags: [],
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var capturedArguments: [String] = []
  try await ReactCommand.run(
    values: values,
    runtime: runtime,
    appleScriptRunner: { _, arguments in
      capturedArguments = arguments
    },
  )
  #expect(capturedArguments[0] == "guid-only-target")
  #expect(capturedArguments[1] == "guid-only-target")
}
