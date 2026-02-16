import Foundation
import IMsgCore

struct ReactionEventMetadata {
  let isReaction: Bool?
  let reactionType: String?
  let reactionEmoji: String?
  let isReactionAdd: Bool?
  let reactedToGUID: String?

  init(message: Message) {
    if message.isReaction {
      isReaction = true
      reactionType = message.reactionType?.name
      reactionEmoji = message.reactionType?.emoji
      isReactionAdd = message.isReactionAdd
      reactedToGUID = message.reactedToGUID
    } else {
      isReaction = nil
      reactionType = nil
      reactionEmoji = nil
      isReactionAdd = nil
      reactedToGUID = nil
    }
  }

  func merge(into payload: inout [String: Any]) {
    guard isReaction == true else { return }
    payload["is_reaction"] = true
    if let reactionType {
      payload["reaction_type"] = reactionType
    }
    if let reactionEmoji {
      payload["reaction_emoji"] = reactionEmoji
    }
    if let isReactionAdd {
      payload["is_reaction_add"] = isReactionAdd
    }
    if let reactedToGUID, !reactedToGUID.isEmpty {
      payload["reacted_to_guid"] = reactedToGUID
    }
  }
}
