import Foundation
import IMsgCore

struct ChatPayload: Codable {
  let id: Int64
  let name: String
  let identifier: String
  let service: String
  let lastMessageAt: String
  let guid: String?
  let displayName: String?
  let isGroup: Bool
  let participants: [String]?

  init(chat: Chat, participants: [String]? = nil) {
    self.id = chat.id
    self.name = chat.name
    self.identifier = chat.identifier
    self.service = chat.service
    self.lastMessageAt = CLIISO8601.format(chat.lastMessageAt)
    self.guid = chat.guid
    self.displayName = chat.displayName
    self.isGroup = isGroupHandle(identifier: chat.identifier, guid: chat.guid ?? "")
    self.participants = participants
  }

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case identifier
    case service
    case lastMessageAt = "last_message_at"
    case guid
    case displayName = "display_name"
    case isGroup = "is_group"
    case participants
  }
}

struct MessagePayload: Codable {
  let id: Int64
  let chatID: Int64
  let guid: String
  let replyToGUID: String?
  let threadOriginatorGUID: String?
  let sender: String
  let isFromMe: Bool
  let text: String
  let createdAt: String
  let attachments: [AttachmentPayload]
  let reactions: [ReactionPayload]
  /// The destination_caller_id from the database. For messages where is_from_me is true,
  /// this can help distinguish between messages actually sent by the local user vs
  /// messages received on a secondary phone number registered with the same Apple ID.
  let destinationCallerID: String?

  // Reaction event metadata (populated when this message is a reaction event)
  let isReaction: Bool?
  let reactionType: String?
  let reactionEmoji: String?
  let isReactionAdd: Bool?
  let reactedToGUID: String?

  // Chat / group metadata (populated when callers supply chat context)
  let chatIdentifier: String?
  let chatGuid: String?
  let chatName: String?
  let participants: [String]?
  let isGroup: Bool?

  init(
    message: Message,
    attachments: [AttachmentMeta],
    reactions: [Reaction] = [],
    chatInfo: ChatInfo? = nil,
    participants: [String]? = nil
  ) {
    self.id = message.rowID
    self.chatID = message.chatID
    self.guid = message.guid
    self.replyToGUID = message.replyToGUID
    self.threadOriginatorGUID = message.threadOriginatorGUID
    self.sender = message.sender
    self.isFromMe = message.isFromMe
    self.text = message.text
    self.createdAt = CLIISO8601.format(message.date)
    self.attachments = attachments.map { AttachmentPayload(meta: $0) }
    self.reactions = reactions.map { ReactionPayload(reaction: $0) }
    self.destinationCallerID = message.destinationCallerID

    // Reaction event metadata
    if message.isReaction {
      self.isReaction = true
      self.reactionType = message.reactionType?.name
      self.reactionEmoji = message.reactionType?.emoji
      self.isReactionAdd = message.isReactionAdd
      self.reactedToGUID = message.reactedToGUID
    } else {
      self.isReaction = nil
      self.reactionType = nil
      self.reactionEmoji = nil
      self.isReactionAdd = nil
      self.reactedToGUID = nil
    }

    // Chat / group metadata. When chatInfo is omitted, all fields stay nil
    // which preserves the existing JSON shape for callers that don't populate it
    // (notably the RPC `messagePayload` dictionary builder, which overlays its
    // own `chat_identifier`, `chat_guid`, `chat_name`, `participants`, `is_group`
    // keys on top of asDictionary()).
    self.chatIdentifier = chatInfo?.identifier
    self.chatGuid = chatInfo?.guid
    self.chatName = chatInfo?.name
    self.participants = participants
    if let chatInfo {
      self.isGroup = isGroupHandle(identifier: chatInfo.identifier, guid: chatInfo.guid)
    } else {
      self.isGroup = nil
    }
  }

  enum CodingKeys: String, CodingKey {
    case id
    case chatID = "chat_id"
    case guid
    case replyToGUID = "reply_to_guid"
    case threadOriginatorGUID = "thread_originator_guid"
    case sender
    case isFromMe = "is_from_me"
    case text
    case createdAt = "created_at"
    case attachments
    case reactions
    case destinationCallerID = "destination_caller_id"
    case isReaction = "is_reaction"
    case reactionType = "reaction_type"
    case reactionEmoji = "reaction_emoji"
    case isReactionAdd = "is_reaction_add"
    case reactedToGUID = "reacted_to_guid"
    case chatIdentifier = "chat_identifier"
    case chatGuid = "chat_guid"
    case chatName = "chat_name"
    case participants
    case isGroup = "is_group"
  }
}

extension MessagePayload {
  func asDictionary() throws -> [String: Any] {
    let data = try MessagePayload.encoder.encode(self)
    let json = try JSONSerialization.jsonObject(with: data)
    return (json as? [String: Any]) ?? [:]
  }

  private static let encoder: JSONEncoder = {
    JSONEncoder()
  }()
}

struct ReactionPayload: Codable {
  let id: Int64
  let type: String
  let emoji: String
  let sender: String
  let isFromMe: Bool
  let createdAt: String

  init(reaction: Reaction) {
    self.id = reaction.rowID
    self.type = reaction.reactionType.name
    self.emoji = reaction.reactionType.emoji
    self.sender = reaction.sender
    self.isFromMe = reaction.isFromMe
    self.createdAt = CLIISO8601.format(reaction.date)
  }

  enum CodingKeys: String, CodingKey {
    case id
    case type
    case emoji
    case sender
    case isFromMe = "is_from_me"
    case createdAt = "created_at"
  }
}

struct GroupPayload: Codable {
  let id: Int64
  let identifier: String
  let guid: String
  let name: String
  let service: String
  let isGroup: Bool
  let participants: [String]

  init(chatInfo: ChatInfo, participants: [String]) {
    self.id = chatInfo.id
    self.identifier = chatInfo.identifier
    self.guid = chatInfo.guid
    self.name = chatInfo.name
    self.service = chatInfo.service
    self.isGroup = isGroupHandle(identifier: chatInfo.identifier, guid: chatInfo.guid)
    self.participants = participants
  }

  enum CodingKeys: String, CodingKey {
    case id
    case identifier
    case guid
    case name
    case service
    case isGroup = "is_group"
    case participants
  }
}

struct AttachmentPayload: Codable {
  let filename: String
  let transferName: String
  let uti: String
  let mimeType: String
  let totalBytes: Int64
  let isSticker: Bool
  let originalPath: String
  let missing: Bool

  init(meta: AttachmentMeta) {
    self.filename = meta.filename
    self.transferName = meta.transferName
    self.uti = meta.uti
    self.mimeType = meta.mimeType
    self.totalBytes = meta.totalBytes
    self.isSticker = meta.isSticker
    self.originalPath = meta.originalPath
    self.missing = meta.missing
  }

  enum CodingKeys: String, CodingKey {
    case filename = "filename"
    case transferName = "transfer_name"
    case uti = "uti"
    case mimeType = "mime_type"
    case totalBytes = "total_bytes"
    case isSticker = "is_sticker"
    case originalPath = "original_path"
    case missing = "missing"
  }
}

enum CLIISO8601 {
  static func format(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}
