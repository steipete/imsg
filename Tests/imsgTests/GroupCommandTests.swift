import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func groupCommandRequiresChatID() async {
  let values = ParsedValues(
    positional: [],
    options: [:],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  do {
    try await GroupCommand.spec.run(values, runtime)
    #expect(Bool(false))
  } catch let error as ParsedValuesError {
    #expect(error.description.contains("Missing required option"))
  } catch {
    #expect(Bool(false))
  }
}

@Test
func groupCommandThrowsOnUnknownChatID() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["9999"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  do {
    try await GroupCommand.spec.run(values, runtime)
    #expect(Bool(false))
  } catch let error as IMsgError {
    #expect(String(describing: error).contains("9999"))
  } catch {
    #expect(Bool(false))
  }
}

@Test
func groupCommandPrintsPlainTextForGroup() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let (output, _) = try await StdoutCapture.capture {
    try await GroupCommand.spec.run(values, runtime)
  }
  #expect(output.contains("id: 1"))
  #expect(output.contains("identifier: +123"))
  #expect(output.contains("guid: iMessage;+;chat123"))
  #expect(output.contains("name: Test Chat"))
  #expect(output.contains("service: iMessage"))
  #expect(output.contains("is_group: true"))
  #expect(output.contains("- +123"))
  #expect(output.contains("- +456"))
}

@Test
func groupCommandEmitsJsonPayload() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"]],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let (output, _) = try await StdoutCapture.capture {
    try await GroupCommand.spec.run(values, runtime)
  }
  #expect(output.contains("\"id\":1"))
  #expect(output.contains("\"identifier\":\"+123\""))
  #expect(output.contains("\"guid\":\"iMessage;+;chat123\""))
  #expect(output.contains("\"name\":\"Test Chat\""))
  #expect(output.contains("\"service\":\"iMessage\""))
  #expect(output.contains("\"is_group\":true"))
  #expect(output.contains("\"participants\":[\"+123\",\"+456\"]"))
}
