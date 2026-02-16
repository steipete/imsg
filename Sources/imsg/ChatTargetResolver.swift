import IMsgCore

struct ChatTargetInput: Sendable {
  let recipient: String
  let chatID: Int64?
  let chatIdentifier: String
  let chatGUID: String

  var hasChatTarget: Bool {
    chatID != nil || !chatIdentifier.isEmpty || !chatGUID.isEmpty
  }
}

struct ResolvedChatTarget: Sendable {
  let chatIdentifier: String
  let chatGUID: String

  var preferredIdentifier: String? {
    if !chatGUID.isEmpty { return chatGUID }
    if !chatIdentifier.isEmpty { return chatIdentifier }
    return nil
  }
}

enum ChatTargetResolver {
  static func validateRecipientRequirements(
    input: ChatTargetInput,
    mixedTargetError: Error,
    missingRecipientError: Error
  ) throws {
    if input.hasChatTarget && !input.recipient.isEmpty {
      throw mixedTargetError
    }
    if !input.hasChatTarget && input.recipient.isEmpty {
      throw missingRecipientError
    }
  }

  static func resolveChatTarget(
    input: ChatTargetInput,
    lookupChat: (Int64) async throws -> ChatInfo?,
    unknownChatError: (Int64) -> Error
  ) async throws -> ResolvedChatTarget {
    var resolvedIdentifier = input.chatIdentifier
    var resolvedGUID = input.chatGUID

    if let chatID = input.chatID {
      guard let info = try await lookupChat(chatID) else {
        throw unknownChatError(chatID)
      }
      resolvedIdentifier = info.identifier
      resolvedGUID = info.guid
    }

    return ResolvedChatTarget(
      chatIdentifier: resolvedIdentifier,
      chatGUID: resolvedGUID
    )
  }

  static func directTypingIdentifier(
    recipient: String,
    serviceRaw: String,
    invalidServiceError: (String) -> Error
  ) throws -> String {
    guard let service = MessageService(rawValue: serviceRaw.lowercased()) else {
      throw invalidServiceError(serviceRaw)
    }
    let prefix = service == .sms ? "SMS" : "iMessage"
    return "\(prefix);-;\(recipient)"
  }
}
