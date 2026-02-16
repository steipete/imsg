import Foundation
import IMsgCore

extension RPCServer {
  func handleChatsList(id: Any?, params: [String: Any]) async throws {
    let limit = intParam(params["limit"]) ?? 20
    let chats = try store.listChats(limit: max(limit, 1))
    var payloads: [[String: Any]] = []
    payloads.reserveCapacity(chats.count)

    for chat in chats {
      let info = try await cache.info(chatID: chat.id)
      let participants = try await cache.participants(chatID: chat.id)
      let identifier = info?.identifier ?? chat.identifier
      let guid = info?.guid ?? ""
      let name = (info?.name.isEmpty == false ? info?.name : nil) ?? chat.name
      let service = info?.service ?? chat.service
      payloads.append(
        chatPayload(
          id: chat.id,
          identifier: identifier,
          guid: guid,
          name: name,
          service: service,
          lastMessageAt: chat.lastMessageAt,
          participants: participants
        ))
    }

    respond(id: id, result: ["chats": payloads])
  }

  func handleMessagesHistory(id: Any?, params: [String: Any]) async throws {
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

    var payloads: [[String: Any]] = []
    payloads.reserveCapacity(filtered.count)
    for message in filtered {
      let payload = try await buildMessagePayload(
        store: store,
        cache: cache,
        message: message,
        includeAttachments: includeAttachments
      )
      payloads.append(payload)
    }

    respond(id: id, result: ["messages": payloads])
  }

  func handleWatchSubscribe(id: Any?, params: [String: Any]) async throws {
    let chatID = int64Param(params["chat_id"])
    let sinceRowID = int64Param(params["since_rowid"])
    let participants = stringArrayParam(params["participants"])
    let startISO = stringParam(params["start"])
    let endISO = stringParam(params["end"])
    let includeAttachments = boolParam(params["attachments"]) ?? false
    let includeReactions = boolParam(params["include_reactions"]) ?? false
    let filter = try MessageFilter.fromISO(
      participants: participants,
      startISO: startISO,
      endISO: endISO
    )
    let config = MessageWatcherConfiguration(includeReactions: includeReactions)
    let subID = await subscriptions.allocateID()
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
          let payload = try await buildMessagePayload(
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
    await subscriptions.insert(task, for: subID)
    respond(id: id, result: ["subscription": subID])
  }

  func handleWatchUnsubscribe(id: Any?, params: [String: Any]) async throws {
    guard let subID = intParam(params["subscription"]) else {
      throw RPCError.invalidParams("subscription is required")
    }
    if let task = await subscriptions.remove(subID) {
      task.cancel()
    }
    respond(id: id, result: ["ok": true])
  }

  func handleTyping(params: [String: Any], id: Any?, start: Bool) async throws {
    let input = ChatTargetInput(
      recipient: stringParam(params["to"]) ?? "",
      chatID: int64Param(params["chat_id"]),
      chatIdentifier: stringParam(params["chat_identifier"]) ?? "",
      chatGUID: stringParam(params["chat_guid"]) ?? ""
    )
    try ChatTargetResolver.validateRecipientRequirements(
      input: input,
      mixedTargetError: RPCError.invalidParams("use to or chat_*; not both"),
      missingRecipientError: RPCError.invalidParams("to is required for direct typing")
    )

    let resolvedTarget = try await ChatTargetResolver.resolveChatTarget(
      input: input,
      lookupChat: { chatID in try await cache.info(chatID: chatID) },
      unknownChatError: { chatID in
        RPCError.invalidParams("unknown chat_id \(chatID)")
      }
    )

    let resolvedIdentifier: String
    if let preferred = resolvedTarget.preferredIdentifier {
      resolvedIdentifier = preferred
    } else if input.hasChatTarget {
      throw RPCError.invalidParams("missing chat identifier or guid")
    } else {
      let serviceRaw = stringParam(params["service"]) ?? "imessage"
      resolvedIdentifier = try ChatTargetResolver.directTypingIdentifier(
        recipient: input.recipient,
        serviceRaw: serviceRaw,
        invalidServiceError: { _ in RPCError.invalidParams("invalid service") }
      )
    }

    if start {
      try startTyping(resolvedIdentifier)
    } else {
      try stopTyping(resolvedIdentifier)
    }
    respond(id: id, result: ["ok": true])
  }

  func handleSend(params: [String: Any], id: Any?) async throws {
    let text = stringParam(params["text"]) ?? ""
    let file = stringParam(params["file"]) ?? ""
    let serviceRaw = stringParam(params["service"]) ?? "auto"
    guard let service = MessageService(rawValue: serviceRaw) else {
      throw RPCError.invalidParams("invalid service")
    }
    let region = stringParam(params["region"]) ?? "US"

    let input = ChatTargetInput(
      recipient: stringParam(params["to"]) ?? "",
      chatID: int64Param(params["chat_id"]),
      chatIdentifier: stringParam(params["chat_identifier"]) ?? "",
      chatGUID: stringParam(params["chat_guid"]) ?? ""
    )
    try ChatTargetResolver.validateRecipientRequirements(
      input: input,
      mixedTargetError: RPCError.invalidParams("use to or chat_*; not both"),
      missingRecipientError: RPCError.invalidParams("to is required for direct sends")
    )

    if text.isEmpty && file.isEmpty {
      throw RPCError.invalidParams("text or file is required")
    }

    let resolvedTarget = try await ChatTargetResolver.resolveChatTarget(
      input: input,
      lookupChat: { chatID in try await cache.info(chatID: chatID) },
      unknownChatError: { chatID in
        RPCError.invalidParams("unknown chat_id \(chatID)")
      }
    )
    if input.hasChatTarget && resolvedTarget.preferredIdentifier == nil {
      throw RPCError.invalidParams("missing chat identifier or guid")
    }

    try sendMessage(
      MessageSendOptions(
        recipient: input.recipient,
        text: text,
        attachmentPath: file,
        service: service,
        region: region,
        chatIdentifier: resolvedTarget.chatIdentifier,
        chatGUID: resolvedTarget.chatGUID
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
) async throws -> [String: Any] {
  let chatInfo = try await cache.info(chatID: message.chatID)
  let participants = try await cache.participants(chatID: message.chatID)
  let attachments = includeAttachments ? try store.attachments(for: message.rowID) : []
  let reactions = includeAttachments ? try store.reactions(for: message.rowID) : []
  return try messagePayload(
    message: message,
    chatInfo: chatInfo,
    participants: participants,
    attachments: attachments,
    reactions: reactions
  )
}
