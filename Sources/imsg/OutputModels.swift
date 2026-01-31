import Foundation
import IMsgCore

struct ChatPayload: Codable {
  let id: Int64
  let name: String
  let identifier: String
  let service: String
  let lastMessageAt: String

  init(chat: Chat) {
    self.id = chat.id
    self.name = chat.name
    self.identifier = chat.identifier
    self.service = chat.service
    self.lastMessageAt = CLIISO8601.format(chat.lastMessageAt)
  }

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case identifier
    case service
    case lastMessageAt = "last_message_at"
  }
}

struct MessagePayload: Codable {
  let id: Int64
  let chatID: Int64
  let guid: String
  let replyToGUID: String?
  let sender: String
  let isFromMe: Bool
  let text: String
  let createdAt: String
  let attachments: [AttachmentPayload]
  let reactions: [ReactionPayload]
  
  // Reaction event metadata (populated when this message is a reaction event)
  let isReaction: Bool?
  let reactionType: String?
  let reactionEmoji: String?
  let isReactionAdd: Bool?
  let reactedToGUID: String?

  init(message: Message, attachments: [AttachmentMeta], reactions: [Reaction] = []) {
    self.id = message.rowID
    self.chatID = message.chatID
    self.guid = message.guid
    self.replyToGUID = message.replyToGUID
    self.sender = message.sender
    self.isFromMe = message.isFromMe
    self.text = message.text
    self.createdAt = CLIISO8601.format(message.date)
    self.attachments = attachments.map { AttachmentPayload(meta: $0) }
    self.reactions = reactions.map { ReactionPayload(reaction: $0) }
    
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
  }

  enum CodingKeys: String, CodingKey {
    case id
    case chatID = "chat_id"
    case guid
    case replyToGUID = "reply_to_guid"
    case sender
    case isFromMe = "is_from_me"
    case text
    case createdAt = "created_at"
    case attachments
    case reactions
    case isReaction = "is_reaction"
    case reactionType = "reaction_type"
    case reactionEmoji = "reaction_emoji"
    case isReactionAdd = "is_reaction_add"
    case reactedToGUID = "reacted_to_guid"
  }
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
