import Foundation
import SQLite

/// A reaction event represents when someone adds or removes a reaction to a message.
/// Unlike `Reaction` which represents the current state, this captures the event itself.
public struct ReactionEvent: Sendable, Equatable {
  /// The ROWID of the reaction message in the database
  public let rowID: Int64
  /// The chat ID where the reaction occurred
  public let chatID: Int64
  /// The type of reaction
  public let reactionType: ReactionType
  /// Whether this is adding (true) or removing (false) a reaction
  public let isAdd: Bool
  /// The sender of the reaction (phone number or email)
  public let sender: String
  /// Whether the reaction was sent by the current user
  public let isFromMe: Bool
  /// When the reaction event occurred
  public let date: Date
  /// The GUID of the message being reacted to
  public let reactedToGUID: String
  /// The ROWID of the message being reacted to (if available)
  public let reactedToID: Int64?
  /// The original text of the reaction message (e.g., "Liked \"hello\"")
  public let text: String

  public init(
    rowID: Int64,
    chatID: Int64,
    reactionType: ReactionType,
    isAdd: Bool,
    sender: String,
    isFromMe: Bool,
    date: Date,
    reactedToGUID: String,
    reactedToID: Int64?,
    text: String
  ) {
    self.rowID = rowID
    self.chatID = chatID
    self.reactionType = reactionType
    self.isAdd = isAdd
    self.sender = sender
    self.isFromMe = isFromMe
    self.date = date
    self.reactedToGUID = reactedToGUID
    self.reactedToID = reactedToID
    self.text = text
  }
}

extension MessageStore {
  /// Fetch reaction events (add/remove) after a given rowID.
  /// These are the reaction messages themselves, useful for streaming reaction events in watch mode.
  public func reactionEventsAfter(afterRowID: Int64, chatID: Int64?, limit: Int) throws -> [ReactionEvent] {
    guard hasReactionColumns else { return [] }
    
    let bodyColumn = hasAttributedBody ? "m.attributedBody" : "NULL"
    let destinationCallerColumn = hasDestinationCallerID ? "m.destination_caller_id" : "NULL"
    
    var sql = """
      SELECT m.ROWID, cmj.chat_id, m.associated_message_type, m.associated_message_guid,
             m.handle_id, h.id, m.is_from_me, m.date, IFNULL(m.text, '') AS text,
             \(destinationCallerColumn) AS destination_caller_id,
             \(bodyColumn) AS body,
             orig.ROWID AS orig_rowid
      FROM message m
      LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      LEFT JOIN message orig ON (orig.guid = m.associated_message_guid 
        OR m.associated_message_guid LIKE '%/' || orig.guid)
      WHERE m.ROWID > ?
        AND m.associated_message_type >= 2000
        AND m.associated_message_type <= 3006
      """
    var bindings: [Binding?] = [afterRowID]
    
    if let chatID {
      sql += " AND cmj.chat_id = ?"
      bindings.append(chatID)
    }
    sql += " ORDER BY m.ROWID ASC LIMIT ?"
    bindings.append(limit)
    
    return try withConnection { db in
      var events: [ReactionEvent] = []
      for row in try db.prepare(sql, bindings) {
        let rowID = int64Value(row[0]) ?? 0
        let resolvedChatID = int64Value(row[1]) ?? chatID ?? 0
        let typeValue = intValue(row[2]) ?? 0
        let associatedGUID = stringValue(row[3])
        // let handleID = int64Value(row[4])
        var sender = stringValue(row[5])
        let isFromMe = boolValue(row[6])
        let date = appleDate(from: int64Value(row[7]))
        let text = stringValue(row[8])
        let destinationCallerID = stringValue(row[9])
        let body = dataValue(row[10])
        let origRowID = int64Value(row[11])
        
        if sender.isEmpty && !destinationCallerID.isEmpty {
          sender = destinationCallerID
        }
        
        let resolvedText = text.isEmpty ? TypedStreamParser.parseAttributedBody(body) : text
        let isAdd = ReactionType.isReactionAdd(typeValue)
        let rawType = isAdd ? typeValue : typeValue - 1000
        
        // Extract custom emoji for type 2006/3006
        let customEmoji: String? = (rawType == 2006) ? extractCustomEmoji(from: resolvedText) : nil
        guard let reactionType = ReactionType(rawValue: rawType, customEmoji: customEmoji) else {
          continue
        }
        
        // Normalize the associated GUID (remove "p:X/" prefix)
        let reactedToGUID = normalizeAssociatedGUID(associatedGUID)
        
        events.append(ReactionEvent(
          rowID: rowID,
          chatID: resolvedChatID,
          reactionType: reactionType,
          isAdd: isAdd,
          sender: sender,
          isFromMe: isFromMe,
          date: date,
          reactedToGUID: reactedToGUID,
          reactedToID: origRowID,
          text: resolvedText
        ))
      }
      return events
    }
  }
  
}
