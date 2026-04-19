import Foundation
import SQLite
import Testing

@testable import IMsgCore

@Suite
struct MessageStoreByGUIDTests {
  @Test
  func returnsNilForEmptyGUID() throws {
    let store = try TestDatabase.makeStore(includeReactionColumns: true)
    #expect(try store.messageByGUID("") == nil)
    #expect(try store.messageByGUID("   ") == nil)
  }

  @Test
  func returnsNilForUnknownGUID() throws {
    let store = try makeStoreWithGUIDs()
    #expect(try store.messageByGUID("NONEXISTENT-GUID") == nil)
  }

  @Test
  func resolvesExistingGUIDToMessage() throws {
    let store = try makeStoreWithGUIDs()
    let resolved = try #require(try store.messageByGUID("AAA-111"))
    #expect(resolved.rowID == 10)
    #expect(resolved.text == "hello from GUID")
    #expect(resolved.guid == "AAA-111")
    #expect(resolved.isFromMe == false)
    #expect(resolved.sender == "+14155550123")
  }

  @Test
  func returnsOnlyFirstMatchOnLimit1() throws {
    // Two messages with the same GUID shouldn't happen in practice but we
    // defend against it with LIMIT 1 in the SQL.
    let store = try makeStoreWithGUIDs(addDuplicateGUID: true)
    let resolved = try #require(try store.messageByGUID("AAA-111"))
    #expect(resolved.rowID == 10)  // Lower ROWID wins via ORDER BY default
  }

  private func makeStoreWithGUIDs(addDuplicateGUID: Bool = false) throws -> MessageStore {
    let db = try Connection(.inMemory)
    try db.execute(
      """
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        handle_id INTEGER,
        text TEXT,
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
      "CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, guid TEXT, display_name TEXT, service_name TEXT);"
    )
    try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
    try db.execute("CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);")
    try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);")
    try db.execute(
      """
      CREATE TABLE attachment (
        ROWID INTEGER PRIMARY KEY,
        filename TEXT, transfer_name TEXT, uti TEXT, mime_type TEXT,
        total_bytes INTEGER, is_sticker INTEGER
      );
      """
    )
    try db.execute(
      "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);"
    )

    let now = Date()
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+14155550123'), (2, 'Me')")
    try db.run(
      "INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name) VALUES (1, '+14155550123', 'iMessage;+;chat1', 'Test', 'iMessage')"
    )
    try db.run("INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 1), (1, 2)")

    let rows: [(Int64, Int64, String, String, Date, Bool)] = [
      (10, 1, "hello from GUID", "AAA-111", now.addingTimeInterval(-300), false),
      (11, 2, "reply!", "BBB-222", now.addingTimeInterval(-200), true),
    ]
    for r in rows {
      try db.run(
        "INSERT INTO message(ROWID, handle_id, text, guid, date, is_from_me, service) VALUES (?,?,?,?,?,?,?)",
        r.0, r.1, r.2, r.3, TestDatabase.appleEpoch(r.4), r.5 ? 1 : 0, "iMessage"
      )
      try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, ?)", r.0)
    }

    if addDuplicateGUID {
      try db.run(
        "INSERT INTO message(ROWID, handle_id, text, guid, date, is_from_me, service) VALUES (?,?,?,?,?,?,?)",
        Int64(12), Int64(1), "duplicate", "AAA-111",
        TestDatabase.appleEpoch(now.addingTimeInterval(-100)), 0, "iMessage"
      )
      try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, ?)", Int64(12))
    }

    return try MessageStore(connection: db, path: ":memory:")
  }
}
