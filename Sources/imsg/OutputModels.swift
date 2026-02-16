import Foundation
import IMsgCore

struct ChatPayload: Codable {
  let id: Int64
  let name: String
  let identifier: String
  let service: String
  let lastMessageAt: String

  init(chat: Chat) {
    id = chat.id
    name = chat.name
    identifier = chat.identifier
    service = chat.service
    lastMessageAt = CLIISO8601.format(chat.lastMessageAt)
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
  let threadOriginatorGUID: String?
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
    id = message.rowID
    chatID = message.chatID
    guid = message.guid
    replyToGUID = message.replyToGUID
    threadOriginatorGUID = message.threadOriginatorGUID
    sender = message.sender
    isFromMe = message.isFromMe
    text = message.text
    createdAt = CLIISO8601.format(message.date)
    self.attachments = attachments.map { AttachmentPayload(meta: $0) }
    self.reactions = reactions.map { ReactionPayload(reaction: $0) }

    let reactionMetadata = ReactionEventMetadata(message: message)
    isReaction = reactionMetadata.isReaction
    reactionType = reactionMetadata.reactionType
    reactionEmoji = reactionMetadata.reactionEmoji
    isReactionAdd = reactionMetadata.isReactionAdd
    reactedToGUID = reactionMetadata.reactedToGUID
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
    id = reaction.rowID
    type = reaction.reactionType.name
    emoji = reaction.reactionType.emoji
    sender = reaction.sender
    isFromMe = reaction.isFromMe
    createdAt = CLIISO8601.format(reaction.date)
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
    filename = meta.filename
    transferName = meta.transferName
    uti = meta.uti
    mimeType = meta.mimeType
    totalBytes = meta.totalBytes
    isSticker = meta.isSticker
    originalPath = meta.originalPath
    missing = meta.missing
  }

  enum CodingKeys: String, CodingKey {
    case filename
    case transferName = "transfer_name"
    case uti
    case mimeType = "mime_type"
    case totalBytes = "total_bytes"
    case isSticker = "is_sticker"
    case originalPath = "original_path"
    case missing
  }
}

enum CLIISO8601 {
  static func format(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}
