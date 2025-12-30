import Foundation
import SQLite
import Testing

@testable import IMsgCore

private enum TestDatabase {
  static func appleEpoch(_ date: Date) -> Int64 {
    let seconds = date.timeIntervalSince1970 - MessageStore.appleEpochOffset
    return Int64(seconds * 1_000_000_000)
  }

  static func makeStore(includeAttributedBody: Bool = false) throws -> MessageStore {
    let db = try Connection(.inMemory)
    if includeAttributedBody {
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
    } else {
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
    }
    try db.execute(
      """
      CREATE TABLE chat (
        ROWID INTEGER PRIMARY KEY,
        chat_identifier TEXT,
        display_name TEXT,
        service_name TEXT
      );
      """
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
      INSERT INTO chat(ROWID, chat_identifier, display_name, service_name)
      VALUES (1, '+123', 'Test Chat', 'iMessage')
      """
    )
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123'), (2, 'Me')")

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

@Test
func listChatsReturnsChat() throws {
  let store = try TestDatabase.makeStore()
  let chats = try store.listChats(limit: 5)
  #expect(chats.count == 1)
  #expect(chats.first?.identifier == "+123")
}

@Test
func messagesByChatReturnsMessages() throws {
  let store = try TestDatabase.makeStore()
  let messages = try store.messages(chatID: 1, limit: 10)
  #expect(messages.count == 3)
  #expect(messages[1].isFromMe)
  #expect(messages[0].attachmentsCount == 0)
}

@Test
func messagesAfterReturnsMessages() throws {
  let store = try TestDatabase.makeStore()
  let messages = try store.messagesAfter(afterRowID: 1, chatID: nil, limit: 10)
  #expect(messages.count == 2)
  #expect(messages.first?.rowID == 2)
}

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
    INSERT INTO chat(ROWID, chat_identifier, display_name, service_name)
    VALUES (1, '+123', 'Test Chat', 'iMessage')
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
    INSERT INTO chat(ROWID, chat_identifier, display_name, service_name)
    VALUES (1, '+123', 'Test Chat', 'iMessage')
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
  #expect(messages.first?.text == text)
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
  try db.execute(
    """
    CREATE TABLE chat (
      ROWID INTEGER PRIMARY KEY,
      chat_identifier TEXT,
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
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, attributedBody, date, is_from_me, service)
    VALUES (1, 1, NULL, ?, ?, 0, 'iMessage')
    """,
    body,
    TestDatabase.appleEpoch(now)
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messagesAfter(afterRowID: 0, chatID: nil, limit: 10)
  #expect(messages.count == 1)
  #expect(messages.first?.text == "fallback text")
}

@Test
func attachmentsByMessageReturnsMetadata() throws {
  let store = try TestDatabase.makeStore()
  let attachments = try store.attachments(for: 2)
  #expect(attachments.count == 1)
  #expect(attachments.first?.mimeType == "application/octet-stream")
}

@Test
func longRepeatedPatternMessage() throws {
  // Test the exact pattern that causes crashes: repeated "aaaaaaaaaaaa " pattern
  // This reproduces the UInt8 overflow bug when segment.count > 256
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
  // Create message with repeated pattern like "aaaaaaaaaaaa aaaaaaaaaaaa ..."
  // This pattern triggers the UInt8 overflow bug in TypedStreamParser when segment > 256 bytes
  let pattern = "aaaaaaaaaaaa "
  // Creates a message > 1300 bytes
  let longText = String(repeating: pattern, count: 100)
  let bodyBytes = [UInt8(0x01), UInt8(0x2b)] + Array(longText.utf8) + [0x86, 0x84]
  let body = Blob(bytes: bodyBytes)
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, display_name, service_name)
    VALUES (1, '+123', 'Test Chat', 'iMessage')
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
  #expect(messages.first?.text == longText)
  #expect(messages.first?.text.count == longText.count)
}
