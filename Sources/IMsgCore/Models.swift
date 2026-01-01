import Foundation

/// The type of reaction on an iMessage.
/// Values correspond to the `associated_message_type` column in the Messages database.
/// Standard tapbacks are 2000-2005, custom emoji reactions are 2006.
public enum ReactionType: Sendable, Equatable, Hashable {
  case love
  case like
  case dislike
  case laugh
  case emphasis
  case question
  case custom(String)

  /// Initialize from the database associated_message_type value
  /// For custom emojis (2006), pass the emoji string extracted from the message text
  public init?(rawValue: Int, customEmoji: String? = nil) {
    switch rawValue {
    case 2000: self = .love
    case 2001: self = .like
    case 2002: self = .dislike
    case 2003: self = .laugh
    case 2004: self = .emphasis
    case 2005: self = .question
    case 2006:
      guard let emoji = customEmoji else { return nil }
      self = .custom(emoji)
    default: return nil
    }
  }

  /// Returns the reaction type for a removal (values 3000-3006)
  public static func fromRemoval(_ value: Int, customEmoji: String? = nil) -> ReactionType? {
    return ReactionType(rawValue: value - 1000, customEmoji: customEmoji)
  }

  /// Whether this associated_message_type represents adding a reaction (2000-2006)
  public static func isReactionAdd(_ value: Int) -> Bool {
    return value >= 2000 && value <= 2006
  }

  /// Whether this associated_message_type represents removing a reaction (3000-3006)
  public static func isReactionRemove(_ value: Int) -> Bool {
    return value >= 3000 && value <= 3006
  }

  /// Human-readable name for the reaction
  public var name: String {
    switch self {
    case .love: return "love"
    case .like: return "like"
    case .dislike: return "dislike"
    case .laugh: return "laugh"
    case .emphasis: return "emphasis"
    case .question: return "question"
    case .custom: return "custom"
    }
  }

  /// Emoji representation of the reaction
  public var emoji: String {
    switch self {
    case .love: return "❤️"
    case .like: return "👍"
    case .dislike: return "👎"
    case .laugh: return "😂"
    case .emphasis: return "‼️"
    case .question: return "❓"
    case .custom(let emoji): return emoji
    }
  }

  public var isCustom: Bool {
    if case .custom = self {
      return true
    }
    return false
  }
}

/// A reaction to an iMessage.
public struct Reaction: Sendable, Equatable {
  /// The ROWID of the reaction message in the database
  public let rowID: Int64
  /// The type of reaction
  public let reactionType: ReactionType
  /// The sender of the reaction (phone number or email)
  public let sender: String
  /// Whether the reaction was sent by the current user
  public let isFromMe: Bool
  /// When the reaction was added
  public let date: Date
  /// The ROWID of the message being reacted to
  public let associatedMessageID: Int64

  public init(
    rowID: Int64,
    reactionType: ReactionType,
    sender: String,
    isFromMe: Bool,
    date: Date,
    associatedMessageID: Int64
  ) {
    self.rowID = rowID
    self.reactionType = reactionType
    self.sender = sender
    self.isFromMe = isFromMe
    self.date = date
    self.associatedMessageID = associatedMessageID
  }
}

public struct Chat: Sendable, Equatable {
  public let id: Int64
  public let identifier: String
  public let name: String
  public let service: String
  public let lastMessageAt: Date

  public init(id: Int64, identifier: String, name: String, service: String, lastMessageAt: Date) {
    self.id = id
    self.identifier = identifier
    self.name = name
    self.service = service
    self.lastMessageAt = lastMessageAt
  }
}

public struct Message: Sendable, Equatable {
  public let rowID: Int64
  public let chatID: Int64
  public let sender: String
  public let text: String
  public let date: Date
  public let isFromMe: Bool
  public let service: String
  public let handleID: Int64?
  public let attachmentsCount: Int

  public init(
    rowID: Int64,
    chatID: Int64,
    sender: String,
    text: String,
    date: Date,
    isFromMe: Bool,
    service: String,
    handleID: Int64?,
    attachmentsCount: Int
  ) {
    self.rowID = rowID
    self.chatID = chatID
    self.sender = sender
    self.text = text
    self.date = date
    self.isFromMe = isFromMe
    self.service = service
    self.handleID = handleID
    self.attachmentsCount = attachmentsCount
  }
}

public struct AttachmentMeta: Sendable, Equatable {
  public let filename: String
  public let transferName: String
  public let uti: String
  public let mimeType: String
  public let totalBytes: Int64
  public let isSticker: Bool
  public let originalPath: String
  public let missing: Bool

  public init(
    filename: String,
    transferName: String,
    uti: String,
    mimeType: String,
    totalBytes: Int64,
    isSticker: Bool,
    originalPath: String,
    missing: Bool
  ) {
    self.filename = filename
    self.transferName = transferName
    self.uti = uti
    self.mimeType = mimeType
    self.totalBytes = totalBytes
    self.isSticker = isSticker
    self.originalPath = originalPath
    self.missing = missing
  }
}
