import Foundation
import IMsgCore

typealias SentMessageResolver = (
  _ store: MessageStore,
  _ options: MessageSendOptions,
  _ chatID: Int64?,
  _ sentAt: Date
) async throws -> Message?

protocol RPCOutput: Sendable {
  func sendResponse(id: Any, result: Any)
  func sendError(id: Any?, error: RPCError)
  func sendNotification(method: String, params: Any)
}

/// Methods exposed by `imsg rpc` over JSON-RPC. Advertised to clients via
/// `imsg status --json` (`rpc_methods` field) so capability-aware consumers
/// (like the openclaw imessage channel plugin) can gate features off when
/// running against an older imsg build that doesn't implement a given method.
///
/// Keep in sync with the dispatch switch in `RPCServer.handleLine`.
let kSupportedRPCMethods: [String] = [
  "chats.list",
  "chats.create",
  "chats.delete",
  "chats.markUnread",
  "messages.history",
  "watch.subscribe",
  "watch.unsubscribe",
  "send",
  "typing",
  "read",
  "group.rename",
  "group.setIcon",
  "group.addParticipant",
  "group.removeParticipant",
  "group.leave",
]

final class RPCServer {
  let store: MessageStore
  let watcher: MessageWatcher
  let output: RPCOutput
  let cache: ChatCache
  let subscriptions = SubscriptionStore()
  let verbose: Bool
  let sendMessage: (MessageSendOptions) throws -> Void
  let resolveSentMessage: SentMessageResolver
  let contactResolver: any ContactResolving

  init(
    store: MessageStore,
    verbose: Bool,
    output: RPCOutput = RPCWriter(),
    sendMessage: @escaping (MessageSendOptions) throws -> Void = { try MessageSender().send($0) },
    resolveSentMessage: @escaping SentMessageResolver = RPCServer.resolveSentMessage,
    contactResolver: any ContactResolving = NoOpContactResolver()
  ) {
    self.store = store
    self.watcher = MessageWatcher(store: store)
    self.cache = ChatCache(store: store)
    self.verbose = verbose
    self.output = output
    self.sendMessage = sendMessage
    self.resolveSentMessage = resolveSentMessage
    self.contactResolver = contactResolver
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
      case "typing":
        try await handleTyping(params: params, id: id)
      case "read":
        try await handleRead(params: params, id: id)
      case "chats.create":
        try await handleChatsCreate(id: id, params: params)
      case "chats.delete":
        try await handleChatsDelete(id: id, params: params)
      case "chats.markUnread":
        try await handleChatsMarkUnread(id: id, params: params)
      case "group.rename":
        try await handleGroupRename(id: id, params: params)
      case "group.setIcon":
        try await handleGroupSetIcon(id: id, params: params)
      case "group.addParticipant":
        try await handleGroupAddParticipant(id: id, params: params)
      case "group.removeParticipant":
        try await handleGroupRemoveParticipant(id: id, params: params)
      case "group.leave":
        try await handleGroupLeave(id: id, params: params)
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

  static func resolveSentMessage(
    store: MessageStore,
    options: MessageSendOptions,
    chatID: Int64?,
    sentAt: Date
  ) async throws -> Message? {
    try await SentMessageVerifier.resolveSentMessage(
      store: store,
      options: options,
      chatID: chatID,
      sentAt: sentAt
    )
  }
}
