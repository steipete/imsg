import Foundation
import SQLite

extension MessageStore {
  public func attachments(for messageIDs: [Int64]) throws -> [Int64: [AttachmentMeta]] {
    let uniqueIDs = Array(Set(messageIDs))
    guard !uniqueIDs.isEmpty else { return [:] }

    let placeholders = Array(repeating: "?", count: uniqueIDs.count).joined(separator: ",")
    let sql = """
      SELECT maj.message_id, a.filename, a.transfer_name, a.uti, a.mime_type, a.total_bytes, a.is_sticker
      FROM message_attachment_join maj
      JOIN attachment a ON a.ROWID = maj.attachment_id
      WHERE maj.message_id IN (\(placeholders))
      ORDER BY maj.message_id ASC
      """
    let bindings: [Binding?] = uniqueIDs.map { $0 }

    return try withConnection { db in
      var metasByMessageID: [Int64: [AttachmentMeta]] = [:]
      for row in try db.prepare(sql, bindings) {
        let messageID = int64Value(row[0]) ?? 0
        let filename = stringValue(row[1])
        let transferName = stringValue(row[2])
        let uti = stringValue(row[3])
        let mimeType = stringValue(row[4])
        let totalBytes = int64Value(row[5]) ?? 0
        let isSticker = boolValue(row[6])
        let resolved = AttachmentResolver.resolve(filename)
        metasByMessageID[messageID, default: []].append(
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
      return metasByMessageID
    }
  }

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
      JOIN message r ON r.associated_message_guid = m.guid
        OR r.associated_message_guid LIKE '%/' || m.guid
      LEFT JOIN handle h ON r.handle_id = h.ROWID
      WHERE m.ROWID = ?
        AND m.guid IS NOT NULL
        AND m.guid != ''
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

        applyReactionRow(
          rowID: rowID,
          typeValue: typeValue,
          sender: sender,
          isFromMe: isFromMe,
          date: date,
          resolvedText: resolvedText,
          messageID: messageID,
          reactions: &reactions,
          reactionIndex: &reactionIndex
        )
      }
      return reactions
    }
  }

  public func reactions(for messages: [Message]) throws -> [Int64: [Reaction]] {
    guard hasReactionColumns else { return [:] }

    let messageIDByGUID: [String: Int64] = Dictionary(
      uniqueKeysWithValues: messages.compactMap { message in
        guard !message.guid.isEmpty else { return nil }
        return (message.guid, message.rowID)
      })
    guard !messageIDByGUID.isEmpty else { return [:] }

    let bodyColumn = hasAttributedBody ? "r.attributedBody" : "NULL"
    let sql = """
      SELECT r.ROWID, r.associated_message_guid, r.associated_message_type, h.id, r.is_from_me, r.date,
             IFNULL(r.text, '') AS text, \(bodyColumn) AS body
      FROM message r
      LEFT JOIN handle h ON r.handle_id = h.ROWID
      WHERE r.associated_message_guid IS NOT NULL
        AND r.associated_message_guid != ''
        AND r.associated_message_type >= 2000
        AND r.associated_message_type <= 3006
      ORDER BY r.date ASC
      """

    return try withConnection { db in
      var reactionsByMessageID: [Int64: [Reaction]] = [:]
      var reactionIndexByMessageID: [Int64: [ReactionKey: Int]] = [:]

      for row in try db.prepare(sql) {
        let associatedMessageGUID = stringValue(row[1])
        let baseGUID = baseAssociatedMessageGUID(from: associatedMessageGUID)
        guard let messageID = messageIDByGUID[baseGUID] else { continue }

        let rowID = int64Value(row[0]) ?? 0
        let typeValue = intValue(row[2]) ?? 0
        let sender = stringValue(row[3])
        let isFromMe = boolValue(row[4])
        let date = appleDate(from: int64Value(row[5]))
        let text = stringValue(row[6])
        let body = dataValue(row[7])
        let resolvedText = text.isEmpty ? TypedStreamParser.parseAttributedBody(body) : text

        var reactions = reactionsByMessageID[messageID, default: []]
        var reactionIndex = reactionIndexByMessageID[messageID] ?? [:]
        applyReactionRow(
          rowID: rowID,
          typeValue: typeValue,
          sender: sender,
          isFromMe: isFromMe,
          date: date,
          resolvedText: resolvedText,
          messageID: messageID,
          reactions: &reactions,
          reactionIndex: &reactionIndex
        )
        reactionsByMessageID[messageID] = reactions
        reactionIndexByMessageID[messageID] = reactionIndex
      }

      return reactionsByMessageID
    }
  }

  /// Extract custom emoji from reaction message text like "Reacted 🎉 to "original message""
  func extractCustomEmoji(from text: String) -> String? {
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

  private func baseAssociatedMessageGUID(from associatedGUID: String) -> String {
    guard let slashIndex = associatedGUID.lastIndex(of: "/") else { return associatedGUID }
    let guidStart = associatedGUID.index(after: slashIndex)
    return String(associatedGUID[guidStart...])
  }

  private func applyReactionRow(
    rowID: Int64,
    typeValue: Int,
    sender: String,
    isFromMe: Bool,
    date: Date,
    resolvedText: String,
    messageID: Int64,
    reactions: inout [Reaction],
    reactionIndex: inout [ReactionKey: Int]
  ) {
    if ReactionType.isReactionRemove(typeValue) {
      let customEmoji = typeValue == 3006 ? extractCustomEmoji(from: resolvedText) : nil
      let reactionType = ReactionType.fromRemoval(typeValue, customEmoji: customEmoji)
      if let reactionType {
        let key = ReactionKey(sender: sender, isFromMe: isFromMe, reactionType: reactionType)
        if let index = reactionIndex.removeValue(forKey: key) {
          reactions.remove(at: index)
          reactionIndex = ReactionKey.reindex(reactions: reactions)
        }
        return
      }
      if typeValue == 3006 {
        if let index = reactions.firstIndex(where: {
          $0.sender == sender && $0.isFromMe == isFromMe && $0.reactionType.isCustom
        }) {
          reactions.remove(at: index)
          reactionIndex = ReactionKey.reindex(reactions: reactions)
        }
      }
      return
    }

    let customEmoji: String? = typeValue == 2006 ? extractCustomEmoji(from: resolvedText) : nil
    guard let reactionType = ReactionType(rawValue: typeValue, customEmoji: customEmoji) else {
      return
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
