import Foundation
import SQLite

@testable import IMsgCore

enum CommandTestDatabase {
  static func appleEpoch(_ date: Date) -> Int64 {
    let seconds = date.timeIntervalSince1970 - MessageStore.appleEpochOffset
    return Int64(seconds * 1_000_000_000)
  }

  static func makePath() throws -> String {
    let path = try makeDatabasePath()
    let db = try Connection(path)
    try createSchema(db, includeChatHandleJoin: false)
    try seedBasicChat(db)
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

  static func makeStoreForRPC() throws -> MessageStore {
    let db = try Connection(.inMemory)
    try createSchema(db, includeChatHandleJoin: true)
    try seedRPCChat(db)
    return try MessageStore(
      connection: db,
      path: ":memory:",
      hasAttributedBody: false,
      hasReactionColumns: false
    )
  }

  private static func makeDatabasePath() throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("chat.db").path
  }

  private static func createSchema(_ db: Connection, includeChatHandleJoin: Bool) throws {
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
    if includeChatHandleJoin {
      try db.execute("CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);")
    }
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
  }

  private static func seedBasicChat(_ db: Connection) throws {
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
  }

  private static func seedRPCChat(_ db: Connection) throws {
    let now = Date()
    try db.run(
      """
      INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
      VALUES (1, 'iMessage;+;chat123', 'iMessage;+;chat123', 'Group Chat', 'iMessage')
      """
    )
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123'), (2, 'me@icloud.com')")
    try db.run("INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 1), (1, 2)")
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
      VALUES (5, 1, 'hello', ?, 0, 'iMessage')
      """,
      appleEpoch(now)
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 5)")
  }
}
