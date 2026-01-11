import Foundation
import IMsgCore

protocol RPCOutput: Sendable {
  func sendResponse(id: Any, result: Any)
  func sendError(id: Any?, error: RPCError)
  func sendNotification(method: String, params: Any)
}

final class RPCServer {
  private let store: MessageStore
  private let watcher: MessageWatcher
  private let output: RPCOutput
  private let cache: ChatCache
  private let verbose: Bool
  private let sendMessage: (MessageSendOptions) throws -> Void
  private var nextSubscriptionID = 1
  private var subscriptions: [Int: Task<Void, Never>] = [:]

  init(
    store: MessageStore,
    verbose: Bool,
    output: RPCOutput = RPCWriter(),
    sendMessage: @escaping (MessageSendOptions) throws -> Void = { try MessageSender().send($0) }
  ) {
    self.store = store
    self.watcher = MessageWatcher(store: store)
    self.cache = ChatCache(store: store)
    self.verbose = verbose
    self.output = output
    self.sendMessage = sendMessage
  }

  func run() async throws {
    while let line = readLine() {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      await handleLine(trimmed)
    }
    for task in subscriptions.values {
      task.cancel()
    }
  }

  func handleLineForTesting(_ line: String) async {
    await handleLine(line)
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
        let limit = intParam(params["limit"]) ?? 20
        let chats = try store.listChats(limit: max(limit, 1))
        let payloads = try chats.map { chat in
          let info = try cache.info(chatID: chat.id)
          let participants = try cache.participants(chatID: chat.id)
          let identifier = info?.identifier ?? chat.identifier
          let guid = info?.guid ?? ""
          let name = (info?.name.isEmpty == false ? info?.name : nil) ?? chat.name
          let service = info?.service ?? chat.service
          return chatPayload(
            id: chat.id,
            identifier: identifier,
            guid: guid,
            name: name,
            service: service,
            lastMessageAt: chat.lastMessageAt,
            participants: participants
          )
        }
        respond(id: id, result: ["chats": payloads])
      case "messages.history":
        guard let chatID = int64Param(params["chat_id"]) else {
          throw RPCError.invalidParams("chat_id is required")
        }
        let limit = intParam(params["limit"]) ?? 50
        let participants = stringArrayParam(params["participants"])
        let startISO = stringParam(params["start"])
        let endISO = stringParam(params["end"])
        let includeAttachments = boolParam(params["attachments"]) ?? false
        let filter = try MessageFilter.fromISO(
          participants: participants,
          startISO: startISO,
          endISO: endISO
        )
        let filtered = try store.messages(chatID: chatID, limit: max(limit, 1), filter: filter)
        let payloads = try filtered.map { message in
          try buildMessagePayload(
            store: store,
            cache: cache,
            message: message,
            includeAttachments: includeAttachments
          )
        }
        respond(id: id, result: ["messages": payloads])
      case "watch.subscribe":
        let chatID = int64Param(params["chat_id"])
        let sinceRowID = int64Param(params["since_rowid"])
        let participants = stringArrayParam(params["participants"])
        let startISO = stringParam(params["start"])
        let endISO = stringParam(params["end"])
        let includeAttachments = boolParam(params["attachments"]) ?? false
        let filter = try MessageFilter.fromISO(
          participants: participants,
          startISO: startISO,
          endISO: endISO
        )
        let config = MessageWatcherConfiguration()
        let subID = nextSubscriptionID
        nextSubscriptionID += 1
        let localStore = store
        let localWatcher = watcher
        let localCache = cache
        let localWriter = output
        let localFilter = filter
        let localChatID = chatID
        let localSinceRowID = sinceRowID
        let localConfig = config
        let localIncludeAttachments = includeAttachments
        let task = Task {
          do {
            for try await message in localWatcher.stream(
              chatID: localChatID,
              sinceRowID: localSinceRowID,
              configuration: localConfig
            ) {
              if Task.isCancelled { return }
              if !localFilter.allows(message) { continue }
              let payload = try buildMessagePayload(
                store: localStore,
                cache: localCache,
                message: message,
                includeAttachments: localIncludeAttachments
              )
              localWriter.sendNotification(
                method: "message",
                params: ["subscription": subID, "message": payload]
              )
            }
          } catch {
            localWriter.sendNotification(
              method: "error",
              params: [
                "subscription": subID,
                "error": ["message": String(describing: error)],
              ]
            )
          }
        }
        subscriptions[subID] = task
        respond(id: id, result: ["subscription": subID])
      case "watch.unsubscribe":
        guard let subID = intParam(params["subscription"]) else {
          throw RPCError.invalidParams("subscription is required")
        }
        if let task = subscriptions.removeValue(forKey: subID) {
          task.cancel()
        }
        respond(id: id, result: ["ok": true])
      case "send":
        try handleSend(params: params, id: id)
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

  private func respond(id: Any?, result: Any) {
    guard let id else { return }
    output.sendResponse(id: id, result: result)
  }

  private func handleSend(params: [String: Any], id: Any?) throws {
    let text = stringParam(params["text"]) ?? ""
    let file = stringParam(params["file"]) ?? ""
    let serviceRaw = stringParam(params["service"]) ?? "auto"
    guard let service = MessageService(rawValue: serviceRaw) else {
      throw RPCError.invalidParams("invalid service")
    }
    let region = stringParam(params["region"]) ?? "US"

    let chatID = int64Param(params["chat_id"])
    let chatIdentifier = stringParam(params["chat_identifier"]) ?? ""
    let chatGUID = stringParam(params["chat_guid"]) ?? ""
    let hasChatTarget = chatID != nil || !chatIdentifier.isEmpty || !chatGUID.isEmpty
    let recipient = stringParam(params["to"]) ?? ""
    if hasChatTarget && !recipient.isEmpty {
      throw RPCError.invalidParams("use to or chat_*; not both")
    }
    if !hasChatTarget && recipient.isEmpty {
      throw RPCError.invalidParams("to is required for direct sends")
    }

    if text.isEmpty && file.isEmpty {
      throw RPCError.invalidParams("text or file is required")
    }

    var resolvedChatIdentifier = chatIdentifier
    var resolvedChatGUID = chatGUID
    if let chatID {
      guard let info = try cache.info(chatID: chatID) else {
        throw RPCError.invalidParams("unknown chat_id \(chatID)")
      }
      resolvedChatIdentifier = info.identifier
      resolvedChatGUID = info.guid
    }
    if hasChatTarget && resolvedChatIdentifier.isEmpty && resolvedChatGUID.isEmpty {
      throw RPCError.invalidParams("missing chat identifier or guid")
    }

    try sendMessage(
      MessageSendOptions(
        recipient: recipient,
        text: text,
        attachmentPath: file,
        service: service,
        region: region,
        chatIdentifier: resolvedChatIdentifier,
        chatGUID: resolvedChatGUID
      )
    )
    respond(id: id, result: ["ok": true])
  }

}

private func buildMessagePayload(
  store: MessageStore,
  cache: ChatCache,
  message: Message,
  includeAttachments: Bool
) throws -> [String: Any] {
  let chatInfo = try cache.info(chatID: message.chatID)
  let participants = try cache.participants(chatID: message.chatID)
  let attachments = includeAttachments ? try store.attachments(for: message.rowID) : []
  let reactions = includeAttachments ? try store.reactions(for: message.rowID) : []
  return messagePayload(
    message: message,
    chatInfo: chatInfo,
    participants: participants,
    attachments: attachments,
    reactions: reactions
  )
}

private final class RPCWriter: RPCOutput, @unchecked Sendable {
  private let queue = DispatchQueue(label: "imsg.rpc.writer")

  func sendResponse(id: Any, result: Any) {
    send(["jsonrpc": "2.0", "id": id, "result": result])
  }

  func sendError(id: Any?, error: RPCError) {
    let payload: [String: Any] = [
      "jsonrpc": "2.0",
      "id": id ?? NSNull(),
      "error": error.asDictionary(),
    ]
    send(payload)
  }

  func sendNotification(method: String, params: Any) {
    send(["jsonrpc": "2.0", "method": method, "params": params])
  }

  private func send(_ object: Any) {
    queue.sync {
      do {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        if let output = String(data: data, encoding: .utf8) {
          FileHandle.standardOutput.write(Data(output.utf8))
          FileHandle.standardOutput.write(Data("\n".utf8))
        }
      } catch {
        if let fallback =
          "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"write failed\"}}\n"
          .data(using: .utf8)
        {
          FileHandle.standardOutput.write(fallback)
        }
      }
    }
  }
}

struct RPCError: Error {
  let code: Int
  let message: String
  let data: String?

  static func parseError(_ message: String) -> RPCError {
    RPCError(code: -32700, message: "Parse error", data: message)
  }

  static func invalidRequest(_ message: String) -> RPCError {
    RPCError(code: -32600, message: "Invalid Request", data: message)
  }

  static func methodNotFound(_ method: String) -> RPCError {
    RPCError(code: -32601, message: "Method not found", data: method)
  }

  static func invalidParams(_ message: String) -> RPCError {
    RPCError(code: -32602, message: "Invalid params", data: message)
  }

  static func internalError(_ message: String) -> RPCError {
    RPCError(code: -32603, message: "Internal error", data: message)
  }

  func asDictionary() -> [String: Any] {
    var dict: [String: Any] = [
      "code": code,
      "message": message,
    ]
    if let data {
      dict["data"] = data
    }
    return dict
  }
}

private final class ChatCache: @unchecked Sendable {
  private let store: MessageStore
  private var infoCache: [Int64: ChatInfo] = [:]
  private var participantsCache: [Int64: [String]] = [:]

  init(store: MessageStore) {
    self.store = store
  }

  func info(chatID: Int64) throws -> ChatInfo? {
    if let cached = infoCache[chatID] { return cached }
    if let info = try store.chatInfo(chatID: chatID) {
      infoCache[chatID] = info
      return info
    }
    return nil
  }

  func participants(chatID: Int64) throws -> [String] {
    if let cached = participantsCache[chatID] { return cached }
    let participants = try store.participants(chatID: chatID)
    participantsCache[chatID] = participants
    return participants
  }
}
