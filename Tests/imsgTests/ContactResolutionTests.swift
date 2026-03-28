import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func looksLikeNameDetectsPhoneNumbers() {
  #expect(ChatTargetResolver.looksLikeName("+15551234567") == false)
  #expect(ChatTargetResolver.looksLikeName("5551234567") == false)
  #expect(ChatTargetResolver.looksLikeName("(555) 123-4567") == false)
  #expect(ChatTargetResolver.looksLikeName("") == false)
}

@Test
func looksLikeNameDetectsEmails() {
  #expect(ChatTargetResolver.looksLikeName("user@example.com") == false)
}

@Test
func looksLikeNameDetectsNames() {
  #expect(ChatTargetResolver.looksLikeName("John Smith") == true)
  #expect(ChatTargetResolver.looksLikeName("Alice") == true)
  #expect(ChatTargetResolver.looksLikeName("John") == true)
}

@Test
func resolveRecipientNamePassesThroughPhone() throws {
  let mock = MockContactResolver()
  let result = try ChatTargetResolver.resolveRecipientName("+15551234567", contacts: mock)
  #expect(result == "+15551234567")
}

@Test
func resolveRecipientNamePassesThroughEmail() throws {
  let mock = MockContactResolver()
  let result = try ChatTargetResolver.resolveRecipientName("user@example.com", contacts: mock)
  #expect(result == "user@example.com")
}

@Test
func resolveRecipientNameResolvesUniqueName() throws {
  let mock = MockContactResolver(
    contacts: [(name: "John Smith", handle: "+15551234567")]
  )
  let result = try ChatTargetResolver.resolveRecipientName("John Smith", contacts: mock)
  #expect(result == "+15551234567")
}

@Test
func resolveRecipientNameThrowsOnAmbiguousMatch() {
  let mock = MockContactResolver(
    contacts: [
      (name: "John Smith", handle: "+15551234567"),
      (name: "John Doe", handle: "+15559876543"),
    ]
  )
  #expect(throws: (any Error).self) {
    try ChatTargetResolver.resolveRecipientName("John", contacts: mock)
  }
}

@Test
func resolveRecipientNamePassesThroughUnknownName() throws {
  let mock = MockContactResolver()
  let result = try ChatTargetResolver.resolveRecipientName("Unknown Person", contacts: mock)
  #expect(result == "Unknown Person")
}

@Test
func messagePayloadIncludesSenderName() throws {
  let message = Message(
    rowID: 1,
    chatID: 1,
    sender: "+15551234567",
    text: "hello",
    date: Date(timeIntervalSince1970: 0),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 0,
    guid: "msg-1"
  )
  let payload = MessagePayload(
    message: message,
    attachments: [],
    senderName: "John Smith"
  )
  #expect(payload.senderName == "John Smith")
  #expect(payload.sender == "+15551234567")
}

@Test
func messagePayloadOmitsSenderNameWhenNil() throws {
  let message = Message(
    rowID: 1,
    chatID: 1,
    sender: "+15551234567",
    text: "hello",
    date: Date(timeIntervalSince1970: 0),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 0,
    guid: "msg-1"
  )
  let payload = MessagePayload(message: message, attachments: [])
  #expect(payload.senderName == nil)
}

@Test
func chatPayloadIncludesContactName() {
  let chat = Chat(
    id: 1,
    identifier: "+15551234567",
    name: "+15551234567",
    service: "iMessage",
    lastMessageAt: Date(timeIntervalSince1970: 0)
  )
  let payload = ChatPayload(chat: chat, contactName: "John Smith")
  #expect(payload.contactName == "John Smith")
}

@Test
func reactionPayloadIncludesSenderName() {
  let reaction = Reaction(
    rowID: 1,
    reactionType: .like,
    sender: "+15551234567",
    isFromMe: false,
    date: Date(timeIntervalSince1970: 0),
    associatedMessageID: 1
  )
  let payload = ReactionPayload(reaction: reaction, senderName: "Alice")
  #expect(payload.senderName == "Alice")
}

@Test
func rpcChatPayloadIncludesContactName() {
  let date = Date(timeIntervalSince1970: 0)
  let payload = chatPayload(
    id: 1,
    identifier: "+15551234567",
    guid: "iMessage;-;+15551234567",
    name: "+15551234567",
    service: "iMessage",
    lastMessageAt: date,
    participants: ["+15551234567"],
    contactName: "John Smith"
  )
  #expect(payload["contact_name"] as? String == "John Smith")
}

@Test
func rpcChatPayloadOmitsContactNameWhenNil() {
  let date = Date(timeIntervalSince1970: 0)
  let payload = chatPayload(
    id: 1,
    identifier: "+15551234567",
    guid: "iMessage;-;+15551234567",
    name: "+15551234567",
    service: "iMessage",
    lastMessageAt: date,
    participants: ["+15551234567"]
  )
  #expect(payload["contact_name"] == nil)
}

@Test
func rpcMessagePayloadIncludesSenderName() throws {
  let message = Message(
    rowID: 1,
    chatID: 1,
    sender: "+15551234567",
    text: "hello",
    date: Date(timeIntervalSince1970: 0),
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 0,
    guid: "msg-1"
  )
  let payload = try messagePayload(
    message: message,
    chatInfo: nil,
    participants: [],
    attachments: [],
    reactions: [],
    senderName: "John Smith"
  )
  #expect(payload["sender_name"] as? String == "John Smith")
}
