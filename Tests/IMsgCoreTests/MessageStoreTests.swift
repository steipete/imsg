import Foundation
import SQLite
import Testing

@testable import IMsgCore

private enum TestDatabase {
  static func appleEpoch(_ date: Date) -> Int64 {
    let seconds = date.timeIntervalSince1970 - MessageStore.appleEpochOffset
    return Int64(seconds * 1_000_000_000)
  }

  static func makeStore(includeAttributedBody: Bool = false, includeReactionColumns: Bool = false) throws -> MessageStore {
    let db = try Connection(.inMemory)
    let attributedBodyColumn = includeAttributedBody ? "attributedBody BLOB," : ""
    let reactionColumns = includeReactionColumns ? "guid TEXT, associated_message_guid TEXT, associated_message_type INTEGER," : ""
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

@Test
func reactionsForMessageReturnsReactions() throws {
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
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, display_name, service_name)
    VALUES (1, '+123', 'Test Chat', 'iMessage')
    """
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123'), (2, '+456')")

  // Insert the original message with a guid
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (1, 1, 'Hello world', 'msg-guid-1', NULL, 0, ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(now.addingTimeInterval(-600))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")

  // Insert reactions to the message
  // associated_message_guid format is "p:X/GUID" where X is the part index
  // Love reaction from +456
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (2, 2, '', 'reaction-guid-1', 'p:0/msg-guid-1', 2000, ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(now.addingTimeInterval(-500))
  )
  // Like reaction from me
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (3, 1, '', 'reaction-guid-2', 'p:0/msg-guid-1', 2001, ?, 1, 'iMessage')
    """,
    TestDatabase.appleEpoch(now.addingTimeInterval(-400))
  )
  // Laugh reaction from +456
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (4, 2, '', 'reaction-guid-3', 'p:0/msg-guid-1', 2003, ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(now.addingTimeInterval(-300))
  )
  // Custom emoji reaction (type 2006) from +456
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (5, 2, 'Reacted 🎉 to "Hello world"', 'reaction-guid-4', 'p:0/msg-guid-1', 2006, ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(now.addingTimeInterval(-200))
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let reactions = try store.reactions(for: 1)

  #expect(reactions.count == 4)

  // First reaction: Love from +456
  #expect(reactions[0].reactionType == .love)
  #expect(reactions[0].sender == "+456")
  #expect(reactions[0].isFromMe == false)

  // Second reaction: Like from me
  #expect(reactions[1].reactionType == .like)
  #expect(reactions[1].isFromMe == true)

  // Third reaction: Laugh from +456
  #expect(reactions[2].reactionType == .laugh)
  #expect(reactions[2].sender == "+456")

  // Fourth reaction: Custom emoji 🎉 from +456
  #expect(reactions[3].reactionType == .custom("🎉"))
  #expect(reactions[3].reactionType.emoji == "🎉")
  #expect(reactions[3].sender == "+456")
}

@Test
func reactionsForMessageWithNoReactionsReturnsEmpty() throws {
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
  try db.run(
    """
    INSERT INTO chat(ROWID, chat_identifier, display_name, service_name)
    VALUES (1, '+123', 'Test Chat', 'iMessage')
    """
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")

  // Insert a message with no reactions
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
    VALUES (1, 1, 'No reactions here', 'msg-guid-1', NULL, 0, ?, 0, 'iMessage')
    """,
    TestDatabase.appleEpoch(now)
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")

  let store = try MessageStore(connection: db, path: ":memory:")
  let reactions = try store.reactions(for: 1)

  #expect(reactions.isEmpty)
}

@Test
func reactionTypeProperties() throws {
  #expect(ReactionType.love.name == "love")
  #expect(ReactionType.love.emoji == "❤️")
  #expect(ReactionType.like.name == "like")
  #expect(ReactionType.like.emoji == "👍")
  #expect(ReactionType.dislike.name == "dislike")
  #expect(ReactionType.dislike.emoji == "👎")
  #expect(ReactionType.laugh.name == "laugh")
  #expect(ReactionType.laugh.emoji == "😂")
  #expect(ReactionType.emphasis.name == "emphasis")
  #expect(ReactionType.emphasis.emoji == "‼️")
  #expect(ReactionType.question.name == "question")
  #expect(ReactionType.question.emoji == "❓")
  #expect(ReactionType.custom("🎉").name == "custom")
  #expect(ReactionType.custom("🎉").emoji == "🎉")
}

@Test
func reactionTypeFromRawValue() throws {
  #expect(ReactionType(rawValue: 2000) == .love)
  #expect(ReactionType(rawValue: 2001) == .like)
  #expect(ReactionType(rawValue: 2002) == .dislike)
  #expect(ReactionType(rawValue: 2003) == .laugh)
  #expect(ReactionType(rawValue: 2004) == .emphasis)
  #expect(ReactionType(rawValue: 2005) == .question)
  #expect(ReactionType(rawValue: 2006, customEmoji: "🎉") == .custom("🎉"))
  #expect(ReactionType(rawValue: 2006) == nil)  // 2006 requires customEmoji
  #expect(ReactionType(rawValue: 9999) == nil)
}

@Test
func reactionTypeHelpers() throws {
  #expect(ReactionType.isReactionAdd(2000) == true)
  #expect(ReactionType.isReactionAdd(2005) == true)
  #expect(ReactionType.isReactionAdd(2006) == true)
  #expect(ReactionType.isReactionAdd(1999) == false)
  #expect(ReactionType.isReactionAdd(2007) == false)

  #expect(ReactionType.isReactionRemove(3000) == true)
  #expect(ReactionType.isReactionRemove(3005) == true)
  #expect(ReactionType.isReactionRemove(3006) == true)
  #expect(ReactionType.isReactionRemove(2999) == false)
  #expect(ReactionType.isReactionRemove(3007) == false)

  #expect(ReactionType.fromRemoval(3000) == .love)
  #expect(ReactionType.fromRemoval(3001) == .like)
  #expect(ReactionType.fromRemoval(3005) == .question)
  #expect(ReactionType.fromRemoval(3006, customEmoji: "🎉") == .custom("🎉"))
}
