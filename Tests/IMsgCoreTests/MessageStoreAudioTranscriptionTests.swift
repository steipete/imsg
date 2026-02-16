import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Test
func audioMessagesUseTranscriptionText() throws {
  let db = try Connection(.inMemory)
  try db.execute(
    """
    CREATE TABLE message (
      ROWID INTEGER PRIMARY KEY,
      handle_id INTEGER,
      text TEXT,
      date INTEGER,
      is_from_me INTEGER,
      service TEXT,
      is_audio_message INTEGER
    );
    """,
  )
  try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
  try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);")
  try db.execute(
    """
    CREATE TABLE attachment (
      ROWID INTEGER PRIMARY KEY,
      filename TEXT,
      transfer_name TEXT,
      uti TEXT,
      mime_type TEXT,
      total_bytes INTEGER,
      is_sticker INTEGER,
      user_info BLOB
    );
    """,
  )
  try db.execute(
    "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);",
  )

  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service, is_audio_message)
    VALUES (1, 1, 'placeholder', ?, 0, 'iMessage', 1)
    """,
    TestDatabase.appleEpoch(now),
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")

  let info = try PropertyListSerialization.data(
    fromPropertyList: ["audio-transcription": "test transcript"],
    format: .binary,
    options: 0,
  )
  let infoBlob = Blob(bytes: [UInt8](info))
  try db.run(
    """
    INSERT INTO attachment(
      ROWID,
      filename,
      transfer_name,
      uti,
      mime_type,
      total_bytes,
      is_sticker,
      user_info
    )
    VALUES (1, '', '', '', '', 0, 0, ?)
    """,
    infoBlob,
  )
  try db.run("INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (1, 1)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messages(chatID: 1, limit: 10)
  #expect(messages.count == 1)
  #expect(messages.first?.text == "test transcript")
}

@Test
func messagesAfterUsesAudioTranscriptionText() throws {
  let db = try Connection(.inMemory)
  try db.execute(
    """
    CREATE TABLE message (
      ROWID INTEGER PRIMARY KEY,
      handle_id INTEGER,
      text TEXT,
      date INTEGER,
      is_from_me INTEGER,
      service TEXT,
      is_audio_message INTEGER
    );
    """,
  )
  try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
  try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);")
  try db.execute(
    """
    CREATE TABLE attachment (
      ROWID INTEGER PRIMARY KEY,
      filename TEXT,
      transfer_name TEXT,
      uti TEXT,
      mime_type TEXT,
      total_bytes INTEGER,
      is_sticker INTEGER,
      user_info BLOB
    );
    """,
  )
  try db.execute(
    "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);",
  )

  let now = Date()
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service, is_audio_message)
    VALUES (1, 1, 'placeholder', ?, 0, 'iMessage', 1)
    """,
    TestDatabase.appleEpoch(now),
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")

  let info = try PropertyListSerialization.data(
    fromPropertyList: ["audio-transcription": "test transcript"],
    format: .binary,
    options: 0,
  )
  let infoBlob = Blob(bytes: [UInt8](info))
  try db.run(
    """
    INSERT INTO attachment(
      ROWID,
      filename,
      transfer_name,
      uti,
      mime_type,
      total_bytes,
      is_sticker,
      user_info
    )
    VALUES (1, '', '', '', '', 0, 0, ?)
    """,
    infoBlob,
  )
  try db.run("INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (1, 1)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messagesAfter(afterRowID: 0, chatID: 1, limit: 10)
  #expect(messages.count == 1)
  #expect(messages.first?.text == "test transcript")
}
