import Commander
import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

private enum CommandTestDatabase {
  static func appleEpoch(_ date: Date) -> Int64 {
    let seconds = date.timeIntervalSince1970 - MessageStore.appleEpochOffset
    return Int64(seconds * 1_000_000_000)
  }

  static func makePath() throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("chat.db").path
    let db = try Connection(path)
    try db.execute(
      """
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        handle_id INTEGER,
        text TEXT,
        date INTEGER,
        is_from_me INTEGER,
        service TEXT
      );
      """
    )
    try db.execute(
      """
      CREATE TABLE chat (
        ROWID INTEGER PRIMARY KEY,
        chat_identifier TEXT,
        guid TEXT,
        display_name TEXT,
        service_name TEXT
      );
      """
    )
    try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
    try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);")
    try db.execute(
      "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);")
    try db.execute(
      """
      CREATE TABLE attachment (
        ROWID INTEGER PRIMARY KEY,
        filename TEXT,
        transfer_name TEXT,
        uti TEXT,
        mime_type TEXT,
        total_bytes INTEGER,
        is_sticker INTEGER
      );
      """
    )

    let now = Date()
    try db.run(
      """
      INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
      VALUES (1, '+123', 'iMessage;+;chat123', 'Test Chat', 'iMessage')
      """
    )
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
      VALUES (1, 1, 'hello', ?, 0, 'iMessage')
      """,
      appleEpoch(now)
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")
    return path
  }

  static func makePathWithAttachment() throws -> String {
    let path = try makePath()
    let db = try Connection(path)
    try db.run(
      """
      INSERT INTO attachment(ROWID, filename, transfer_name, uti, mime_type, total_bytes, is_sticker)
      VALUES (1, '/tmp/file.dat', 'file.dat', 'public.data', 'application/octet-stream', 10, 0)
      """
    )
    try db.run("INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (1, 1)")
    return path
  }
}

@Test
func chatsCommandRunsWithJsonOutput() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "limit": ["5"]],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  _ = try await StdoutCapture.capture {
    try await ChatsCommand.spec.run(values, runtime)
  }
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
  _ = try await StdoutCapture.capture {
    try await HistoryCommand.spec.run(values, runtime)
  }
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
    values: values, runtime: runtime,
    sendMessage: { options in
      captured = options
    })
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
    values: values, runtime: runtime,
    sendMessage: { options in
      captured = options
    })
  #expect(captured?.chatIdentifier == "+123")
  #expect(captured?.chatGUID == "iMessage;+;chat123")
  #expect(captured?.recipient.isEmpty == true)
}

@Test
func reactCommandRejectsMultiCharacterEmojiInput() async {
  do {
    let path = try CommandTestDatabase.makePath()
    let values = ParsedValues(
      positional: [],
      options: ["db": [path], "chatID": ["1"], "reaction": ["🎉 party"]],
      flags: []
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
    flags: []
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
    }
  )
  #expect(capturedArguments == ["iMessage;+;chat123", "Test Chat", "2"])
  #expect(capturedScript.contains("on run argv"))
  #expect(capturedScript.contains("keystroke \"f\" using command down"))
  #expect(capturedScript.contains("set targetChat to chat id chatGUID"))
  #expect(capturedScript.contains("keystroke reactionKey"))
  #expect(capturedScript.contains("chat123") == false)
}

@Test
func reactCommandBuildsParameterizedAppleScriptForCustomEmoji() async throws {
  let path = try CommandTestDatabase.makePath()
  let values = ParsedValues(
    positional: [],
    options: ["db": [path], "chatID": ["1"], "reaction": ["🎉"]],
    flags: []
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
    }
  )
  #expect(capturedArguments == ["iMessage;+;chat123", "Test Chat", "🎉"])
  #expect(capturedScript.contains("on run argv"))
  #expect(capturedScript.contains("keystroke customEmoji"))
  #expect(capturedScript.contains("key code 36"))
  #expect(capturedScript.contains("chat123") == false)
}

@Test
func watchCommandRejectsInvalidDebounce() async {
  let values = ParsedValues(
    positional: [],
    options: ["debounce": ["nope"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  do {
    _ = try await StdoutCapture.capture {
      try await WatchCommand.spec.run(values, runtime)
    }
    #expect(Bool(false))
  } catch let error as ParsedValuesError {
    #expect(error.description.contains("Invalid value"))
  } catch {
    #expect(Bool(false))
  }
}

@Test
func watchCommandRunsWithStubStream() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["db": ["/tmp/unused"], "debounce": ["1ms"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let db = try Connection(.inMemory)
  let store = try MessageStore(
    connection: db,
    path: ":memory:",
    hasAttributedBody: false,
    hasReactionColumns: false
  )
  let message = Message(
    rowID: 1,
    chatID: 1,
    sender: "+123",
    text: "hello",
    date: Date(),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 2
  )
  let streamProvider:
    (
      MessageWatcher,
      Int64?,
      Int64?,
      MessageWatcherConfiguration
    ) -> AsyncThrowingStream<Message, Error> = { _, _, _, _ in
      AsyncThrowingStream { continuation in
        continuation.yield(message)
        continuation.finish()
      }
    }
  _ = try await StdoutCapture.capture {
    try await WatchCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in store },
      streamProvider: streamProvider
    )
  }
}

@Test
func watchCommandRunsWithJsonOutput() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["db": ["/tmp/unused"], "debounce": ["1ms"]],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let db = try Connection(.inMemory)
  try db.execute(
    """
    CREATE TABLE attachment (
      ROWID INTEGER PRIMARY KEY,
      filename TEXT,
      transfer_name TEXT,
      uti TEXT,
      mime_type TEXT,
      total_bytes INTEGER,
      is_sticker INTEGER
    );
    """
  )
  try db.execute(
    "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);")
  try db.run(
    """
    INSERT INTO attachment(ROWID, filename, transfer_name, uti, mime_type, total_bytes, is_sticker)
    VALUES (1, '/tmp/file.dat', 'file.dat', 'public.data', 'application/octet-stream', 10, 0)
    """
  )
  try db.run("INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (1, 1)")

  let store = try MessageStore(
    connection: db,
    path: ":memory:",
    hasAttributedBody: false,
    hasReactionColumns: false
  )
  let message = Message(
    rowID: 1,
    chatID: 1,
    sender: "+123",
    text: "hello",
    date: Date(),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 1
  )
  let streamProvider:
    (
      MessageWatcher,
      Int64?,
      Int64?,
      MessageWatcherConfiguration
    ) -> AsyncThrowingStream<Message, Error> = { _, _, _, _ in
      AsyncThrowingStream { continuation in
        continuation.yield(message)
        continuation.finish()
      }
    }
  _ = try await StdoutCapture.capture {
    try await WatchCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in store },
      streamProvider: streamProvider
    )
  }
}

@Test
func watchCommandFlushesPlainOutput() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["db": ["/tmp/unused"], "debounce": ["1ms"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let db = try Connection(.inMemory)
  let store = try MessageStore(
    connection: db,
    path: ":memory:",
    hasAttributedBody: false,
    hasReactionColumns: false
  )
  let message = Message(
    rowID: 1,
    chatID: 1,
    sender: "+123",
    text: "hello",
    date: Date(),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 0
  )
  let streamProvider:
    (
      MessageWatcher,
      Int64?,
      Int64?,
      MessageWatcherConfiguration
    ) -> AsyncThrowingStream<Message, Error> = { _, _, _, _ in
      AsyncThrowingStream { continuation in
        continuation.yield(message)
        continuation.finish()
      }
    }

  let (output, _) = try await StdoutCapture.capture {
    try await WatchCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in store },
      streamProvider: streamProvider
    )
  }
  #expect(output.contains("hello"))
}

@Test
func watchCommandFlushesJsonOutput() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["db": ["/tmp/unused"], "debounce": ["1ms"]],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let db = try Connection(.inMemory)
  try db.execute(
    """
    CREATE TABLE attachment (
      ROWID INTEGER PRIMARY KEY,
      filename TEXT,
      transfer_name TEXT,
      uti TEXT,
      mime_type TEXT,
      total_bytes INTEGER,
      is_sticker INTEGER
    );
    """
  )
  try db.execute(
    "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);")
  try db.execute(
    """
    CREATE TABLE message (
      ROWID INTEGER PRIMARY KEY,
      handle_id INTEGER,
      text TEXT,
      date INTEGER,
      is_from_me INTEGER,
      service TEXT
    );
    """
  )

  let store = try MessageStore(
    connection: db,
    path: ":memory:",
    hasAttributedBody: false,
    hasReactionColumns: false
  )
  let message = Message(
    rowID: 1,
    chatID: 1,
    sender: "+123",
    text: "hello",
    date: Date(),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 0
  )
  let streamProvider:
    (
      MessageWatcher,
      Int64?,
      Int64?,
      MessageWatcherConfiguration
    ) -> AsyncThrowingStream<Message, Error> = { _, _, _, _ in
      AsyncThrowingStream { continuation in
        continuation.yield(message)
        continuation.finish()
      }
    }

  let (output, _) = try await StdoutCapture.capture {
    try await WatchCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in store },
      streamProvider: streamProvider
    )
  }
  #expect(output.contains("\"text\":\"hello\""))
}
