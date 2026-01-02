import Foundation
import SQLite

@testable import IMsgCore

enum TestDatabase {
  static func appleEpoch(_ date: Date) -> Int64 {
    let seconds = date.timeIntervalSince1970 - MessageStore.appleEpochOffset
    return Int64(seconds * 1_000_000_000)
  }

  static func makeStore(
    includeAttributedBody: Bool = false,
    includeReactionColumns: Bool = false
  ) throws -> MessageStore {
    let db = try Connection(.inMemory)
    let attributedBodyColumn = includeAttributedBody ? "attributedBody BLOB," : ""

    let reactionColumns: String
    if includeReactionColumns {
      reactionColumns = "guid TEXT, associated_message_guid TEXT, associated_message_type INTEGER,"
    } else {
      reactionColumns = ""
    }

    try db.execute(
      """
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        handle_id INTEGER,
        text TEXT,
        \(attributedBodyColumn)
        \(reactionColumns)
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
    try db.execute("CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);")
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
        is_sticker INTEGER
      );
      """
    )
    try db.execute(
      """
      CREATE TABLE message_attachment_join (
        message_id INTEGER,
        attachment_id INTEGER
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
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123'), (2, 'Me')")
    try db.run("INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 1), (1, 2)")

    let messageRows: [(Int64, Int64, String?, Bool, Date, Int)] = [
      (1, 1, "hello", false, now.addingTimeInterval(-600), 0),
      (2, 2, "hi back", true, now.addingTimeInterval(-500), 1),
      (3, 1, "photo", false, now.addingTimeInterval(-60), 0),
    ]
    for row in messageRows {
      try db.run(
        """
        INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
        VALUES (?,?,?,?,?,?)
        """,
        row.0,
        row.1,
        row.2,
        appleEpoch(row.4),
        row.3 ? 1 : 0,
        "iMessage"
      )
      try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, ?)", row.0)
      if row.5 > 0 {
        try db.run(
          """
          INSERT INTO attachment(
            ROWID,
            filename,
            transfer_name,
            uti,
            mime_type,
            total_bytes,
            is_sticker
          )
          VALUES (1, '~/Library/Messages/Attachments/test.dat', 'test.dat', 'public.data', 'application/octet-stream', 123, 0)
          """
        )
        try db.run(
          """
          INSERT INTO message_attachment_join(message_id, attachment_id)
          VALUES (?, 1)
          """,
          row.0
        )
      }
    }

    return try MessageStore(connection: db, path: ":memory:")
  }
}
