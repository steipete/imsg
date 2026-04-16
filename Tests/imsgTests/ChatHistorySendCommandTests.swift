import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func chatsCommandRunsWithJsonOutput() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "limit": ["5"]],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let (output, _) = try await StdoutCapture.capture {
    try await ChatsCommand.spec.run(values, runtime)
  }
  #expect(output.contains("\"is_group\":true"))
  #expect(output.contains("\"guid\":\"iMessage;+;chat123\""))
  #expect(output.contains("\"display_name\":\"Test Chat\""))
  #expect(output.contains("\"participants\":[\"+123\",\"+456\"]"))
}

@Test
func chatsCommandPlainOutputMarksGroups() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "limit": ["5"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let (output, _) = try await StdoutCapture.capture {
    try await ChatsCommand.spec.run(values, runtime)
  }
  #expect(output.contains("[1 group]"))
}

@Test
func historyCommandRunsWithChatID() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"], "limit": ["5"]],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let (output, _) = try await StdoutCapture.capture {
    try await HistoryCommand.spec.run(values, runtime)
  }
  #expect(output.contains("\"chat_identifier\":\"+123\""))
  #expect(output.contains("\"chat_guid\":\"iMessage;+;chat123\""))
  #expect(output.contains("\"chat_name\":\"Test Chat\""))
  #expect(output.contains("\"is_group\":true"))
  #expect(output.contains("\"participants\":[\"+123\",\"+456\"]"))
}

@Test
func historyCommandPlainOutputPrintsGroupHeader() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"], "limit": ["5"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let (output, _) = try await StdoutCapture.capture {
    try await HistoryCommand.spec.run(values, runtime)
  }
  #expect(output.contains("# group chat: Test Chat"))
  #expect(output.contains("+123"))
  #expect(output.contains("+456"))
}

@Test
func historyCommandRunsWithAttachmentsNonJson() async throws {
  let path = try CommandTestDatabase.makePathWithAttachment()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"], "limit": ["5"]],
    flags: ["attachments"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  _ = try await StdoutCapture.capture {
    try await HistoryCommand.spec.run(values, runtime)
  }
}

@Test
func chatsCommandRunsWithPlainOutput() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "limit": ["5"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  _ = try await StdoutCapture.capture {
    try await ChatsCommand.spec.run(values, runtime)
  }
}

@Test
func sendCommandRejectsMissingRecipient() async {
  let values = ParsedValues(
    positional: [],
    options: ["text": ["hi"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  do {
    try await SendCommand.spec.run(values, runtime)
    #expect(Bool(false))
  } catch let error as ParsedValuesError {
    #expect(error.description.contains("Missing required option"))
  } catch {
    #expect(Bool(false))
  }
}

@Test
func sendCommandRunsWithStubSender() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["to": ["+15551234567"], "text": ["hi"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var captured: MessageSendOptions?
  try await SendCommand.run(
    values: values,
    runtime: runtime,
    sendMessage: { options in
      captured = options
    }
  )
  #expect(captured?.recipient == "+15551234567")
  #expect(captured?.text == "hi")
}

@Test
func sendCommandResolvesChatID() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"], "text": ["hi"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  var captured: MessageSendOptions?
  try await SendCommand.run(
    values: values,
    runtime: runtime,
    sendMessage: { options in
      captured = options
    }
  )
  #expect(captured?.chatIdentifier == "+123")
  #expect(captured?.chatGUID == "iMessage;+;chat123")
  #expect(captured?.recipient.isEmpty == true)
}
