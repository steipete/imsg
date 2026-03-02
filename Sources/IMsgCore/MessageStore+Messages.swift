import Foundation
import SQLite

private struct MessageRowColumns {
  let rowID: Int
  let chatID: Int?
  let handleID: Int
  let sender: Int
  let text: Int
  let date: Int
  let isFromMe: Int
  let service: Int
  let chatStyle: Int
  let isAudioMessage: Int
  let destinationCallerID: Int
  let guid: Int
  let associatedGUID: Int
  let associatedType: Int
  let attachments: Int
  let body: Int
  let threadOriginatorGUID: Int
}

private struct DecodedMessageRow {
  let rowID: Int64
  let chatID: Int64
  let handleID: Int64?
  let sender: String
  let text: String
  let date: Date
  let isFromMe: Bool
  let service: String
  let isGroup: Bool
  let destinationCallerID: String
  let guid: String
  let associatedGUID: String
  let associatedType: Int?
  let attachments: Int
  let threadOriginatorGUID: String
}

extension MessageStore {
  public func messages(chatID: Int64, limit: Int) throws -> [Message] {
    return try messages(chatID: chatID, limit: limit, filter: nil)
  }

  public func messages(chatID: Int64, limit: Int, filter: MessageFilter?) throws -> [Message] {
    let bodyColumn = hasAttributedBody ? "m.attributedBody" : "NULL"
    let guidColumn = hasReactionColumns ? "m.guid" : "NULL"
    let associatedGuidColumn = hasReactionColumns ? "m.associated_message_guid" : "NULL"
    let associatedTypeColumn = hasReactionColumns ? "m.associated_message_type" : "NULL"
    let destinationCallerColumn = hasDestinationCallerID ? "m.destination_caller_id" : "NULL"
    let audioMessageColumn = hasAudioMessageColumn ? "m.is_audio_message" : "0"
    let chatStyleColumn = hasChatStyleColumn ? "c.style" : "NULL"
    let chatJoin = hasChatStyleColumn ? "JOIN chat c ON cmj.chat_id = c.ROWID" : ""
    let threadOriginatorColumn =
      hasThreadOriginatorGUIDColumn ? "m.thread_originator_guid" : "NULL"
    let reactionFilter =
      hasReactionColumns
      ? " AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000 OR m.associated_message_type > 3006)"
      : ""
    var sql = """
      SELECT m.ROWID, m.handle_id, h.id, IFNULL(m.text, '') AS text, m.date, m.is_from_me, m.service,
             \(chatStyleColumn) AS chat_style,
             \(audioMessageColumn) AS is_audio_message, \(destinationCallerColumn) AS destination_caller_id,
             \(guidColumn) AS guid, \(associatedGuidColumn) AS associated_guid, \(associatedTypeColumn) AS associated_type,
             (SELECT COUNT(*) FROM message_attachment_join maj WHERE maj.message_id = m.ROWID) AS attachments,
             \(bodyColumn) AS body,
             \(threadOriginatorColumn) AS thread_originator_guid
      FROM message m
      JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
      \(chatJoin)
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      WHERE cmj.chat_id = ?\(reactionFilter)
      """
    var bindings: [Binding?] = [chatID]

    if let filter {
      if let startDate = filter.startDate {
        sql += " AND m.date >= ?"
        bindings.append(MessageStore.appleEpoch(startDate))
      }
      if let endDate = filter.endDate {
        sql += " AND m.date < ?"
        bindings.append(MessageStore.appleEpoch(endDate))
      }
      if !filter.participants.isEmpty {
        let placeholders = Array(repeating: "?", count: filter.participants.count).joined(
          separator: ",")
        // Match current in-memory behavior: Message.sender is either handle.id or destination_caller_id.
        sql +=
          " AND COALESCE(NULLIF(h.id,''), \(destinationCallerColumn)) COLLATE NOCASE IN (\(placeholders))"
        for participant in filter.participants {
          bindings.append(participant)
        }
      }
    }

    sql += " ORDER BY m.date DESC LIMIT ?"
    bindings.append(limit)
    let columns = MessageRowColumns(
      rowID: 0,
      chatID: nil,
      handleID: 1,
      sender: 2,
      text: 3,
      date: 4,
      isFromMe: 5,
      service: 6,
      chatStyle: 7,
      isAudioMessage: 8,
      destinationCallerID: 9,
      guid: 10,
      associatedGUID: 11,
      associatedType: 12,
      attachments: 13,
      body: 14,
      threadOriginatorGUID: 15
    )

    return try withConnection { db in
      var messages: [Message] = []
      for row in try db.prepare(sql, bindings) {
        let decoded = try decodeMessageRow(row, columns: columns, fallbackChatID: chatID)
        let replyToGUID = replyToGUID(
          associatedGuid: decoded.associatedGUID,
          associatedType: decoded.associatedType
        )
        messages.append(
          Message(
            rowID: decoded.rowID,
            chatID: decoded.chatID,
            sender: decoded.sender,
            text: decoded.text,
            date: decoded.date,
            isFromMe: decoded.isFromMe,
            service: decoded.service,
            isGroup: decoded.isGroup,
            handleID: decoded.handleID,
            attachmentsCount: decoded.attachments,
            guid: decoded.guid,
            routing: Message.RoutingMetadata(
              replyToGUID: replyToGUID,
              threadOriginatorGUID: decoded.threadOriginatorGUID.isEmpty
                ? nil : decoded.threadOriginatorGUID,
              destinationCallerID: decoded.destinationCallerID.isEmpty
                ? nil : decoded.destinationCallerID
            )
          ))
      }
      return messages
    }
  }

  public func messagesAfter(afterRowID: Int64, chatID: Int64?, limit: Int) throws -> [Message] {
    return try messagesAfter(
      afterRowID: afterRowID,
      chatID: chatID,
      limit: limit,
      includeReactions: false
    )
  }

  public func messagesAfter(
    afterRowID: Int64,
    chatID: Int64?,
    limit: Int,
    includeReactions: Bool
  ) throws -> [Message] {
    let bodyColumn = hasAttributedBody ? "m.attributedBody" : "NULL"
    let guidColumn = hasReactionColumns ? "m.guid" : "NULL"
    let associatedGuidColumn = hasReactionColumns ? "m.associated_message_guid" : "NULL"
    let associatedTypeColumn = hasReactionColumns ? "m.associated_message_type" : "NULL"
    let destinationCallerColumn = hasDestinationCallerID ? "m.destination_caller_id" : "NULL"
    let audioMessageColumn = hasAudioMessageColumn ? "m.is_audio_message" : "0"
    let chatStyleColumn = hasChatStyleColumn ? "c.style" : "NULL"
    let chatJoin = hasChatStyleColumn ? "LEFT JOIN chat c ON cmj.chat_id = c.ROWID" : ""
    let balloonBundleIDColumn = hasBalloonBundleIDColumn ? "m.balloon_bundle_id" : "NULL"
    let threadOriginatorColumn =
      hasThreadOriginatorGUIDColumn ? "m.thread_originator_guid" : "NULL"
    // Only filter out reactions if includeReactions is false
    let reactionFilter: String
    if includeReactions {
      reactionFilter = ""
    } else {
      if hasReactionColumns {
        reactionFilter =
          " AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000 OR m.associated_message_type > 3006)"
      } else {
        reactionFilter = ""
      }
    }
    var sql = """
      SELECT m.ROWID, cmj.chat_id, m.handle_id, h.id, IFNULL(m.text, '') AS text, m.date, m.is_from_me, m.service,
             \(chatStyleColumn) AS chat_style,
             \(audioMessageColumn) AS is_audio_message, \(destinationCallerColumn) AS destination_caller_id,
             \(guidColumn) AS guid, \(associatedGuidColumn) AS associated_guid, \(associatedTypeColumn) AS associated_type,
             (SELECT COUNT(*) FROM message_attachment_join maj WHERE maj.message_id = m.ROWID) AS attachments,
             \(bodyColumn) AS body,
             \(threadOriginatorColumn) AS thread_originator_guid,
             \(balloonBundleIDColumn) AS balloon_bundle_id
      FROM message m
      LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
      \(chatJoin)
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      WHERE m.ROWID > ?\(reactionFilter)
      """
    var bindings: [Binding?] = [afterRowID]
    if let chatID {
      sql += " AND cmj.chat_id = ?"
      bindings.append(chatID)
    }
    sql += " ORDER BY m.ROWID ASC LIMIT ?"
    bindings.append(limit)
    let columns = MessageRowColumns(
      rowID: 0,
      chatID: 1,
      handleID: 2,
      sender: 3,
      text: 4,
      date: 5,
      isFromMe: 6,
      service: 7,
      chatStyle: 8,
      isAudioMessage: 9,
      destinationCallerID: 10,
      guid: 11,
      associatedGUID: 12,
      associatedType: 13,
      attachments: 14,
      body: 15,
      threadOriginatorGUID: 16
    )

    let balloonBundleIDIndex = 17

    return try withConnection { db in
      var messages: [Message] = []
      let urlBalloonProvider = "com.apple.messages.URLBalloonProvider"

      for row in try db.prepare(sql, bindings) {
        let decoded = try decodeMessageRow(row, columns: columns, fallbackChatID: chatID)
        let balloonBundleID = stringValue(row[balloonBundleIDIndex])
        if balloonBundleID == urlBalloonProvider,
          shouldSkipURLBalloonDuplicate(
            chatID: decoded.chatID,
            sender: decoded.sender,
            text: decoded.text,
            isFromMe: decoded.isFromMe,
            date: decoded.date,
            rowID: decoded.rowID
          )
        {
          continue
        }

        let replyToGUID = replyToGUID(
          associatedGuid: decoded.associatedGUID,
          associatedType: decoded.associatedType
        )
        let reaction = decodeReaction(
          associatedType: decoded.associatedType,
          associatedGUID: decoded.associatedGUID,
          text: decoded.text
        )

        messages.append(
          Message(
            rowID: decoded.rowID,
            chatID: decoded.chatID,
            sender: decoded.sender,
            text: decoded.text,
            date: decoded.date,
            isFromMe: decoded.isFromMe,
            service: decoded.service,
            isGroup: decoded.isGroup,
            handleID: decoded.handleID,
            attachmentsCount: decoded.attachments,
            guid: decoded.guid,
            routing: Message.RoutingMetadata(
              replyToGUID: replyToGUID,
              threadOriginatorGUID: decoded.threadOriginatorGUID.isEmpty
                ? nil : decoded.threadOriginatorGUID,
              destinationCallerID: decoded.destinationCallerID.isEmpty
                ? nil : decoded.destinationCallerID
            ),
            reaction: Message.ReactionMetadata(
              isReaction: reaction.isReaction,
              reactionType: reaction.reactionType,
              isReactionAdd: reaction.isReactionAdd,
              reactedToGUID: reaction.reactedToGUID
            )
          ))
      }
      return messages
    }
  }

  private func decodeMessageRow(
    _ row: [Binding?],
    columns: MessageRowColumns,
    fallbackChatID: Int64?
  ) throws -> DecodedMessageRow {
    let rowID = int64Value(row[columns.rowID]) ?? 0
    let resolvedChatID = columns.chatID.flatMap { int64Value(row[$0]) } ?? fallbackChatID ?? 0
    let handleID = int64Value(row[columns.handleID])
    let sender = stringValue(row[columns.sender])
    let text = stringValue(row[columns.text])
    let date = appleDate(from: int64Value(row[columns.date]))
    let isFromMe = boolValue(row[columns.isFromMe])
    let service = stringValue(row[columns.service])
    let isGroup = intValue(row[columns.chatStyle]) == 43
    let isAudioMessage = boolValue(row[columns.isAudioMessage])
    let destinationCallerID = stringValue(row[columns.destinationCallerID])
    let guid = stringValue(row[columns.guid])
    let associatedGUID = stringValue(row[columns.associatedGUID])
    let associatedType = intValue(row[columns.associatedType])
    let attachments = intValue(row[columns.attachments]) ?? 0
    let body = dataValue(row[columns.body])
    let threadOriginatorGUID = stringValue(row[columns.threadOriginatorGUID])

    var resolvedText = text.isEmpty ? TypedStreamParser.parseAttributedBody(body) : text
    if isAudioMessage, let transcription = try audioTranscription(for: rowID) {
      resolvedText = transcription
    }

    var resolvedSender = sender
    if resolvedSender.isEmpty && !destinationCallerID.isEmpty {
      resolvedSender = destinationCallerID
    }

    return DecodedMessageRow(
      rowID: rowID,
      chatID: resolvedChatID,
      handleID: handleID,
      sender: resolvedSender,
      text: resolvedText,
      date: date,
      isFromMe: isFromMe,
      service: service,
      isGroup: isGroup,
      destinationCallerID: destinationCallerID,
      guid: guid,
      associatedGUID: associatedGUID,
      associatedType: associatedType,
      attachments: attachments,
      threadOriginatorGUID: threadOriginatorGUID
    )
  }
}
