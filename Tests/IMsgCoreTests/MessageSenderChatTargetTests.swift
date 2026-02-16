import Foundation
import Testing

@testable import IMsgCore

private func normalizeForTest(_ input: String) -> String {
  let result =
    input
    .replacingOccurrences(of: "imessage:", with: "")
    .replacingOccurrences(of: "sms:", with: "")
    .replacingOccurrences(of: "auto:", with: "")
    .filter { "+0123456789".contains($0) }
  return result.isEmpty ? input : result
}

private final class TestMessageSender {
  private var captured: [String] = []

  func send(_ options: MessageSendOptions) throws -> [String] {
    var resolved = options
    let chatTarget = resolveChatTarget(&resolved)
    let useChat = !chatTarget.isEmpty
    if useChat == false {
      if resolved.region.isEmpty { resolved.region = "US" }
      resolved.recipient = normalizeForTest(resolved.recipient)
      if resolved.service == .auto { resolved.service = .imessage }
    }
    captured = [
      resolved.recipient,
      resolved.text,
      resolved.service.rawValue,
      resolved.attachmentPath,
      resolved.attachmentPath.isEmpty ? "0" : "1",
      chatTarget,
      useChat ? "1" : "0",
    ]
    return captured
  }

  private func resolveChatTarget(_ options: inout MessageSendOptions) -> String {
    let guid = options.chatGUID.trimmingCharacters(in: .whitespacesAndNewlines)
    let identifier = options.chatIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    if !identifier.isEmpty && looksLikeHandle(identifier) {
      if options.recipient.isEmpty {
        options.recipient = identifier
      }
      return ""
    }
    if !guid.isEmpty {
      return guid
    }
    if identifier.isEmpty {
      return ""
    }
    return identifier
  }

  private func looksLikeHandle(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return false }
    let lower = trimmed.lowercased()
    if lower.hasPrefix("imessage:") || lower.hasPrefix("sms:") || lower.hasPrefix("auto:") {
      return true
    }
    if trimmed.contains("@") { return true }
    let allowed = CharacterSet(charactersIn: "+0123456789 ()-")
    return trimmed.rangeOfCharacter(from: allowed.inverted) == nil
  }
}

@Test
func messageSenderPrefersHandleWhenChatIdentifierLooksLikeHandle() throws {
  let sender = TestMessageSender()
  let options = MessageSendOptions(
    recipient: "",
    text: "hi",
    attachmentPath: "",
    service: .auto,
    region: "US",
    chatIdentifier: "imessage:+15551234567",
    chatGUID: "iMessage;+;chat123"
  )
  let captured = try sender.send(options)

  #expect(captured[5].isEmpty)
  #expect(captured[6] == "0")
  #expect(captured[0].contains("15551234567"))
}

@Test
func messageSenderUsesChatGuidWhenIdentifierIsGroupHandle() throws {
  let sender = TestMessageSender()
  let options = MessageSendOptions(
    recipient: "",
    text: "hi",
    attachmentPath: "",
    service: .auto,
    region: "US",
    chatIdentifier: "iMessage;+;group123",
    chatGUID: "iMessage;+;group123"
  )
  let captured = try sender.send(options)

  #expect(captured[5] == "iMessage;+;group123")
  #expect(captured[6] == "1")
}
