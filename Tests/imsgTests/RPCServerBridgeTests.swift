import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func rpcSendUsesBridgeWhenReadyAndExistingDirectChatResolves() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let output = TestRPCOutput()
  var appleScriptCalled = false
  var capturedAction: BridgeAction?
  var capturedParams: [String: Any] = [:]
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { _ in appleScriptCalled = true },
    resolveSentMessage: { _, _, _, _ in nil },
    invokeBridge: { action, params in
      capturedAction = action
      capturedParams = params
      return ["messageGuid": "bridge-guid", "chatGuid": "iMessage;-;+123", "service": "iMessage"]
    },
    isBridgeReady: { true }
  )

  let line = #"{"jsonrpc":"2.0","id":"3bridge","method":"send","params":{"to":"+123","text":"yo"}}"#
  await server.handleLineForTesting(line)

  #expect(appleScriptCalled == false)
  #expect(capturedAction == .sendMessage)
  #expect(capturedParams["chatGuid"] as? String == "iMessage;-;+123")
  #expect(capturedParams["message"] as? String == "yo")
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["transport"] as? String == "bridge")
  #expect(result?["guid"] as? String == "bridge-guid")
  #expect(result?["chat_guid"] as? String == "iMessage;-;+123")
  #expect(result?["service"] as? String == "iMessage")
}

@Test
func rpcSendFallsBackToAppleScriptWhenAutoBridgeFails() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  let output = TestRPCOutput()
  var captured: MessageSendOptions?
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    sendMessage: { options in captured = options },
    resolveSentMessage: { _, _, _, _ in nil },
    invokeBridge: { _, _ in throw IMsgBridgeError.dylibReturnedError("nope") },
    isBridgeReady: { true }
  )

  let line =
    #"{"jsonrpc":"2.0","id":"3fallback","method":"send","params":{"to":"+123","text":"yo"}}"#
  await server.handleLineForTesting(line)

  #expect(captured?.recipient == "+123")
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["transport"] as? String == "applescript")
  #expect(result?["chat_guid"] as? String == "iMessage;-;+123")
  #expect(result?["service"] as? String == "iMessage")
}

@Test
func rpcTypingResolvesExistingAnyPrefixChat() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCDirectChat()
  _ = try store.withConnection { db in
    try db.run(
      """
      UPDATE chat
      SET chat_identifier = 'any;-;+123', guid = 'any;-;+123'
      WHERE ROWID = 1
      """
    )
  }
  let output = TestRPCOutput()
  var startedIdentifier: String?
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    startTyping: { startedIdentifier = $0 },
    stopTyping: { _ in }
  )

  let line = #"{"jsonrpc":"2.0","id":"3typing","method":"typing","params":{"to":"+123"}}"#
  await server.handleLineForTesting(line)

  #expect(startedIdentifier == "any;-;+123")
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["ok"] as? Bool == true)
}
