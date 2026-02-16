import Foundation
import Testing

@testable import IMsgCore

@Test
func attachmentResolverResolvesPaths() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let file = dir.appendingPathComponent("test.txt")
  let payload = try #require("hi".data(using: .utf8))
  try payload.write(to: file)

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
    AttachmentResolver.displayName(filename: "file.dat", transferName: "nice.dat") == "nice.dat",
  )
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
func messageFilterHonorsParticipantsAndDates() {
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
    attachmentsCount: 0,
  )
  let filter = MessageFilter(
    participants: ["alice"],
    startDate: now.addingTimeInterval(-10),
    endDate: now.addingTimeInterval(10),
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
  let short = [UInt8(0x01), UInt8(0x2B)] + Array("short".utf8) + [0x86, 0x84]
  let long = [UInt8(0x01), UInt8(0x2B)] + Array("longer text".utf8) + [0x86, 0x84]
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
      region: "US",
    ),
  )
  #expect(captured.count == 7)
  #expect(captured[0] == "+16502530000")
  #expect(captured[2] == "imessage")
  #expect(captured[5].isEmpty)
  #expect(captured[6] == "0")
}

@Test
func messageSenderUsesChatIdentifier() throws {
  let fileManager = FileManager.default
  let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
  defer { try? fileManager.removeItem(at: tempDir) }
  let attachment = tempDir.appendingPathComponent("file.dat")
  try Data("hello".utf8).write(to: attachment)
  let attachmentsSubdirectory = tempDir.appendingPathComponent("staged")
  try fileManager.createDirectory(at: attachmentsSubdirectory, withIntermediateDirectories: true)

  var captured: [String] = []
  let sender = MessageSender(
    runner: { _, args in captured = args },
    attachmentsSubdirectoryProvider: { attachmentsSubdirectory },
  )
  try sender.send(
    MessageSendOptions(
      recipient: "",
      text: "hi",
      attachmentPath: attachment.path,
      service: .sms,
      region: "US",
      chatIdentifier: "iMessage;+;chat123",
      chatGUID: "ignored-guid",
    ),
  )
  #expect(captured[5] == "ignored-guid")
  #expect(captured[6] == "1")
  #expect(captured[4] == "1")
}

@Test
func messageSenderStagesAttachmentsBeforeSend() throws {
  let fileManager = FileManager.default
  let attachmentsSubdirectory = fileManager.temporaryDirectory.appendingPathComponent(
    UUID().uuidString,
  )
  try fileManager.createDirectory(at: attachmentsSubdirectory, withIntermediateDirectories: true)
  defer { try? fileManager.removeItem(at: attachmentsSubdirectory) }
  let sourceDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try fileManager.createDirectory(at: sourceDir, withIntermediateDirectories: true)
  defer { try? fileManager.removeItem(at: sourceDir) }
  let sourceFile = sourceDir.appendingPathComponent("sample.txt")
  let payload = Data("hi".utf8)
  try payload.write(to: sourceFile)

  var captured: [String] = []
  let sender = MessageSender(
    runner: { _, args in captured = args },
    attachmentsSubdirectoryProvider: { attachmentsSubdirectory },
  )

  try sender.send(
    MessageSendOptions(
      recipient: "+16502530000",
      text: "",
      attachmentPath: sourceFile.path,
      service: .imessage,
      region: "US",
    ),
  )

  let stagedPath = captured[3]
  #expect(stagedPath != sourceFile.path)
  #expect(stagedPath.hasPrefix(attachmentsSubdirectory.path))
  #expect(fileManager.fileExists(atPath: stagedPath))
  let stagedData = try Data(contentsOf: URL(fileURLWithPath: stagedPath))
  #expect(stagedData == payload)
}

@Test
func messageSenderThrowsWhenAttachmentsSubdirectoryIsReadOnly() throws {
  let fileManager = FileManager.default
  let readOnlyRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try fileManager.createDirectory(at: readOnlyRoot, withIntermediateDirectories: true)
  try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyRoot.path)
  defer {
    try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyRoot.path)
    try? fileManager.removeItem(at: readOnlyRoot)
  }
  let sourceFile = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let payload = Data("payload".utf8)
  try payload.write(to: sourceFile)
  defer { try? fileManager.removeItem(at: sourceFile) }

  let sender = MessageSender(
    runner: { _, _ in },
    attachmentsSubdirectoryProvider: { readOnlyRoot },
  )

  do {
    try sender.send(
      MessageSendOptions(
        recipient: "+16502530000",
        text: "",
        attachmentPath: sourceFile.path,
        service: .imessage,
        region: "US",
      ),
    )
    #expect(Bool(false))
  } catch {
    #expect(Bool(true))
  }
}

@Test
func messageSenderThrowsWhenAttachmentMissing() {
  let fileManager = FileManager.default
  let attachmentsSubdirectory = fileManager.temporaryDirectory.appendingPathComponent(
    UUID().uuidString,
  )
  try? fileManager.createDirectory(at: attachmentsSubdirectory, withIntermediateDirectories: true)
  defer { try? fileManager.removeItem(at: attachmentsSubdirectory) }
  let missingFile = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
  var runnerCalled = false
  let sender = MessageSender(
    runner: { _, _ in runnerCalled = true },
    attachmentsSubdirectoryProvider: { attachmentsSubdirectory },
  )

  do {
    try sender.send(
      MessageSendOptions(
        recipient: "+16502530000",
        text: "",
        attachmentPath: missingFile,
        service: .imessage,
        region: "US",
      ),
    )
    #expect(Bool(false))
  } catch let error as IMsgError {
    #expect(error.errorDescription?.contains("Attachment not found") == true)
  } catch {
    #expect(Bool(false))
  }

  #expect(runnerCalled == false)
}

@Test
func messageSenderTreatsHandleIdentifierAsRecipient() throws {
  var captured: [String] = []
  let sender = MessageSender(runner: { _, args in
    captured = args
  })
  try sender.send(
    MessageSendOptions(
      recipient: "",
      text: "hi",
      attachmentPath: "",
      service: .auto,
      region: "US",
      chatIdentifier: "+16502530000",
      chatGUID: "",
    ),
  )
  #expect(captured[0] == "+16502530000")
  #expect(captured[5].isEmpty)
  #expect(captured[6] == "0")
}

@Test
func errorDescriptionsIncludeDetails() {
  let error = IMsgError.invalidService("weird")
  #expect(error.errorDescription?.contains("Invalid service: weird") == true)
  let chatError = IMsgError.invalidChatTarget("bad")
  #expect(chatError.errorDescription?.contains("Invalid chat target: bad") == true)
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
