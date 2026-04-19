import Foundation
import SQLite

extension MessageStore {
  /// Look up a single message by its GUID. Returns nil if the GUID is empty,
  /// not found, or the underlying connection is unavailable.
  ///
  /// This is used by consumers that need to resolve `replyToGUID` to the
  /// referenced message without running a separate `sqlite3` process against
  /// the read-only chat.db. The query runs on the same pooled connection as
  /// other reads, honours the same permission-denied enhancement, and is
  /// bounded by LIMIT 1.
  public func messageByGUID(_ guid: String) throws -> Message? {
    let trimmed = guid.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let bodyColumn = hasAttributedBody ? "m.attributedBody" : "NULL"
    let guidColumn = hasReactionColumns ? "m.guid" : "NULL"
    let associatedGuidColumn = hasReactionColumns ? "m.associated_message_guid" : "NULL"
    let associatedTypeColumn = hasReactionColumns ? "m.associated_message_type" : "NULL"
    let destinationCallerColumn = hasDestinationCallerID ? "m.destination_caller_id" : "NULL"
    let audioMessageColumn = hasAudioMessageColumn ? "m.is_audio_message" : "0"
    let threadOriginatorColumn =
      hasThreadOriginatorGUIDColumn ? "m.thread_originator_guid" : "NULL"

    let sql = """
      SELECT m.ROWID, cmj.chat_id, m.handle_id, h.id, IFNULL(m.text, '') AS text, m.date, m.is_from_me, m.service,
             \(audioMessageColumn) AS is_audio_message, \(destinationCallerColumn) AS destination_caller_id,
             \(guidColumn) AS guid, \(associatedGuidColumn) AS associated_guid, \(associatedTypeColumn) AS associated_type,
             (SELECT COUNT(*) FROM message_attachment_join maj WHERE maj.message_id = m.ROWID) AS attachments,
             \(bodyColumn) AS body,
             \(threadOriginatorColumn) AS thread_originator_guid
      FROM message m
      LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      WHERE m.guid = ?
      LIMIT 1
      """

    let columns = MessageStoreGUIDColumns(
      rowID: 0,
      chatID: 1,
      handleID: 2,
      sender: 3,
      text: 4,
      date: 5,
      isFromMe: 6,
      service: 7,
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
      for row in try db.prepare(sql, [trimmed]) {
        return decodeGUIDRow(row, columns: columns)
      }
      return nil
    }
  }

  private func decodeGUIDRow(
    _ row: [Binding?],
    columns: MessageStoreGUIDColumns
  ) -> Message {
    let rowID = int64Value(row[columns.rowID]) ?? 0
    let chatID = int64Value(row[columns.chatID]) ?? 0
    let handleID = int64Value(row[columns.handleID])
    let sender = stringValue(row[columns.sender])
    let text = stringValue(row[columns.text])
    let date = appleDate(from: int64Value(row[columns.date]))
    let isFromMe = boolValue(row[columns.isFromMe])
    let service = stringValue(row[columns.service])
    let isAudioMessage = boolValue(row[columns.isAudioMessage])
    let destinationCallerID = stringValue(row[columns.destinationCallerID])
    let guid = stringValue(row[columns.guid])
    let associatedGUID = stringValue(row[columns.associatedGUID])
    let associatedType = intValue(row[columns.associatedType])
    let attachments = intValue(row[columns.attachments]) ?? 0
    let body = dataValue(row[columns.body])
    let threadOriginatorGUID = stringValue(row[columns.threadOriginatorGUID])

    var resolvedText = text.isEmpty ? TypedStreamParser.parseAttributedBody(body) : text
    if isAudioMessage, let transcription = try? audioTranscription(for: rowID) {
      resolvedText = transcription
    }

    var resolvedSender = sender
    if resolvedSender.isEmpty && !destinationCallerID.isEmpty {
      resolvedSender = destinationCallerID
    }

    let replyToGUID = replyToGUID(
      associatedGuid: associatedGUID,
      associatedType: associatedType
    )
    let reaction = decodeReaction(
      associatedType: associatedType,
      associatedGUID: associatedGUID,
      text: resolvedText
    )

    return Message(
      rowID: rowID,
      chatID: chatID,
      sender: resolvedSender,
      text: resolvedText,
      date: date,
      isFromMe: isFromMe,
      service: service,
      handleID: handleID,
      attachmentsCount: attachments,
      guid: guid,
      routing: Message.RoutingMetadata(
        replyToGUID: replyToGUID,
        threadOriginatorGUID: threadOriginatorGUID.isEmpty ? nil : threadOriginatorGUID,
        destinationCallerID: destinationCallerID.isEmpty ? nil : destinationCallerID
      ),
      reaction: Message.ReactionMetadata(
        isReaction: reaction.isReaction,
        reactionType: reaction.reactionType,
        isReactionAdd: reaction.isReactionAdd,
        reactedToGUID: reaction.reactedToGUID
      )
    )
  }
}

private struct MessageStoreGUIDColumns {
  let rowID: Int
  let chatID: Int
  let handleID: Int
  let sender: Int
  let text: Int
  let date: Int
  let isFromMe: Int
  let service: Int
  let isAudioMessage: Int
  let destinationCallerID: Int
  let guid: Int
  let associatedGUID: Int
  let associatedType: Int
  let attachments: Int
  let body: Int
  let threadOriginatorGUID: Int
}
