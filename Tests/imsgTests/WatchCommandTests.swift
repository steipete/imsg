import Commander
import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

private func singleMessageStreamProvider(
  _ message: Message
) -> (
  MessageWatcher,
  Int64?,
  Int64?,
  MessageWatcherConfiguration
) -> AsyncThrowingStream<Message, Error> {
  return { _, _, _, _ in
    AsyncThrowingStream { continuation in
      continuation.yield(message)
      continuation.finish()
    }
  }
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
  _ = try await StdoutCapture.capture {
    try await WatchCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in store },
      streamProvider: singleMessageStreamProvider(message)
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
  _ = try await StdoutCapture.capture {
    try await WatchCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in store },
      streamProvider: singleMessageStreamProvider(message)
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

  let (output, _) = try await StdoutCapture.capture {
    try await WatchCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in store },
      streamProvider: singleMessageStreamProvider(message)
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

  let (output, _) = try await StdoutCapture.capture {
    try await WatchCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in store },
      streamProvider: singleMessageStreamProvider(message)
    )
  }
  #expect(output.contains("\"text\":\"hello\""))
}

@Test
func watchCommandShowsGroupLabelWhenWatchingAll() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["db": ["/tmp/unused"], "debounce": ["1ms"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let store = try CommandTestDatabase.makeStoreForRPC()
  let message = Message(
    rowID: 10,
    chatID: 1,
    sender: "+123",
    text: "group msg",
    date: Date(),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 0
  )

  let (output, _) = try await StdoutCapture.capture {
    try await WatchCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in store },
      streamProvider: singleMessageStreamProvider(message)
    )
  }
  // Group chat message should show group name in parentheses
  #expect(output.contains("(Group Chat)"))
  #expect(output.contains("group msg"))
}

@Test
func watchCommandNoGroupLabelWhenScopedToChat() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["chatID": ["1"], "db": ["/tmp/unused"], "debounce": ["1ms"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let store = try CommandTestDatabase.makeStoreForRPC()
  let message = Message(
    rowID: 10,
    chatID: 1,
    sender: "+123",
    text: "scoped msg",
    date: Date(),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 0
  )

  let (output, _) = try await StdoutCapture.capture {
    try await WatchCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in store },
      streamProvider: singleMessageStreamProvider(message)
    )
  }
  // Scoped watch should NOT show group label
  #expect(!output.contains("(Group Chat)"))
  #expect(output.contains("scoped msg"))
}

@Test
func watchCommandNoLabelFor1on1WhenWatchingAll() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["db": ["/tmp/unused"], "debounce": ["1ms"]],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let store = try CommandTestDatabase.makeStoreFor1on1()
  let message = Message(
    rowID: 10,
    chatID: 1,
    sender: "+15551234567",
    text: "direct msg",
    date: Date(),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 0
  )

  let (output, _) = try await StdoutCapture.capture {
    try await WatchCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in store },
      streamProvider: singleMessageStreamProvider(message)
    )
  }
  // 1:1 messages should NOT have parenthetical group label even when watching all chats
  #expect(!output.contains("("))
  #expect(!output.contains(")"))
  #expect(output.contains("direct msg"))
  #expect(output.contains("+15551234567"))
}
