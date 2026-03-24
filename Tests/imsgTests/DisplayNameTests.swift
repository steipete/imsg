import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

// MARK: - ChatPayload display_name encoding

@Test
func chatPayloadEncodesDisplayNameWhenProvided() throws {
  let chat = Chat(
    id: 27, identifier: "+14253433719", name: "", service: "iMessage",
    lastMessageAt: Date(timeIntervalSince1970: 0))
  let payload = ChatPayload(chat: chat, displayName: "Shyawn Karim")
  let data = try JSONEncoder().encode(payload)
  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  #expect(json?["display_name"] as? String == "Shyawn Karim")
  #expect(json?["name"] as? String == "")
  #expect(json?["identifier"] as? String == "+14253433719")
}

@Test
func chatPayloadEncodesNullDisplayNameWhenNil() throws {
  let chat = Chat(
    id: 84, identifier: "a36a822c067c4404a04ddeb731dab9b2", name: "", service: "iMessage",
    lastMessageAt: Date(timeIntervalSince1970: 0))
  let payload = ChatPayload(chat: chat)
  let data = try JSONEncoder().encode(payload)
  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  // display_name key is absent when nil (default Codable behavior)
  #expect(json?["display_name"] == nil)
}

// MARK: - MessagePayload sender_display_name encoding

@Test
func messagePayloadEncodesSenderDisplayName() throws {
  let message = Message(
    rowID: 10, chatID: 1, sender: "+14253433719", text: "hey",
    date: Date(timeIntervalSince1970: 1), isFromMe: false,
    service: "iMessage", handleID: nil, attachmentsCount: 0, guid: "msg-10")
  let payload = MessagePayload(
    message: message, attachments: [], senderDisplayName: "Shyawn Karim")
  let data = try JSONEncoder().encode(payload)
  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  #expect(json?["sender_display_name"] as? String == "Shyawn Karim")
  #expect(json?["sender"] as? String == "+14253433719")
}

@Test
func messagePayloadDefaultsSenderDisplayNameToNil() throws {
  let message = Message(
    rowID: 11, chatID: 1, sender: "+15550000001", text: "hi",
    date: Date(timeIntervalSince1970: 1), isFromMe: false,
    service: "iMessage", handleID: nil, attachmentsCount: 0, guid: "msg-11")
  let payload = MessagePayload(message: message, attachments: [])
  let data = try JSONEncoder().encode(payload)
  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  #expect(json?["sender_display_name"] == nil)
}

// MARK: - ReactionPayload sender_display_name encoding

@Test
func reactionPayloadEncodesSenderDisplayName() throws {
  let reaction = Reaction(
    rowID: 50, reactionType: .like, sender: "+14253433719",
    isFromMe: false, date: Date(timeIntervalSince1970: 2), associatedMessageID: 10)
  let payload = ReactionPayload(reaction: reaction, senderDisplayName: "Shyawn Karim")
  let data = try JSONEncoder().encode(payload)
  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  #expect(json?["sender_display_name"] as? String == "Shyawn Karim")
  #expect(json?["sender"] as? String == "+14253433719")
}

@Test
func reactionPayloadDefaultsSenderDisplayNameToNil() throws {
  let reaction = Reaction(
    rowID: 51, reactionType: .laugh, sender: "+15550000001",
    isFromMe: false, date: Date(timeIntervalSince1970: 2), associatedMessageID: 10)
  let payload = ReactionPayload(reaction: reaction)
  let data = try JSONEncoder().encode(payload)
  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  #expect(json?["sender_display_name"] == nil)
}

// MARK: - Reactions in MessagePayload get resolved independently

@Test
func messagePayloadResolvesReactionSendersFromResolvedNames() throws {
  let message = Message(
    rowID: 12, chatID: 1, sender: "+11111111111", text: "hello",
    date: Date(timeIntervalSince1970: 1), isFromMe: false,
    service: "iMessage", handleID: nil, attachmentsCount: 0, guid: "msg-12")
  let reaction = Reaction(
    rowID: 60, reactionType: .love, sender: "+12222222222",
    isFromMe: false, date: Date(timeIntervalSince1970: 2), associatedMessageID: 12)
  let resolvedNames = [
    "+11111111111": "Alice",
    "+12222222222": "Bob",
  ]
  let payload = MessagePayload(
    message: message, attachments: [], reactions: [reaction],
    senderDisplayName: "Alice", resolvedNames: resolvedNames)
  let data = try JSONEncoder().encode(payload)
  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

  // Message sender resolved
  #expect(json?["sender_display_name"] as? String == "Alice")

  // Reaction sender resolved independently (Bob, not Alice)
  let reactions = json?["reactions"] as? [[String: Any]]
  #expect(reactions?.count == 1)
  #expect(reactions?.first?["sender_display_name"] as? String == "Bob")
  #expect(reactions?.first?["sender"] as? String == "+12222222222")
}

// MARK: - ContactResolver edge cases

@Test
func resolverTreatsEmailLikeIdentifierAsEmailLookup() {
  let resolver = ContactResolver()
  // Should attempt email lookup, not phone - won't match but shouldn't crash
  let result = resolver.resolve("nobody@fake-domain-12345.test")
  #expect(result == nil)
}

@Test
func resolverTreatsNumberWithoutPlusAsPhone() {
  let resolver = ContactResolver()
  // Numbers without + prefix should still attempt phone lookup
  let result = resolver.resolve("14255550000")
  #expect(result == nil)
}

@Test
func batchResolveWithMixedIdentifierTypes() {
  let resolver = ContactResolver()
  let results = resolver.resolve([
    "+15550000001",
    "nobody@fake-domain-12345.test",
    "chat999999999",
    "",
  ])
  // None should resolve, but none should crash
  #expect(results.isEmpty)
}

// MARK: - RPC payload display_name fields

@Test
func rpcChatPayloadIncludesDisplayName() {
  let payload = chatPayload(
    id: 27, identifier: "+14253433719", guid: "", name: "",
    service: "iMessage", lastMessageAt: Date(timeIntervalSince1970: 0),
    participants: ["+14253433719"], displayName: "Shyawn Karim")
  #expect(payload["display_name"] as? String == "Shyawn Karim")
  #expect(payload["name"] as? String == "")
}

@Test
func rpcChatPayloadOmitsDisplayNameWhenNil() {
  let payload = chatPayload(
    id: 84, identifier: "a36a822c", guid: "", name: "",
    service: "iMessage", lastMessageAt: Date(timeIntervalSince1970: 0),
    participants: [])
  #expect(payload["display_name"] == nil)
}

@Test
func rpcMessagePayloadIncludesSenderDisplayName() throws {
  let message = Message(
    rowID: 13, chatID: 1, sender: "+123", text: "test",
    date: Date(timeIntervalSince1970: 1), isFromMe: false,
    service: "iMessage", handleID: nil, attachmentsCount: 0, guid: "msg-13")
  let payload = try messagePayload(
    message: message, chatInfo: nil, participants: [],
    attachments: [], reactions: [], senderDisplayName: "Alice")
  #expect(payload["sender_display_name"] as? String == "Alice")
}
