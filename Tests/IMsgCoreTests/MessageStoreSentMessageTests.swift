import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test
func latestSentMessageMatchesNewestOutgoingTextInChat() throws {
  let db = try makeSentMessageDatabase()
  let now = Date()
  try insertSentMessageFixture(
    db,
    rowID: 1,
    chatID: 1,
    text: "same",
    guid: "old-guid",
    date: now.addingTimeInterval(-20),
    isFromMe: true
  )
  try insertSentMessageFixture(
    db,
    rowID: 2,
    chatID: 1,
    text: "same",
    guid: "incoming-guid",
    date: now.addingTimeInterval(-5),
    isFromMe: false
  )
  try insertSentMessageFixture(
    db,
    rowID: 3,
    chatID: 1,
    text: "same",
    guid: "chat-guid",
    date: now,
    isFromMe: true
  )
  try insertSentMessageFixture(
    db,
    rowID: 4,
    chatID: 2,
    text: "same",
    guid: "other-chat-guid",
    date: now.addingTimeInterval(5),
    isFromMe: true
  )
  let store = try MessageStore(connection: db, path: ":memory:")

  let message = try store.latestSentMessage(
    matchingText: "same",
    chatID: 1,
    since: now.addingTimeInterval(-10)
  )

  #expect(message?.rowID == 3)
  #expect(message?.chatID == 1)
  #expect(message?.guid == "chat-guid")
}

@Test
func latestSentMessageFallsBackToNewestOutgoingTextWithoutChatFilter() throws {
  let db = try makeSentMessageDatabase()
  let now = Date()
  try insertSentMessageFixture(
    db,
    rowID: 1,
    chatID: 1,
    text: "same",
    guid: "chat-one-guid",
    date: now,
    isFromMe: true
  )
  try insertSentMessageFixture(
    db,
    rowID: 2,
    chatID: 2,
    text: "same",
    guid: "chat-two-guid",
    date: now.addingTimeInterval(5),
    isFromMe: true
  )
  let store = try MessageStore(connection: db, path: ":memory:")

  let message = try store.latestSentMessage(
    matchingText: "same",
    chatID: nil,
    since: now.addingTimeInterval(-1)
  )

  #expect(message?.rowID == 2)
  #expect(message?.chatID == 2)
  #expect(message?.guid == "chat-two-guid")
}

@Test
func latestSentMessageMatchesAttributedBodyText() throws {
  let db = try makeSentMessageDatabase()
  let now = Date()
  let text = "body fallback"
  let bodyBytes = [UInt8(0x01), UInt8(0x2b)] + Array(text.utf8) + [0x86, 0x84]
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, attributedBody, guid, associated_message_guid,
      associated_message_type, date, is_from_me, service
    )
    VALUES (10, 1, NULL, ?, 'body-guid', NULL, 0, ?, 1, 'iMessage')
    """,
    Blob(bytes: bodyBytes),
    TestDatabase.appleEpoch(now)
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 10)")
  let store = try MessageStore(connection: db, path: ":memory:")

  let message = try store.latestSentMessage(
    matchingText: text,
    chatID: 1,
    since: now.addingTimeInterval(-1)
  )

  #expect(message?.rowID == 10)
  #expect(message?.guid == "body-guid")
  #expect(message?.text == text)
}

@Test
func chatInfoMatchingTargetHandlesAnyGroupPolarityMismatch() throws {
  let db = try makeSentMessageDatabase()
  try db.run(
    """
    UPDATE chat
    SET chat_identifier = 'any;+;chat134', guid = 'any;+;chat134'
    WHERE ROWID = 1
    """
  )
  let store = try MessageStore(connection: db, path: ":memory:")

  let info = try store.chatInfo(matchingTarget: "any;-;chat134")

  #expect(info?.id == 1)
  #expect(info?.guid == "any;+;chat134")
}

@Test
func latestUnjoinedSentMessageRowIDMatchesAnyGroupTargetVariants() throws {
  let db = try makeSentMessageDatabase()
  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (2, 'any;-;chat134')")
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      date, is_from_me, service
    )
    VALUES (20, 2, '', 'ghost-guid', NULL, 0, ?, 1, 'SMS')
    """,
    TestDatabase.appleEpoch(now)
  )
  let store = try MessageStore(connection: db, path: ":memory:")

  let rowID = try store.latestUnjoinedSentMessageRowID(
    matchingTargetHandles: ["any;+;chat134"],
    since: now.addingTimeInterval(-1)
  )

  #expect(rowID == 20)
}

private func makeSentMessageDatabase() throws -> Connection {
  let db = try Connection(.inMemory)
  try db.execute(
    """
    CREATE TABLE message (
      ROWID INTEGER PRIMARY KEY,
      handle_id INTEGER,
      text TEXT,
      attributedBody BLOB,
      guid TEXT,
      associated_message_guid TEXT,
      associated_message_type INTEGER,
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
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
    VALUES (1, 'iMessage;+;one', 'iMessage;+;one', 'One', 'iMessage'),
           (2, 'iMessage;+;two', 'iMessage;+;two', 'Two', 'iMessage')
    """
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, 'me@icloud.com')")
  return db
}

private func insertSentMessageFixture(
  _ db: Connection,
  rowID: Int64,
  chatID: Int64,
  text: String,
  guid: String,
  date: Date,
  isFromMe: Bool
) throws {
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid, associated_message_type,
      date, is_from_me, service
    )
    VALUES (?, 1, ?, ?, NULL, 0, ?, ?, 'iMessage')
    """,
    rowID,
    text,
    guid,
    TestDatabase.appleEpoch(date),
    isFromMe ? 1 : 0
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (?, ?)", chatID, rowID)
}
