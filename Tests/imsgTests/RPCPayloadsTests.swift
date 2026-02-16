import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func isGroupHandleFlagsGroup() {
  #expect(isGroupHandle(identifier: "iMessage;+;chat123", guid: "") == true)
  #expect(isGroupHandle(identifier: "", guid: "iMessage;-;chat999") == false)
  #expect(isGroupHandle(identifier: "+1555", guid: "") == false)
}

@Test
func chatPayloadIncludesParticipantsAndGroupFlag() {
  let date = Date(timeIntervalSince1970: 0)
  let payload = chatPayload(
    id: 1,
    identifier: "iMessage;+;chat123",
    guid: "iMessage;+;chat123",
    name: "Group",
    service: "iMessage",
    lastMessageAt: date,
    participants: ["+111", "+222"]
  )
  #expect(payload["id"] as? Int64 == 1)
  #expect(payload["identifier"] as? String == "iMessage;+;chat123")
  #expect(payload["is_group"] as? Bool == true)
  #expect((payload["participants"] as? [String])?.count == 2)
}

@Test
func messagePayloadIncludesChatFields() {
  let message = Message(
    rowID: 5,
    chatID: 10,
    sender: "+123",
    text: "hello",
    date: Date(timeIntervalSince1970: 1),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 1,
    guid: "msg-guid-5",
    replyToGUID: "msg-guid-1",
    threadOriginatorGUID: "thread-guid-5"
  )
  let chatInfo = ChatInfo(
    id: 10,
    identifier: "iMessage;+;chat123",
    guid: "iMessage;+;chat123",
    name: "Group",
    service: "iMessage"
  )
  let attachment = AttachmentMeta(
    filename: "file.dat",
    transferName: "file.dat",
    uti: "public.data",
    mimeType: "application/octet-stream",
    totalBytes: 12,
    isSticker: false,
    originalPath: "/tmp/file.dat",
    missing: false
  )
  let reaction = Reaction(
    rowID: 99,
    reactionType: .like,
    sender: "+123",
    isFromMe: false,
    date: Date(timeIntervalSince1970: 2),
    associatedMessageID: 5
  )
  let payload = messagePayload(
    message: message,
    chatInfo: chatInfo,
    participants: ["+111"],
    attachments: [attachment],
    reactions: [reaction]
  )
  #expect(payload["chat_id"] as? Int64 == 10)
  #expect(payload["guid"] as? String == "msg-guid-5")
  #expect(payload["reply_to_guid"] as? String == "msg-guid-1")
  #expect(payload["thread_originator_guid"] as? String == "thread-guid-5")
  #expect(payload["chat_identifier"] as? String == "iMessage;+;chat123")
  #expect(payload["chat_name"] as? String == "Group")
  #expect(payload["is_group"] as? Bool == true)
  #expect((payload["attachments"] as? [[String: Any]])?.count == 1)
  #expect(
    (payload["reactions"] as? [[String: Any]])?.first?["emoji"] as? String
      == ReactionType.like.emoji)
}

@Test
func messagePayloadOmitsEmptyReplyToGuid() {
  let message = Message(
    rowID: 6,
    chatID: 10,
    sender: "+123",
    text: "hello",
    date: Date(timeIntervalSince1970: 1),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 0,
    guid: "msg-guid-6",
    replyToGUID: nil
  )
  let payload = messagePayload(
    message: message,
    chatInfo: nil,
    participants: [],
    attachments: [],
    reactions: []
  )
  #expect(payload["reply_to_guid"] == nil)
  #expect(payload["thread_originator_guid"] == nil)
  #expect(payload["guid"] as? String == "msg-guid-6")
}

@Test
func paramParsingHelpers() {
  #expect(stringParam(123 as NSNumber) == "123")
  #expect(intParam("42") == 42)
  #expect(int64Param(NSNumber(value: 9_223_372_036_854_775_000 as Int64)) != nil)
  #expect(boolParam("true") == true)
  #expect(boolParam("false") == false)
  #expect(stringArrayParam("a,b , c").count == 3)
  #expect(stringArrayParam(["x", "y"]).count == 2)
}
