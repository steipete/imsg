import Foundation
import SQLite

struct MessageRowColumns {
  static let balloonBundleID = "balloon_bundle_id"

  let rowID: String
  let chatID: String?
  let handleID: String
  let sender: String
  let text: String
  let date: String
  let isFromMe: String
  let service: String
  let isAudioMessage: String
  let destinationCallerID: String
  let guid: String
  let associatedGUID: String
  let associatedType: String
  let attachments: String
  let body: String
  let threadOriginatorGUID: String

  static func message(chatID: String?) -> MessageRowColumns {
    MessageRowColumns(
      rowID: "message_rowid",
      chatID: chatID,
      handleID: "handle_id",
      sender: "sender",
      text: "text",
      date: "date",
      isFromMe: "is_from_me",
      service: "service",
      isAudioMessage: "is_audio_message",
      destinationCallerID: "destination_caller_id",
      guid: "guid",
      associatedGUID: "associated_guid",
      associatedType: "associated_type",
      attachments: "attachments",
      body: "body",
      threadOriginatorGUID: "thread_originator_guid"
    )
  }
}

struct DecodedMessageRow {
  let rowID: Int64
  let chatID: Int64
  let handleID: Int64?
  let sender: String
  let text: String
  let date: Date
  let isFromMe: Bool
  let service: String
  let destinationCallerID: String
  let guid: String
  let associatedGUID: String
  let associatedType: Int?
  let attachments: Int
  let threadOriginatorGUID: String
}

struct MessageRowSelection {
  let selectList: String
  let columns: MessageRowColumns

  init(store: MessageStore, includeChatID: Bool, includeBalloonBundleID: Bool = false) {
    let columns = MessageRowColumns.message(chatID: includeChatID ? "chat_id" : nil)
    let schema = store.schema
    let bodyColumn = schema.hasAttributedBody ? "m.attributedBody" : "NULL"
    let guidColumn = schema.hasReactionColumns ? "m.guid" : "NULL"
    let associatedGuidColumn = schema.hasReactionColumns ? "m.associated_message_guid" : "NULL"
    let associatedTypeColumn = schema.hasReactionColumns ? "m.associated_message_type" : "NULL"
    let destinationCallerColumn =
      schema.hasDestinationCallerID ? "m.destination_caller_id" : "NULL"
    let audioMessageColumn = schema.hasAudioMessageColumn ? "m.is_audio_message" : "0"
    let threadOriginatorColumn =
      schema.hasThreadOriginatorGUIDColumn ? "m.thread_originator_guid" : "NULL"
    let chatColumn = includeChatID ? ", cmj.chat_id AS \(columns.chatID!)" : ""

    var selectList = """
      m.ROWID AS \(columns.rowID)\(chatColumn), m.handle_id AS \(columns.handleID),
             h.id AS \(columns.sender), IFNULL(m.text, '') AS \(columns.text),
             m.date AS \(columns.date), m.is_from_me AS \(columns.isFromMe),
             m.service AS \(columns.service),
             \(audioMessageColumn) AS \(columns.isAudioMessage),
             \(destinationCallerColumn) AS \(columns.destinationCallerID),
             \(guidColumn) AS \(columns.guid), \(associatedGuidColumn) AS \(columns.associatedGUID),
             \(associatedTypeColumn) AS \(columns.associatedType),
             (SELECT COUNT(*) FROM message_attachment_join maj WHERE maj.message_id = m.ROWID) AS \(columns.attachments),
             \(bodyColumn) AS \(columns.body),
             \(threadOriginatorColumn) AS \(columns.threadOriginatorGUID)
      """
    if includeBalloonBundleID {
      let balloonColumn = schema.hasBalloonBundleIDColumn ? "m.balloon_bundle_id" : "NULL"
      selectList += ",\n             \(balloonColumn) AS \(MessageRowColumns.balloonBundleID)"
    }

    self.selectList = selectList
    self.columns = columns
  }
}

private struct ChatMessagesQuery {
  let sql: String
  let bindings: [Binding?]
  let selection: MessageRowSelection
  let fallbackChatID: Int64

  init(store: MessageStore, chatID: ChatID, limit: Int, filter: MessageFilter?) {
    self.selection = MessageRowSelection(store: store, includeChatID: false)
    let destinationCallerColumn =
      store.schema.hasDestinationCallerID ? "m.destination_caller_id" : "NULL"
    let reactionFilter =
      store.schema.hasReactionColumns
      ? " AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000 OR m.associated_message_type > 3006)"
      : ""
    var sql = """
      SELECT \(selection.selectList)
      FROM message m
      JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      WHERE cmj.chat_id = ?\(reactionFilter)
      """
    var bindings: [Binding?] = [chatID.rawValue]

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
        sql +=
          " AND COALESCE(NULLIF(h.id,''), \(destinationCallerColumn)) COLLATE NOCASE IN (\(placeholders))"
        for participant in filter.participants {
          bindings.append(participant)
        }
      }
    }

    sql += " ORDER BY m.date DESC LIMIT ?"
    bindings.append(limit)

    self.sql = sql
    self.bindings = bindings
    self.fallbackChatID = chatID.rawValue
  }
}

private struct MessagesAfterQuery {
  let sql: String
  let bindings: [Binding?]
  let selection: MessageRowSelection
  let fallbackChatID: Int64?

  init(
    store: MessageStore,
    afterRowID: MessageID,
    chatID: ChatID?,
    limit: Int,
    includeReactions: Bool
  ) {
    self.selection = MessageRowSelection(
      store: store,
      includeChatID: true,
      includeBalloonBundleID: true
    )
    let reactionFilter: String
    if includeReactions || !store.schema.hasReactionColumns {
      reactionFilter = ""
    } else {
      reactionFilter =
        " AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000 OR m.associated_message_type > 3006)"
    }
    var sql = """
      SELECT \(selection.selectList)
      FROM message m
      LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      WHERE m.ROWID > ?\(reactionFilter)
      """
    var bindings: [Binding?] = [afterRowID.rawValue]
    if let chatID {
      sql += " AND cmj.chat_id = ?"
      bindings.append(chatID.rawValue)
    }
    sql += " ORDER BY m.ROWID ASC LIMIT ?"
    bindings.append(limit)

    self.sql = sql
    self.bindings = bindings
    self.fallbackChatID = chatID?.rawValue
  }
}

private struct LatestSentMessageQuery {
  let sql: String
  let bindings: [Binding?]
  let selection: MessageRowSelection
  let fallbackChatID: Int64?

  init(store: MessageStore, text: String, chatID: ChatID?, since date: Date) {
    self.selection = MessageRowSelection(store: store, includeChatID: true)
    var sql = """
      SELECT \(selection.selectList)
      FROM message m
      LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      WHERE m.is_from_me = 1
        AND IFNULL(m.text, '') = ?
        AND m.date >= ?
      """
    var bindings: [Binding?] = [text, MessageStore.appleEpoch(date)]
    if let chatID {
      sql += " AND cmj.chat_id = ?"
      bindings.append(chatID.rawValue)
    }
    sql += " ORDER BY m.date DESC, m.ROWID DESC LIMIT 1"

    self.sql = sql
    self.bindings = bindings
    self.fallbackChatID = chatID?.rawValue
  }
}

extension MessageStore {
  public func maxRowID() throws -> Int64 {
    return try withConnection { db in
      let value = try db.scalar("SELECT MAX(ROWID) FROM message")
      return int64Value(value) ?? 0
    }
  }

  public func messages(chatID: Int64, limit: Int) throws -> [Message] {
    return try messages(chatID: chatID, limit: limit, filter: nil)
  }

  public func messages(chatID: Int64, limit: Int, filter: MessageFilter?) throws -> [Message] {
    let query = ChatMessagesQuery(
      store: self,
      chatID: ChatID(rawValue: chatID),
      limit: limit,
      filter: filter
    )

    return try withConnection { db in
      var messages: [Message] = []
      let rows = try db.prepareRowIterator(query.sql, bindings: query.bindings)
      while let row = try rows.failableNext() {
        let decoded = try decodeMessageRow(
          row,
          columns: query.selection.columns,
          fallbackChatID: query.fallbackChatID
        )
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
    let query = MessagesAfterQuery(
      store: self,
      afterRowID: MessageID(rawValue: afterRowID),
      chatID: chatID.map { ChatID(rawValue: $0) },
      limit: limit,
      includeReactions: includeReactions
    )

    return try withConnection { db in
      var messages: [Message] = []
      let urlBalloonProvider = "com.apple.messages.URLBalloonProvider"

      let rows = try db.prepareRowIterator(query.sql, bindings: query.bindings)
      while let row = try rows.failableNext() {
        let decoded = try decodeMessageRow(
          row,
          columns: query.selection.columns,
          fallbackChatID: query.fallbackChatID
        )
        let balloonBundleID = try stringValue(row, MessageRowColumns.balloonBundleID)
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

  public func latestSentMessage(matchingText text: String, chatID: Int64?, since date: Date)
    throws -> Message?
  {
    guard !text.isEmpty else { return nil }

    let query = LatestSentMessageQuery(
      store: self,
      text: text,
      chatID: chatID.map { ChatID(rawValue: $0) },
      since: date
    )

    return try withConnection { db in
      let rows = try db.prepareRowIterator(query.sql, bindings: query.bindings)
      guard let row = try rows.failableNext() else { return nil }
      let decoded = try decodeMessageRow(
        row,
        columns: query.selection.columns,
        fallbackChatID: query.fallbackChatID
      )
      let replyToGUID = replyToGUID(
        associatedGuid: decoded.associatedGUID,
        associatedType: decoded.associatedType
      )
      return Message(
        rowID: decoded.rowID,
        chatID: decoded.chatID,
        sender: decoded.sender,
        text: decoded.text,
        date: decoded.date,
        isFromMe: decoded.isFromMe,
        service: decoded.service,
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
      )
    }
  }

  func decodeMessageRow(
    _ row: Row,
    columns: MessageRowColumns,
    fallbackChatID: Int64?
  ) throws -> DecodedMessageRow {
    let rowID = try int64Value(row, columns.rowID) ?? 0
    let resolvedChatID =
      try columns.chatID.flatMap { try int64Value(row, $0) } ?? fallbackChatID ?? 0
    let handleID = try int64Value(row, columns.handleID)
    let sender = try stringValue(row, columns.sender)
    let text = try stringValue(row, columns.text)
    let date = try appleDate(from: int64Value(row, columns.date))
    let isFromMe = try boolValue(row, columns.isFromMe)
    let service = try stringValue(row, columns.service)
    let isAudioMessage = try boolValue(row, columns.isAudioMessage)
    let destinationCallerID = try stringValue(row, columns.destinationCallerID)
    let guid = try stringValue(row, columns.guid)
    let associatedGUID = try stringValue(row, columns.associatedGUID)
    let associatedType = try intValue(row, columns.associatedType)
    let attachments = try intValue(row, columns.attachments) ?? 0
    let body = try dataValue(row, columns.body)
    let threadOriginatorGUID = try stringValue(row, columns.threadOriginatorGUID)

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
      destinationCallerID: destinationCallerID,
      guid: guid,
      associatedGUID: associatedGUID,
      associatedType: associatedType,
      attachments: attachments,
      threadOriginatorGUID: threadOriginatorGUID
    )
  }
}
