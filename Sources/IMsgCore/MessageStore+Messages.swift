import Foundation
import SQLite

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
    let threadOriginatorColumn =
      hasThreadOriginatorGUIDColumn ? "m.thread_originator_guid" : "NULL"
    let reactionFilter =
      hasReactionColumns
      ? " AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000 OR m.associated_message_type > 3006)"
      : ""
    var sql = """
      SELECT m.ROWID, m.handle_id, h.id, IFNULL(m.text, '') AS text, m.date, m.is_from_me, m.service,
             \(audioMessageColumn) AS is_audio_message, \(destinationCallerColumn) AS destination_caller_id,
             \(guidColumn) AS guid, \(associatedGuidColumn) AS associated_guid, \(associatedTypeColumn) AS associated_type,
             (SELECT COUNT(*) FROM message_attachment_join maj WHERE maj.message_id = m.ROWID) AS attachments,
             \(bodyColumn) AS body,
             \(threadOriginatorColumn) AS thread_originator_guid
      FROM message m
      JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
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

    return try withConnection { db in
      var messages: [Message] = []
      for row in try db.prepare(sql, bindings) {
        let colRowID = 0
        let colHandleID = 1
        let colSender = 2
        let colText = 3
        let colDate = 4
        let colIsFromMe = 5
        let colService = 6
        let colIsAudioMessage = 7
        let colDestinationCallerID = 8
        let colGUID = 9
        let colAssociatedGUID = 10
        let colAssociatedType = 11
        let colAttachments = 12
        let colBody = 13
        let colThreadOriginatorGUID = 14

        let rowID = int64Value(row[colRowID]) ?? 0
        let handleID = int64Value(row[colHandleID])
        var sender = stringValue(row[colSender])
        let text = stringValue(row[colText])
        let date = appleDate(from: int64Value(row[colDate]))
        let isFromMe = boolValue(row[colIsFromMe])
        let service = stringValue(row[colService])
        let isAudioMessage = boolValue(row[colIsAudioMessage])
        let destinationCallerID = stringValue(row[colDestinationCallerID])
        if sender.isEmpty && !destinationCallerID.isEmpty {
          sender = destinationCallerID
        }
        let guid = stringValue(row[colGUID])
        let associatedGuid = stringValue(row[colAssociatedGUID])
        let associatedType = intValue(row[colAssociatedType])
        let attachments = intValue(row[colAttachments]) ?? 0
        let body = dataValue(row[colBody])
        let threadOriginatorGUID = stringValue(row[colThreadOriginatorGUID])
        var resolvedText = text.isEmpty ? TypedStreamParser.parseAttributedBody(body) : text
        if isAudioMessage, let transcription = try audioTranscription(for: rowID) {
          resolvedText = transcription
        }
        let replyToGUID = replyToGUID(
          associatedGuid: associatedGuid,
          associatedType: associatedType
        )
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
            attachmentsCount: attachments,
            guid: guid,
            replyToGUID: replyToGUID,
            threadOriginatorGUID: threadOriginatorGUID.isEmpty ? nil : threadOriginatorGUID
          ))
      }
      return messages
    }
  }

  public func messagesAfter(afterRowID: Int64, chatID: Int64?, limit: Int) throws -> [Message] {
    let bodyColumn = hasAttributedBody ? "m.attributedBody" : "NULL"
    let guidColumn = hasReactionColumns ? "m.guid" : "NULL"
    let associatedGuidColumn = hasReactionColumns ? "m.associated_message_guid" : "NULL"
    let associatedTypeColumn = hasReactionColumns ? "m.associated_message_type" : "NULL"
    let destinationCallerColumn = hasDestinationCallerID ? "m.destination_caller_id" : "NULL"
    let audioMessageColumn = hasAudioMessageColumn ? "m.is_audio_message" : "0"
    let threadOriginatorColumn =
      hasThreadOriginatorGUIDColumn ? "m.thread_originator_guid" : "NULL"
    let reactionFilter =
      hasReactionColumns
      ? " AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000 OR m.associated_message_type > 3006)"
      : ""
    var sql = """
      SELECT m.ROWID, cmj.chat_id, m.handle_id, h.id, IFNULL(m.text, '') AS text, m.date, m.is_from_me, m.service,
             \(audioMessageColumn) AS is_audio_message, \(destinationCallerColumn) AS destination_caller_id,
             \(guidColumn) AS guid, \(associatedGuidColumn) AS associated_guid, \(associatedTypeColumn) AS associated_type,
             (SELECT COUNT(*) FROM message_attachment_join maj WHERE maj.message_id = m.ROWID) AS attachments,
             \(bodyColumn) AS body,
             \(threadOriginatorColumn) AS thread_originator_guid
      FROM message m
      LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
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

    return try withConnection { db in
      var messages: [Message] = []
      for row in try db.prepare(sql, bindings) {
        let colRowID = 0
        let colChatID = 1
        let colHandleID = 2
        let colSender = 3
        let colText = 4
        let colDate = 5
        let colIsFromMe = 6
        let colService = 7
        let colIsAudioMessage = 8
        let colDestinationCallerID = 9
        let colGUID = 10
        let colAssociatedGUID = 11
        let colAssociatedType = 12
        let colAttachments = 13
        let colBody = 14
        let colThreadOriginatorGUID = 15

        let rowID = int64Value(row[colRowID]) ?? 0
        let resolvedChatID = int64Value(row[colChatID]) ?? chatID ?? 0
        let handleID = int64Value(row[colHandleID])
        var sender = stringValue(row[colSender])
        let text = stringValue(row[colText])
        let date = appleDate(from: int64Value(row[colDate]))
        let isFromMe = boolValue(row[colIsFromMe])
        let service = stringValue(row[colService])
        let isAudioMessage = boolValue(row[colIsAudioMessage])
        let destinationCallerID = stringValue(row[colDestinationCallerID])
        if sender.isEmpty && !destinationCallerID.isEmpty {
          sender = destinationCallerID
        }
        let guid = stringValue(row[colGUID])
        let associatedGuid = stringValue(row[colAssociatedGUID])
        let associatedType = intValue(row[colAssociatedType])
        let attachments = intValue(row[colAttachments]) ?? 0
        let body = dataValue(row[colBody])
        let threadOriginatorGUID = stringValue(row[colThreadOriginatorGUID])
        var resolvedText = text.isEmpty ? TypedStreamParser.parseAttributedBody(body) : text
        if isAudioMessage, let transcription = try audioTranscription(for: rowID) {
          resolvedText = transcription
        }
        let replyToGUID = replyToGUID(
          associatedGuid: associatedGuid,
          associatedType: associatedType
        )
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
            attachmentsCount: attachments,
            guid: guid,
            replyToGUID: replyToGUID,
            threadOriginatorGUID: threadOriginatorGUID.isEmpty ? nil : threadOriginatorGUID
          ))
      }
      return messages
    }
  }
}
