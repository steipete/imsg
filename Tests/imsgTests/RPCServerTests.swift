import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

private enum RPCTestDatabase {
  static func appleEpoch(_ date: Date) -> Int64 {
    let seconds = date.timeIntervalSince1970 - MessageStore.appleEpochOffset
    return Int64(seconds * 1_000_000_000)
  }

  static func makeStore() throws -> MessageStore {
    let db = try Connection(.inMemory)
    try db.execute(
      """
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        handle_id INTEGER,
        text TEXT,
        date INTEGER,
        is_from_me INTEGER,
        service TEXT
      );
      """
    )
    try db.execute(
      """
      CREATE TABLE chat (
        ROWID INTEGER PRIMARY KEY,
        chat_identifier TEXT,
        guid TEXT,
        display_name TEXT,
        service_name TEXT
      );
      """
    )
    try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
    try db.execute("CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);")
    try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);")
    try db.execute(
      """
      CREATE TABLE attachment (
        ROWID INTEGER PRIMARY KEY,
        filename TEXT,
        transfer_name TEXT,
        uti TEXT,
        mime_type TEXT,
        total_bytes INTEGER,
        is_sticker INTEGER
      );
      """
    )
    try db.execute(
      "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);")

    let now = Date()
    try db.run(
      """
      INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
      VALUES (1, 'iMessage;+;chat123', 'iMessage;+;chat123', 'Group Chat', 'iMessage')
      """
    )
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123'), (2, 'me@icloud.com')")
    try db.run("INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 1), (1, 2)")
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
      VALUES (5, 1, 'hello', ?, 0, 'iMessage')
      """,
      appleEpoch(now)
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 5)")

    return try MessageStore(
      connection: db, path: ":memory:", hasAttributedBody: false, hasReactionColumns: false)
  }
}

final class TestRPCOutput: RPCOutput, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var responses: [[String: Any]] = []
  private(set) var errors: [[String: Any]] = []
  private(set) var notifications: [[String: Any]] = []

  func sendResponse(id: Any, result: Any) {
    record(&responses, value: ["jsonrpc": "2.0", "id": id, "result": result])
  }

  func sendError(id: Any?, error: RPCError) {
    let payload: [String: Any] = [
      "jsonrpc": "2.0",
      "id": id ?? NSNull(),
      "error": error.asDictionary(),
    ]
    record(&errors, value: payload)
  }

  func sendNotification(method: String, params: Any) {
    record(&notifications, value: ["jsonrpc": "2.0", "method": method, "params": params])
  }

  private func record(_ bucket: inout [[String: Any]], value: [String: Any]) {
    lock.lock()
    defer { lock.unlock() }
    bucket.append(value)
  }
}

private func int64Value(_ value: Any?) -> Int64? {
  if let value = value as? Int64 { return value }
  if let value = value as? Int { return Int64(value) }
  if let value = value as? NSNumber { return value.int64Value }
  return nil
}

@Test
func rpcChatsListReturnsChatPayload() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":"1","method":"chats.list","params":{"limit":10}}"#
  await server.handleLineForTesting(line)

  #expect(output.responses.count == 1)
  let result = output.responses[0]["result"] as? [String: Any]
  let chats = result?["chats"] as? [[String: Any]] ?? []
  #expect(chats.count == 1)
  let chat = chats[0]
  #expect(int64Value(chat["id"]) == 1)
  #expect(chat["identifier"] as? String == "iMessage;+;chat123")
  #expect(chat["is_group"] as? Bool == true)
  #expect((chat["participants"] as? [String])?.count == 2)
}

@Test
func rpcMessagesHistoryIncludesChatFields() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":2,"method":"messages.history","params":{"chat_id":1,"limit":5}}"#
  await server.handleLineForTesting(line)

  let result = output.responses.first?["result"] as? [String: Any]
  let messages = result?["messages"] as? [[String: Any]] ?? []
  #expect(messages.count == 1)
  let message = messages[0]
  #expect(int64Value(message["chat_id"]) == 1)
  #expect(message["chat_identifier"] as? String == "iMessage;+;chat123")
  #expect(message["is_group"] as? Bool == true)
}

@Test
func rpcSendResolvesChatID() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  var captured: MessageSendOptions?
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { options in captured = options }
  )

  let line = #"{"jsonrpc":"2.0","id":"3","method":"send","params":{"chat_id":1,"text":"yo"}}"#
  await server.handleLineForTesting(line)

  #expect(captured?.chatIdentifier == "iMessage;+;chat123")
  #expect(captured?.chatGUID == "iMessage;+;chat123")
  #expect(captured?.recipient.isEmpty == true)
  #expect(output.responses.first?["result"] as? [String: Any] != nil)
}

@Test
func rpcSendRejectsMissingTextAndFile() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":"4","method":"send","params":{"to":"+15551234567"}}"#
  await server.handleLineForTesting(line)

  #expect(output.errors.count == 1)
  let error = output.errors[0]["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcRejectsInvalidJSON() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  await server.handleLineForTesting("not-json")

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32700)
}

@Test
func rpcRejectsNonObjectRequest() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  await server.handleLineForTesting("[]")

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32600)
}

@Test
func rpcRejectsInvalidJSONRPCVersion() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"1.0","id":1,"method":"chats.list"}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32600)
}

@Test
func rpcRejectsMissingMethod() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":1}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32600)
}

@Test
func rpcReportsMethodNotFound() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":1,"method":"nope"}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32601)
}

@Test
func rpcHistoryRequiresChatID() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":5,"method":"messages.history","params":{"limit":5}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcSendRejectsInvalidService() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":6,"method":"send","params":{"to":"+15551234567","text":"hi","service":"fax"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcSendRejectsMissingRecipientForDirectSend() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":7,"method":"send","params":{"text":"hi"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcSendRejectsChatAndRecipient() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":8,"method":"send","params":{"chat_id":1,"to":"+15551234567","text":"hi"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcSendRejectsUnknownChatID() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":9,"method":"send","params":{"chat_id":999,"text":"hi"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcTypingStartResolvesSMSRecipient() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  var startedIdentifier: String?
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    startTyping: { identifier in startedIdentifier = identifier },
    stopTyping: { _ in }
  )

  let line =
    #"{"jsonrpc":"2.0","id":20,"method":"typing.start","params":{"to":"+15551234567","service":"sms"}}"#
  await server.handleLineForTesting(line)

  #expect(startedIdentifier == "SMS;-;+15551234567")
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["ok"] as? Bool == true)
}

@Test
func rpcTypingStopResolvesChatID() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  var stoppedIdentifier: String?
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    startTyping: { _ in },
    stopTyping: { identifier in stoppedIdentifier = identifier }
  )

  let line = #"{"jsonrpc":"2.0","id":21,"method":"typing.stop","params":{"chat_id":1}}"#
  await server.handleLineForTesting(line)

  #expect(stoppedIdentifier == "iMessage;+;chat123")
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["ok"] as? Bool == true)
}

@Test
func rpcTypingRejectsInvalidService() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":22,"method":"typing.start","params":{"to":"+15551234567","service":"fax"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcTypingRejectsChatAndRecipient() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":23,"method":"typing.start","params":{"chat_id":1,"to":"+15551234567"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcWatchSubscribeEmitsNotificationAndUnsubscribe() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let subscribe =
    #"{"jsonrpc":"2.0","id":10,"method":"watch.subscribe","params":{"chat_id":1,"since_rowid":-1}}"#
  await server.handleLineForTesting(subscribe)

  let result = output.responses.first?["result"] as? [String: Any]
  let subscription = int64Value(result?["subscription"]) ?? 0
  #expect(subscription > 0)

  for _ in 0..<20 {
    if output.notifications.count >= 1 { break }
    try await Task.sleep(nanoseconds: 50_000_000)
  }
  #expect(output.notifications.count == 1)
  let params = output.notifications.first?["params"] as? [String: Any]
  #expect(int64Value(params?["subscription"]) == subscription)
  #expect(params?["message"] as? [String: Any] != nil)

  let unsubscribe =
    #"{"jsonrpc":"2.0","id":11,"method":"watch.unsubscribe","params":{"subscription":\#(subscription)}}"#
  await server.handleLineForTesting(unsubscribe)

  #expect(output.responses.count >= 2)
}

@Test
func rpcWatchUnsubscribeRequiresSubscription() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":12,"method":"watch.unsubscribe","params":{}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}
