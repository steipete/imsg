import Foundation
import IMsgCore

protocol RPCOutput: Sendable {
  func sendResponse(id: Any, result: Any)
  func sendError(id: Any?, error: RPCError)
  func sendNotification(method: String, params: Any)
}

final class RPCServer {
  let store: MessageStore
  let watcher: MessageWatcher
  let output: RPCOutput
  let cache: ChatCache
  let subscriptions = SubscriptionStore()
  let verbose: Bool
  let sendMessage: (MessageSendOptions) throws -> Void
  let startTyping: (String) throws -> Void
  let stopTyping: (String) throws -> Void

  init(
    store: MessageStore,
    verbose: Bool,
    output: RPCOutput = RPCWriter(),
    sendMessage: @escaping (MessageSendOptions) throws -> Void = { try MessageSender().send($0) },
    startTyping: @escaping (String) throws -> Void = {
      try TypingIndicator.startTyping(chatIdentifier: $0)
    },
    stopTyping: @escaping (String) throws -> Void = {
      try TypingIndicator.stopTyping(chatIdentifier: $0)
    }
  ) {
    self.store = store
    self.watcher = MessageWatcher(store: store)
    self.cache = ChatCache(store: store)
    self.verbose = verbose
    self.output = output
    self.sendMessage = sendMessage
    self.startTyping = startTyping
    self.stopTyping = stopTyping
  }

  func run() async throws {
    while let line = readLine() {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      await handleLine(trimmed)
    }
    await subscriptions.cancelAll()
  }

  func handleLineForTesting(_ line: String) async {
    await handleLine(line)
  }

  func respond(id: Any?, result: Any) {
    guard let id else { return }
    output.sendResponse(id: id, result: result)
  }

  private func handleLine(_ line: String) async {
    guard let data = line.data(using: .utf8) else {
      output.sendError(id: nil, error: RPCError.parseError("invalid utf8"))
      return
    }
    let json: Any
    do {
      json = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      output.sendError(id: nil, error: RPCError.parseError(error.localizedDescription))
      return
    }
    guard let request = json as? [String: Any] else {
      output.sendError(id: nil, error: RPCError.invalidRequest("request must be an object"))
      return
    }
    let jsonrpc = request["jsonrpc"] as? String
    if jsonrpc != nil && jsonrpc != "2.0" {
      output.sendError(id: request["id"], error: RPCError.invalidRequest("jsonrpc must be 2.0"))
      return
    }
    guard let method = request["method"] as? String, !method.isEmpty else {
      output.sendError(id: request["id"], error: RPCError.invalidRequest("method is required"))
      return
    }
    let params = request["params"] as? [String: Any] ?? [:]
    let id = request["id"]

    do {
      switch method {
      case "chats.list":
        try await handleChatsList(id: id, params: params)
      case "messages.history":
        try await handleMessagesHistory(id: id, params: params)
      case "watch.subscribe":
        try await handleWatchSubscribe(id: id, params: params)
      case "watch.unsubscribe":
        try await handleWatchUnsubscribe(id: id, params: params)
      case "send":
        try await handleSend(params: params, id: id)
      case "typing.start":
        try await handleTyping(params: params, id: id, start: true)
      case "typing.stop":
        try await handleTyping(params: params, id: id, start: false)
      default:
        output.sendError(id: id, error: RPCError.methodNotFound(method))
      }
    } catch let err as RPCError {
      output.sendError(id: id, error: err)
    } catch let err as IMsgError {
      switch err {
      case .invalidService, .invalidChatTarget:
        output.sendError(
          id: id,
          error: RPCError.invalidParams(err.errorDescription ?? "invalid params")
        )
      default:
        output.sendError(id: id, error: RPCError.internalError(err.localizedDescription))
      }
    } catch {
      output.sendError(id: id, error: RPCError.internalError(error.localizedDescription))
    }
  }
}
