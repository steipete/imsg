import Foundation
import SQLite
import Testing

@testable import IMsgCore

private enum WatcherTestDatabase {
  static func appleEpoch(_ date: Date) -> Int64 {
    let seconds = date.timeIntervalSince1970 - MessageStore.appleEpochOffset
    return Int64(seconds * 1_000_000_000)
  }

  static func makeStore() throws -> MessageStore {
    let db = try Connection(.inMemory)
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
      """,
    )
    try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
    try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);")
    try db.execute(
      "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);",
    )

    let now = Date()
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
      VALUES (1, 1, 'hello', ?, 0, 'iMessage')
      """,
      appleEpoch(now),
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")

    return try MessageStore(
      connection: db, path: ":memory:", hasAttributedBody: false, hasReactionColumns: false,
    )
  }
}

@Test
func messageWatcherYieldsExistingMessages() async throws {
  let store = try WatcherTestDatabase.makeStore()
  let watcher = MessageWatcher(store: store)
  let stream = watcher.stream(
    chatID: nil,
    sinceRowID: -1,
    configuration: MessageWatcherConfiguration(debounceInterval: 0.01, batchLimit: 10),
  )

  let task = Task { () throws -> Message? in
    var iterator = stream.makeAsyncIterator()
    return try await iterator.next()
  }

  let message = try await task.value
  #expect(message?.text == "hello")
}
