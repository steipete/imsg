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
      let contactName =
        isGroupHandle(identifier: identifier, guid: guid)
        ? nil : contactResolver.displayName(for: identifier)
      payloads.append(
        chatPayload(
          id: chat.id,
          identifier: identifier,
          guid: guid,
          name: name,
          service: service,
          lastMessageAt: chat.lastMessageAt,
          participants: participants,
          contactName: contactName
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
    let attachmentOptions = AttachmentQueryOptions(
      convertUnsupported: boolParam(params["convert_attachments"]) ?? false)
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
        includeAttachments: includeAttachments,
        includeReactions: true,
        attachmentOptions: attachmentOptions,
        contactResolver: contactResolver
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
    let attachmentOptions = AttachmentQueryOptions(
      convertUnsupported: boolParam(params["convert_attachments"]) ?? false)
    let includeReactions = boolParam(params["include_reactions"]) ?? false
    let debounceInterval = try watchDebounceIntervalParam(params)
    let filter = try MessageFilter.fromISO(
      participants: participants,
      startISO: startISO,
      endISO: endISO
    )
    let config = MessageWatcherConfiguration(
      debounceInterval: debounceInterval,
      includeReactions: includeReactions
    )
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
    let localAttachmentOptions = attachmentOptions
    let localIncludeReactions = includeReactions
    let localContactResolver = contactResolver
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
            includeAttachments: localIncludeAttachments,
            includeReactions: localIncludeReactions,
            attachmentOptions: localAttachmentOptions,
            contactResolver: localContactResolver
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

  func handleSend(params: [String: Any], id: Any?) async throws {
    let text = stringParam(params["text"]) ?? ""
    let file = stringParam(params["file"]) ?? ""
    let serviceRaw = stringParam(params["service"]) ?? "auto"
    guard let service = MessageService(rawValue: serviceRaw) else {
      throw RPCError.invalidParams("invalid service")
    }
    let region = stringParam(params["region"]) ?? "US"
    let rawRecipient = stringParam(params["to"]) ?? ""
    let rawInput = ChatTargetInput(
      recipient: rawRecipient,
      chatID: int64Param(params["chat_id"]),
      chatIdentifier: stringParam(params["chat_identifier"]) ?? "",
      chatGUID: stringParam(params["chat_guid"]) ?? ""
    )
    try ChatTargetResolver.validateRecipientRequirements(
      input: rawInput,
      mixedTargetError: RPCError.invalidParams("use to or chat_*; not both"),
      missingRecipientError: RPCError.invalidParams("to is required for direct sends")
    )
    let recipient: String
    do {
      recipient =
        rawInput.hasChatTarget || rawRecipient.isEmpty
        ? rawRecipient
        : try ChatTargetResolver.resolveRecipientName(rawRecipient, contacts: contactResolver)
    } catch {
      throw RPCError.invalidParams(error.localizedDescription)
    }
    let input = ChatTargetInput(
      recipient: recipient,
      chatID: rawInput.chatID,
      chatIdentifier: rawInput.chatIdentifier,
      chatGUID: rawInput.chatGUID
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

    let options = MessageSendOptions(
      recipient: input.recipient,
      text: text,
      attachmentPath: file,
      service: service,
      region: region,
      chatIdentifier: resolvedTarget.chatIdentifier,
      chatGUID: resolvedTarget.chatGUID
    )
    let sentAt = Date()
    try sendMessage(options)

    let verificationChatID =
      input.chatID
      ?? resolvedTarget.preferredIdentifier.flatMap { try? store.chatInfo(matchingTarget: $0)?.id }
    let sentMessage = try? await resolveSentMessage(store, options, verificationChatID, sentAt)
    if sentMessage == nil {
      try SentMessageVerifier.throwIfMisroutedChatSend(
        store: store,
        options: options,
        sentAt: sentAt
      )
    }
    var result: [String: Any] = ["ok": true]
    if let sentMessage {
      result["id"] = sentMessage.rowID
      if !sentMessage.guid.isEmpty {
        result["guid"] = sentMessage.guid
      }
    }
    respond(id: id, result: result)
  }

  /// `typing` — start/stop the local-user typing indicator. Mirrors the
  /// `imsg typing` CLI surface (which is purely a wrapper over `TypingIndicator`)
  /// so callers that talk to `imsg rpc` over JSON-RPC have parity with the CLI.
  func handleTyping(params: [String: Any], id: Any?) async throws {
    let isTyping = boolParam(params["typing"]) ?? true
    let serviceRaw = stringParam(params["service"]) ?? "imessage"
    let input = ChatTargetInput(
      recipient: stringParam(params["to"]) ?? "",
      chatID: int64Param(params["chat_id"]),
      chatIdentifier: stringParam(params["chat_identifier"]) ?? "",
      chatGUID: stringParam(params["chat_guid"]) ?? ""
    )
    try ChatTargetResolver.validateRecipientRequirements(
      input: input,
      mixedTargetError: RPCError.invalidParams("use to or chat_*; not both"),
      missingRecipientError: RPCError.invalidParams("to is required")
    )
    let resolvedTarget = try await ChatTargetResolver.resolveChatTarget(
      input: input,
      lookupChat: { chatID in try await cache.info(chatID: chatID) },
      unknownChatError: { chatID in
        RPCError.invalidParams("unknown chat_id \(chatID)")
      }
    )
    let identifier: String
    if let preferred = resolvedTarget.preferredIdentifier {
      identifier = preferred
    } else if input.hasChatTarget {
      throw RPCError.invalidParams("missing chat identifier or guid")
    } else {
      do {
        identifier = try ChatTargetResolver.directTypingIdentifier(
          recipient: input.recipient,
          serviceRaw: serviceRaw,
          invalidServiceError: { RPCError.invalidParams($0) }
        )
      } catch let err as RPCError {
        throw err
      }
    }
    if isTyping {
      try TypingIndicator.startTyping(chatIdentifier: identifier)
    } else {
      try TypingIndicator.stopTyping(chatIdentifier: identifier)
    }
    respond(id: id, result: ["ok": true])
  }

  /// `read` — mark all messages in a chat as read on this device, which also
  /// fires a read-receipt to the sender if the chat has receipts enabled.
  func handleRead(params: [String: Any], id: Any?) async throws {
    let input = ChatTargetInput(
      recipient: stringParam(params["to"]) ?? "",
      chatID: int64Param(params["chat_id"]),
      chatIdentifier: stringParam(params["chat_identifier"]) ?? "",
      chatGUID: stringParam(params["chat_guid"]) ?? ""
    )
    try ChatTargetResolver.validateRecipientRequirements(
      input: input,
      mixedTargetError: RPCError.invalidParams("use to or chat_*; not both"),
      missingRecipientError: RPCError.invalidParams("to is required")
    )
    let resolvedTarget = try await ChatTargetResolver.resolveChatTarget(
      input: input,
      lookupChat: { chatID in try await cache.info(chatID: chatID) },
      unknownChatError: { chatID in
        RPCError.invalidParams("unknown chat_id \(chatID)")
      }
    )
    let handle: String
    if let preferred = resolvedTarget.preferredIdentifier {
      handle = preferred
    } else if input.hasChatTarget {
      throw RPCError.invalidParams("missing chat identifier or guid")
    } else {
      handle = input.recipient
    }
    try await IMCoreBridge.shared.markAsRead(handle: handle)
    respond(id: id, result: ["ok": true])
  }
}

func buildMessagePayload(
  store: MessageStore,
  cache: ChatCache,
  message: Message,
  includeAttachments: Bool,
  includeReactions: Bool,
  prefetchedAttachments: [AttachmentMeta]? = nil,
  prefetchedReactions: [Reaction]? = nil,
  attachmentOptions: AttachmentQueryOptions = .default,
  contactResolver: any ContactResolving = NoOpContactResolver()
) async throws -> [String: Any] {
  let chatInfo = try await cache.info(chatID: message.chatID)
  let participants = try await cache.participants(chatID: message.chatID)
  let attachments: [AttachmentMeta]
  if includeAttachments {
    attachments =
      try prefetchedAttachments ?? store.attachments(for: message.rowID, options: attachmentOptions)
  } else {
    attachments = []
  }
  let reactions: [Reaction]
  if includeReactions {
    reactions = try prefetchedReactions ?? store.reactions(for: message.rowID)
  } else {
    reactions = []
  }
  let senderName = message.isFromMe ? nil : contactResolver.displayName(for: message.sender)
  var reactionSenderNames: [Int64: String] = [:]
  for reaction in reactions where !reaction.isFromMe {
    if let name = contactResolver.displayName(for: reaction.sender) {
      reactionSenderNames[reaction.rowID] = name
    }
  }
  return try messagePayload(
    message: message,
    chatInfo: chatInfo,
    participants: participants,
    attachments: attachments,
    reactions: reactions,
    senderName: senderName,
    reactionSenderNames: reactionSenderNames
  )
}
