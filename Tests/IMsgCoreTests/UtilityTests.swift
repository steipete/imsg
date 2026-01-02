import Foundation
import Testing

@testable import IMsgCore

@Test
func attachmentResolverResolvesPaths() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let file = dir.appendingPathComponent("test.txt")
  try "hi".data(using: .utf8)!.write(to: file)

  let existing = AttachmentResolver.resolve(file.path)
  #expect(existing.missing == false)
  #expect(existing.resolved.hasSuffix("test.txt"))

  let missing = AttachmentResolver.resolve(dir.appendingPathComponent("missing.txt").path)
  #expect(missing.missing == true)

  let directory = AttachmentResolver.resolve(dir.path)
  #expect(directory.missing == true)
}

@Test
func attachmentResolverDisplayNamePrefersTransfer() {
  #expect(
    AttachmentResolver.displayName(filename: "file.dat", transferName: "nice.dat") == "nice.dat")
  #expect(AttachmentResolver.displayName(filename: "file.dat", transferName: "") == "file.dat")
  #expect(AttachmentResolver.displayName(filename: "", transferName: "") == "(unknown)")
}

@Test
func iso8601ParserParsesFormats() {
  let fractional = "2024-01-02T03:04:05.678Z"
  let standard = "2024-01-02T03:04:05Z"
  #expect(ISO8601Parser.parse(fractional) != nil)
  #expect(ISO8601Parser.parse(standard) != nil)
  #expect(ISO8601Parser.parse("") == nil)
}

@Test
func iso8601ParserFormatsDates() {
  let date = Date(timeIntervalSince1970: 0)
  let formatted = ISO8601Parser.format(date)
  #expect(formatted.contains("T"))
  #expect(ISO8601Parser.parse(formatted) != nil)
}

@Test
func messageFilterHonorsParticipantsAndDates() throws {
  let now = Date(timeIntervalSince1970: 1000)
  let message = Message(
    rowID: 1,
    chatID: 1,
    sender: "Alice",
    text: "hi",
    date: now,
    isFromMe: false,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 0
  )
  let filter = MessageFilter(
    participants: ["alice"],
    startDate: now.addingTimeInterval(-10),
    endDate: now.addingTimeInterval(10)
  )
  #expect(filter.allows(message) == true)
  let pastFilter = MessageFilter(startDate: now.addingTimeInterval(5))
  #expect(pastFilter.allows(message) == false)
}

@Test
func messageFilterRejectsInvalidISO() {
  do {
    _ = try MessageFilter.fromISO(participants: [], startISO: "bad-date", endISO: nil)
    #expect(Bool(false))
  } catch let error as IMsgError {
    switch error {
    case .invalidISODate(let value):
      #expect(value == "bad-date")
    default:
      #expect(Bool(false))
    }
  } catch {
    #expect(Bool(false))
  }
}

@Test
func typedStreamParserPrefersLongestSegment() {
  let short = [UInt8(0x01), UInt8(0x2b)] + Array("short".utf8) + [0x86, 0x84]
  let long = [UInt8(0x01), UInt8(0x2b)] + Array("longer text".utf8) + [0x86, 0x84]
  let data = Data(short + long)
  #expect(TypedStreamParser.parseAttributedBody(data) == "longer text")
}

@Test
func typedStreamParserTrimsControlCharacters() {
  let bytes: [UInt8] = [0x00, 0x0A] + Array("hello".utf8)
  let data = Data(bytes)
  #expect(TypedStreamParser.parseAttributedBody(data) == "hello")
}

@Test
func phoneNumberNormalizerFormatsValidNumber() {
  let normalizer = PhoneNumberNormalizer()
  let normalized = normalizer.normalize("+1 650-253-0000", region: "US")
  #expect(normalized == "+16502530000")
}

@Test
func phoneNumberNormalizerReturnsInputOnFailure() {
  let normalizer = PhoneNumberNormalizer()
  let normalized = normalizer.normalize("not-a-number", region: "US")
  #expect(normalized == "not-a-number")
}

@Test
func messageSenderBuildsArguments() throws {
  var captured: [String] = []
  let sender = MessageSender(runner: { _, args in
    captured = args
  })
  try sender.send(
    MessageSendOptions(
      recipient: "+16502530000",
      text: "hi",
      attachmentPath: "",
      service: .auto,
      region: "US"
    )
  )
  #expect(captured.count == 7)
  #expect(captured[0] == "+16502530000")
  #expect(captured[2] == "imessage")
  #expect(captured[5].isEmpty)
  #expect(captured[6] == "0")
}

@Test
func messageSenderUsesChatIdentifier() throws {
  var captured: [String] = []
  let sender = MessageSender(runner: { _, args in
    captured = args
  })
  try sender.send(
    MessageSendOptions(
      recipient: "",
      text: "hi",
      attachmentPath: "/tmp/file.dat",
      service: .sms,
      region: "US",
      chatIdentifier: "iMessage;+;chat123",
      chatGUID: "ignored-guid"
    )
  )
  #expect(captured[5] == "iMessage;+;chat123")
  #expect(captured[6] == "1")
  #expect(captured[4] == "1")
}

@Test
func messageSenderRejectsReplyTo() throws {
  let sender = MessageSender(runner: { _, _ in })
  do {
    try sender.send(
      MessageSendOptions(
        recipient: "+16502530000",
        text: "hi",
        attachmentPath: "",
        service: .auto,
        region: "US",
        replyToGUID: "msg-guid-1"
      )
    )
    #expect(Bool(false))
  } catch let error as IMsgError {
    switch error {
    case .replyToNotSupported:
      #expect(Bool(true))
    default:
      #expect(Bool(false))
    }
  } catch {
    #expect(Bool(false))
  }
}

@Test
func errorDescriptionsIncludeDetails() {
  let error = IMsgError.invalidService("weird")
  #expect(error.errorDescription?.contains("Invalid service: weird") == true)
  let chatError = IMsgError.invalidChatTarget("bad")
  #expect(chatError.errorDescription?.contains("Invalid chat target: bad") == true)
  let replyError = IMsgError.replyToNotSupported("nope")
  #expect(replyError.errorDescription?.contains("Reply-to not supported: nope") == true)
  let dateError = IMsgError.invalidISODate("2024-99-99")
  #expect(dateError.errorDescription?.contains("Invalid ISO8601 date") == true)
  let scriptError = IMsgError.appleScriptFailure("nope")
  #expect(scriptError.errorDescription?.contains("AppleScript failed: nope") == true)
  let underlying = NSError(domain: "Test", code: 1)
  let permission = IMsgError.permissionDenied(path: "/tmp/chat.db", underlying: underlying)
  let permissionDescription = permission.errorDescription ?? ""
  #expect(permissionDescription.contains("Permission Error") == true)
  #expect(permissionDescription.contains("/tmp/chat.db") == true)
}
