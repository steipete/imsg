import Foundation
import SQLite

public final class MessageStore: @unchecked Sendable {
  public static let appleEpochOffset: TimeInterval = 978_307_200

  public static var defaultPath: String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return NSString(string: home).appendingPathComponent("Library/Messages/chat.db")
  }

  public let path: String

  private let connection: Connection
  private let queue: DispatchQueue
  private let queueKey = DispatchSpecificKey<Void>()
  private let hasAttributedBody: Bool
  private let hasReactionColumns: Bool

  public init(path: String = MessageStore.defaultPath) throws {
    let normalized = NSString(string: path).expandingTildeInPath
    self.path = normalized
    self.queue = DispatchQueue(label: "imsg.db", qos: .userInitiated)
    self.queue.setSpecific(key: queueKey, value: ())
    do {
      let uri = URL(fileURLWithPath: normalized).absoluteString
      let location = Connection.Location.uri(uri, parameters: [.mode(.readOnly)])
      self.connection = try Connection(location, readonly: true)
      self.connection.busyTimeout = 5
      self.hasAttributedBody = MessageStore.detectAttributedBody(connection: self.connection)
      self.hasReactionColumns = MessageStore.detectReactionColumns(connection: self.connection)
    } catch {
      throw MessageStore.enhance(error: error, path: normalized)
    }
  }

  init(
    connection: Connection,
    path: String,
    hasAttributedBody: Bool? = nil,
    hasReactionColumns: Bool? = nil
  ) throws {
    self.path = path
    self.queue = DispatchQueue(label: "imsg.db.test", qos: .userInitiated)
    self.queue.setSpecific(key: queueKey, value: ())
    self.connection = connection
    self.connection.busyTimeout = 5
    if let hasAttributedBody {
      self.hasAttributedBody = hasAttributedBody
    } else {
      self.hasAttributedBody = MessageStore.detectAttributedBody(connection: connection)
    }
    if let hasReactionColumns {
      self.hasReactionColumns = hasReactionColumns
    } else {
      self.hasReactionColumns = MessageStore.detectReactionColumns(connection: connection)
    }
  }

  public func listChats(limit: Int) throws -> [Chat] {
    let sql = """
      SELECT c.ROWID, IFNULL(c.display_name, c.chat_identifier) AS name, c.chat_identifier, c.service_name,
             MAX(m.date) AS last_date
      FROM chat c
      JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
      JOIN message m ON m.ROWID = cmj.message_id
      GROUP BY c.ROWID
      ORDER BY last_date DESC
      LIMIT ?
      """
    return try withConnection { db in
      var chats: [Chat] = []
      for row in try db.prepare(sql, limit) {
        let id = int64Value(row[0]) ?? 0
        let name = stringValue(row[1])
        let identifier = stringValue(row[2])
        let service = stringValue(row[3])
        let lastDate = appleDate(from: int64Value(row[4]))
        chats.append(
          Chat(
            id: id, identifier: identifier, name: name, service: service, lastMessageAt: lastDate))
      }
      return chats
    }
  }

  public func messages(chatID: Int64, limit: Int) throws -> [Message] {
    let bodyColumn = hasAttributedBody ? "m.attributedBody" : "NULL"
    let sql = """
      SELECT m.ROWID, m.handle_id, h.id, IFNULL(m.text, '') AS text, m.date, m.is_from_me, m.service,
             (SELECT COUNT(*) FROM message_attachment_join maj WHERE maj.message_id = m.ROWID) AS attachments,
             \(bodyColumn) AS body
      FROM message m
      JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      WHERE cmj.chat_id = ?
      ORDER BY m.date DESC
      LIMIT ?
      """
    return try withConnection { db in
      var messages: [Message] = []
      for row in try db.prepare(sql, chatID, limit) {
        let rowID = int64Value(row[0]) ?? 0
        let handleID = int64Value(row[1])
        let sender = stringValue(row[2])
        let text = stringValue(row[3])
        let date = appleDate(from: int64Value(row[4]))
        let isFromMe = boolValue(row[5])
        let service = stringValue(row[6])
        let attachments = intValue(row[7]) ?? 0
        let body = dataValue(row[8])
        let resolvedText = text.isEmpty ? TypedStreamParser.parseAttributedBody(body) : text
        messages.append(
          Message(
            rowID: rowID,
            chatID: chatID,
            sender: sender,
            text: resolvedText,
            date: date,
            isFromMe: isFromMe,
            service: service,
            handleID: handleID,
            attachmentsCount: attachments
          ))
      }
      return messages
    }
  }

  public func messagesAfter(afterRowID: Int64, chatID: Int64?, limit: Int) throws -> [Message] {
    let bodyColumn = hasAttributedBody ? "m.attributedBody" : "NULL"
    var sql = """
      SELECT m.ROWID, cmj.chat_id, m.handle_id, h.id, IFNULL(m.text, '') AS text, m.date, m.is_from_me, m.service,
             (SELECT COUNT(*) FROM message_attachment_join maj WHERE maj.message_id = m.ROWID) AS attachments,
             \(bodyColumn) AS body
      FROM message m
      LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      WHERE m.ROWID > ?
      """
    var bindings: [Binding?] = [afterRowID]
    if let chatID {
      sql += " AND cmj.chat_id = ?"
      bindings.append(chatID)
    }
    sql += " ORDER BY m.ROWID ASC LIMIT ?"
    bindings.append(limit)

    return try withConnection { db in
      var messages: [Message] = []
      for row in try db.prepare(sql, bindings) {
        let rowID = int64Value(row[0]) ?? 0
        let resolvedChatID = int64Value(row[1]) ?? chatID ?? 0
        let handleID = int64Value(row[2])
        let sender = stringValue(row[3])
        let text = stringValue(row[4])
        let date = appleDate(from: int64Value(row[5]))
        let isFromMe = boolValue(row[6])
        let service = stringValue(row[7])
        let attachments = intValue(row[8]) ?? 0
        let body = dataValue(row[9])
        let resolvedText = text.isEmpty ? TypedStreamParser.parseAttributedBody(body) : text
        messages.append(
          Message(
            rowID: rowID,
            chatID: resolvedChatID,
            sender: sender,
            text: resolvedText,
            date: date,
            isFromMe: isFromMe,
            service: service,
            handleID: handleID,
            attachmentsCount: attachments
          ))
      }
      return messages
    }
  }

  public func attachments(for messageID: Int64) throws -> [AttachmentMeta] {
    let sql = """
      SELECT a.filename, a.transfer_name, a.uti, a.mime_type, a.total_bytes, a.is_sticker
      FROM message_attachment_join maj
      JOIN attachment a ON a.ROWID = maj.attachment_id
      WHERE maj.message_id = ?
      """
    return try withConnection { db in
      var metas: [AttachmentMeta] = []
      for row in try db.prepare(sql, messageID) {
        let filename = stringValue(row[0])
        let transferName = stringValue(row[1])
        let uti = stringValue(row[2])
        let mimeType = stringValue(row[3])
        let totalBytes = int64Value(row[4]) ?? 0
        let isSticker = boolValue(row[5])
        let resolved = AttachmentResolver.resolve(filename)
        metas.append(
          AttachmentMeta(
            filename: filename,
            transferName: transferName,
            uti: uti,
            mimeType: mimeType,
            totalBytes: totalBytes,
            isSticker: isSticker,
            originalPath: resolved.resolved,
            missing: resolved.missing
          ))
      }
      return metas
    }
  }

  public func maxRowID() throws -> Int64 {
    return try withConnection { db in
      let value = try db.scalar("SELECT MAX(ROWID) FROM message")
      return int64Value(value) ?? 0
    }
  }

  private func withConnection<T>(_ block: (Connection) throws -> T) throws -> T {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      return try block(connection)
    }
    return try queue.sync {
      try block(connection)
    }
  }

  private static func detectAttributedBody(connection: Connection) -> Bool {
    do {
      let rows = try connection.prepare("PRAGMA table_info(message)")
      for row in rows {
        if let name = row[1] as? String,
          name.caseInsensitiveCompare("attributedBody") == .orderedSame
        {
          return true
        }
      }
    } catch {
      return false
    }
    return false
  }

  private static func enhance(error: Error, path: String) -> Error {
    let message = String(describing: error).lowercased()
    if message.contains("out of memory (14)") || message.contains("authorization denied")
      || message.contains("unable to open database") || message.contains("cannot open")
    {
      return IMsgError.permissionDenied(path: path, underlying: error)
    }
    return error
  }

  private func appleDate(from value: Int64?) -> Date {
    guard let value else { return Date(timeIntervalSince1970: MessageStore.appleEpochOffset) }
    return Date(
      timeIntervalSince1970: (Double(value) / 1_000_000_000) + MessageStore.appleEpochOffset)
  }

  private func stringValue(_ binding: Binding?) -> String {
    return binding as? String ?? ""
  }

  private func int64Value(_ binding: Binding?) -> Int64? {
    if let value = binding as? Int64 { return value }
    if let value = binding as? Int { return Int64(value) }
    if let value = binding as? Double { return Int64(value) }
    return nil
  }

  private func intValue(_ binding: Binding?) -> Int? {
    if let value = binding as? Int { return value }
    if let value = binding as? Int64 { return Int(value) }
    if let value = binding as? Double { return Int(value) }
    return nil
  }

  private func boolValue(_ binding: Binding?) -> Bool {
    if let value = binding as? Bool { return value }
    if let value = intValue(binding) { return value != 0 }
    return false
  }

  private func dataValue(_ binding: Binding?) -> Data {
    if let blob = binding as? Blob {
      return Data(blob.bytes)
    }
    return Data()
  }
}

extension MessageStore {
  public func reactions(for messageID: Int64) throws -> [Reaction] {
    guard hasReactionColumns else { return [] }
    // Reactions are stored as messages with associated_message_type in range 2000-2006
    // 2000-2005 are standard tapbacks, 2006 is custom emoji reactions
    // They reference the original message via associated_message_guid which has format "p:X/GUID"
    // where X is the part index (0 for single-part messages) and GUID matches the original message's guid
    let bodyColumn = hasAttributedBody ? "r.attributedBody" : "NULL"
    let sql = """
      SELECT r.ROWID, r.associated_message_type, h.id, r.is_from_me, r.date, IFNULL(r.text, '') as text,
             \(bodyColumn) AS body
      FROM message m
      JOIN message r ON r.associated_message_guid LIKE '%' || m.guid
      LEFT JOIN handle h ON r.handle_id = h.ROWID
      WHERE m.ROWID = ?
        AND r.associated_message_type >= 2000
        AND r.associated_message_type <= 3006
      ORDER BY r.date ASC
      """
    return try withConnection { db in
      var reactions: [Reaction] = []
      var reactionIndex: [ReactionKey: Int] = [:]
      for row in try db.prepare(sql, messageID) {
        let rowID = int64Value(row[0]) ?? 0
        let typeValue = intValue(row[1]) ?? 0
        let sender = stringValue(row[2])
        let isFromMe = boolValue(row[3])
        let date = appleDate(from: int64Value(row[4]))
        let text = stringValue(row[5])
        let body = dataValue(row[6])
        let resolvedText = text.isEmpty ? TypedStreamParser.parseAttributedBody(body) : text

        if ReactionType.isReactionRemove(typeValue) {
          let customEmoji = typeValue == 3006 ? extractCustomEmoji(from: resolvedText) : nil
          let reactionType = ReactionType.fromRemoval(typeValue, customEmoji: customEmoji)
          if let reactionType {
            let key = ReactionKey(sender: sender, isFromMe: isFromMe, reactionType: reactionType)
            if let index = reactionIndex.removeValue(forKey: key) {
              reactions.remove(at: index)
              reactionIndex = ReactionKey.reindex(reactions: reactions)
            }
            continue
          }
          if typeValue == 3006 {
            if let index = reactions.firstIndex(where: {
              $0.sender == sender && $0.isFromMe == isFromMe && $0.reactionType.isCustom
            }) {
              reactions.remove(at: index)
              reactionIndex = ReactionKey.reindex(reactions: reactions)
            }
          }
          continue
        }

        let customEmoji: String? = typeValue == 2006 ? extractCustomEmoji(from: resolvedText) : nil
        guard let reactionType = ReactionType(rawValue: typeValue, customEmoji: customEmoji) else {
          continue
        }

        let key = ReactionKey(sender: sender, isFromMe: isFromMe, reactionType: reactionType)
        if let index = reactionIndex[key] {
          reactions[index] = Reaction(
            rowID: rowID,
            reactionType: reactionType,
            sender: sender,
            isFromMe: isFromMe,
            date: date,
            associatedMessageID: messageID
          )
        } else {
          reactionIndex[key] = reactions.count
          reactions.append(
            Reaction(
              rowID: rowID,
              reactionType: reactionType,
              sender: sender,
              isFromMe: isFromMe,
              date: date,
              associatedMessageID: messageID
            ))
        }
      }
      return reactions
    }
  }

  /// Extract custom emoji from reaction message text like "Reacted 🎉 to "original message""
  private func extractCustomEmoji(from text: String) -> String? {
    // Format: "Reacted X to "..." where X is the emoji. Fallback to first emoji in text.
    guard
      let reactedRange = text.range(of: "Reacted "),
      let toRange = text.range(of: " to ", range: reactedRange.upperBound..<text.endIndex)
    else {
      return extractFirstEmoji(from: text)
    }
    let emoji = String(text[reactedRange.upperBound..<toRange.lowerBound])
    return emoji.isEmpty ? extractFirstEmoji(from: text) : emoji
  }

  private func extractFirstEmoji(from text: String) -> String? {
    for character in text {
      if character.unicodeScalars.contains(where: {
        $0.properties.isEmojiPresentation || $0.properties.isEmoji
      }) {
        return String(character)
      }
    }
    return nil
  }

  private static func detectReactionColumns(connection: Connection) -> Bool {
    do {
      let rows = try connection.prepare("PRAGMA table_info(message)")
      var columns = Set<String>()
      for row in rows {
        if let name = row[1] as? String {
          columns.insert(name.lowercased())
        }
      }
      return columns.contains("guid")
        && columns.contains("associated_message_guid")
        && columns.contains("associated_message_type")
    } catch {
      return false
    }
  }

  private struct ReactionKey: Hashable {
    let sender: String
    let isFromMe: Bool
    let reactionType: ReactionType

    static func reindex(reactions: [Reaction]) -> [ReactionKey: Int] {
      var index: [ReactionKey: Int] = [:]
      for (offset, reaction) in reactions.enumerated() {
        let key = ReactionKey(
          sender: reaction.sender,
          isFromMe: reaction.isFromMe,
          reactionType: reaction.reactionType
        )
        index[key] = offset
      }
      return index
    }
  }
}
