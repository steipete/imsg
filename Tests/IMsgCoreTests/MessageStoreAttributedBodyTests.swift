import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test
func messagesByChatUsesAttributedBodyFallback() throws {
  let db = try Connection(.inMemory)
  try db.execute(
    """
    CREATE TABLE message (
      ROWID INTEGER PRIMARY KEY,
      handle_id INTEGER,
      text TEXT,
      attributedBody BLOB,
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
    """
    CREATE TABLE message_attachment_join (
      message_id INTEGER,
      attachment_id INTEGER
    );
    """
  )

  let now = Date()
  let bodyBytes = [UInt8(0x01), UInt8(0x2b)] + Array("fallback text".utf8) + [0x86, 0x84]
  let body = Blob(bytes: bodyBytes)
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES (1, '+123', 'iMessage;+;chat123', 'Test Chat', 'iMessage')
    """
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, attributedBody, date, is_from_me, service)
    VALUES (1, 1, NULL, ?, ?, 0, 'iMessage')
    """,
    body,
    TestDatabase.appleEpoch(now)
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messages(chatID: 1, limit: 10)
  #expect(messages.count == 1)
  #expect(messages.first?.text == "fallback text")
}

@Test
func messagesByChatUsesLengthPrefixedAttributedBodyFallback() throws {
  let db = try Connection(.inMemory)
  try db.execute(
    """
    CREATE TABLE message (
      ROWID INTEGER PRIMARY KEY,
      handle_id INTEGER,
      text TEXT,
      attributedBody BLOB,
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
    """
    CREATE TABLE message_attachment_join (
      message_id INTEGER,
      attachment_id INTEGER
    );
    """
  )

  let now = Date()
  let text = "length prefixed"
  let bodyBytes: [UInt8] = [0x01, 0x2b, UInt8(text.utf8.count)] + Array(text.utf8) + [0x86, 0x84]
  let body = Blob(bytes: bodyBytes)
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES (1, '+123', 'iMessage;+;chat123', 'Test Chat', 'iMessage')
    """
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, attributedBody, date, is_from_me, service)
    VALUES (1, 1, NULL, ?, ?, 0, 'iMessage')
    """,
    body,
    TestDatabase.appleEpoch(now)
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messages(chatID: 1, limit: 10)
  #expect(messages.count == 1)
  #expect(messages.first?.text == "length prefixed")
}

@Test
func messagesAfterUsesAttributedBodyFallback() throws {
  let db = try Connection(.inMemory)
  try db.execute(
    """
    CREATE TABLE message (
      ROWID INTEGER PRIMARY KEY,
      handle_id INTEGER,
      text TEXT,
      attributedBody BLOB,
      date INTEGER,
      is_from_me INTEGER,
      service TEXT
    );
    """
  )
  try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
  try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);")
  try db.execute(
    """
    CREATE TABLE message_attachment_join (
      message_id INTEGER,
      attachment_id INTEGER
    );
    """
  )

  let now = Date()
  let bodyBytes = [UInt8(0x01), UInt8(0x2b)] + Array("new text".utf8) + [0x86, 0x84]
  let body = Blob(bytes: bodyBytes)
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, attributedBody, date, is_from_me, service)
    VALUES (1, 1, NULL, ?, ?, 0, 'iMessage')
    """,
    body,
    TestDatabase.appleEpoch(now)
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messagesAfter(afterRowID: 0, chatID: nil, limit: 10)
  #expect(messages.count == 1)
  #expect(messages.first?.text == "new text")
}
