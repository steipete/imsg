import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func reactionEventMetadataMergeIncludesExpectedKeys() {
  let message = Message(
    rowID: 1,
    chatID: 1,
    sender: "+123",
    text: "Liked",
    date: Date(timeIntervalSince1970: 1),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 0,
    guid: "m1",
    isReaction: true,
    reactionType: .like,
    isReactionAdd: true,
    reactedToGUID: "target-guid",
  )
  var payload: [String: Any] = ["id": 1]
  ReactionEventMetadata(message: message).merge(into: &payload)
  #expect(payload["is_reaction"] as? Bool == true)
  #expect(payload["reaction_type"] as? String == "like")
  #expect(payload["reaction_emoji"] as? String == "👍")
  #expect(payload["is_reaction_add"] as? Bool == true)
  #expect(payload["reacted_to_guid"] as? String == "target-guid")
}

@Test
func reactionEventMetadataMergeNoopsForNonReaction() {
  let message = Message(
    rowID: 2,
    chatID: 1,
    sender: "+123",
    text: "hello",
    date: Date(timeIntervalSince1970: 1),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 0,
  )
  var payload: [String: Any] = ["id": 2]
  ReactionEventMetadata(message: message).merge(into: &payload)
  #expect(payload["is_reaction"] == nil)
  #expect(payload["reaction_type"] == nil)
  #expect(payload["reaction_emoji"] == nil)
  #expect(payload["is_reaction_add"] == nil)
  #expect(payload["reacted_to_guid"] == nil)
}
